using Godot;
using System;

/// <summary>
/// Stereo3DViewer — Quest3 / Android tablet için stereo video görüntüleyici.
///
/// DÜZELTMELER (v2):
/// 1. ExternalTexture, _Ready() yerine ilk _Process() frame'inde oluşturuluyor.
///    Godot 4'te ExternalTexture.GetExternalTextureId() _Ready'de 0 dönebiliyor
///    çünkü GL context henüz tam hazır değil.
/// 2. ConnectSourceTexture() artık _pendingConnect bayrağıyla bir sonraki
///    _Process frame'ine erteleniyor.
/// 3. ExternalTexture null-guard'ları güçlendirildi.
/// 4. VariantToBool: Nil → false (önceden true dönüyordu, plugin hatasını maskeliyordu).
/// 5. Renderer kontrolü eklendi: Forward Plus Android'de ExternalTexture'ı kırabiliyor.
/// </summary>
public partial class Stereo3DViewer : Node3D
{
    // -------------------------------------------------------------------------
    // Export parametreleri
    // -------------------------------------------------------------------------

    [ExportGroup("Camera Source")]
    [Export] public bool StartOnReady = true;
    [Export] public string AndroidCameraSingletonName = "QuestExternalTexture";
    [Export] public string NetworkStreamUrl = "";
    [Export] public bool EnableRtspToHlsFallback = true;
    [Export] public int HlsPort = 8888;
    [Export] public int RtspPort = 8554;
    [Export] public int StreamWidth = 1280;
    [Export] public int StreamHeight = 720;
    [Export] public bool AutoStartStream = true;
    [Export(PropertyHint.Range, "0.2,5.0,0.1")] public float StreamHealthCheckIntervalSec = 1.0f;

    [ExportGroup("Stereo View")]
    [Export] public float EyeTextureShiftPixels = 1.5f;
    [Export] public float EyeTextureZoom = 1f;
    [Export] public float CenterOffsetPixels = 0f;
    [Export] public bool MirrorSourceHorizontally = false;

    [ExportGroup("Output")]
    [Export] public int OutputWidth = 1280;
    [Export] public int OutputHeight = 720;
    [Export] public bool MatchWindowSizeAtRuntime = true;
    [Export] public float MeshDistanceMeters = 2.0f;
    [Export(PropertyHint.Range, "1.0,3.0,0.01")] public float EyePlaneFillScale = 1.15f;
    [Export(PropertyHint.Range, "1.0,3.0,0.01")] public float MainPlaneFillScale = 1.2f;
    [Export] public bool UseLeftEyeForMainDisplay = true;

    [ExportGroup("Node Paths")]
    [Export] public NodePath LeftEyeViewportPath   = new NodePath("LeftEyeViewport");
    [Export] public NodePath RightEyeViewportPath  = new NodePath("RightEyeViewport");
    [Export] public NodePath LeftEyeCameraPath     = new NodePath("LeftEyeViewport/LeftEyeRoot/LeftEyeCamera");
    [Export] public NodePath RightEyeCameraPath    = new NodePath("RightEyeViewport/RightEyeRoot/RightEyeCamera");
    [Export] public NodePath LeftEyeMeshPath       = new NodePath("LeftEyeViewport/LeftEyeRoot/LeftEyeVideoMesh");
    [Export] public NodePath RightEyeMeshPath      = new NodePath("RightEyeViewport/RightEyeRoot/RightEyeVideoMesh");
    [Export] public NodePath MainDisplayCameraPath = new NodePath("MainDisplayCamera");
    [Export] public NodePath MainDisplayMeshPath   = new NodePath("MainDisplayMesh");

    // -------------------------------------------------------------------------
    // Özel alanlar
    // -------------------------------------------------------------------------

    private SubViewport    _leftViewport;
    private SubViewport    _rightViewport;
    private Camera3D       _leftEyeCamera;
    private Camera3D       _rightEyeCamera;
    private MeshInstance3D _leftEyeMesh;
    private MeshInstance3D _rightEyeMesh;
    private Camera3D       _mainDisplayCamera;
    private MeshInstance3D _mainDisplayMesh;

    private Shader            _sourceShader;
    private ShaderMaterial    _leftSourceMaterial;
    private ShaderMaterial    _rightSourceMaterial;
    private StandardMaterial3D _mainDisplayMaterial;
    private ImageTexture      _blackFallbackTexture;

    private ExternalTexture _externalTexture;
    private GodotObject     _androidPluginSingleton;

    private bool   _sessionActive;
    private bool   _sourceConnected;
    private bool   _pluginConfigured;
    private float  _reconnectTimer;
    private float  _streamHealthTimer;
    private string _activeStreamUrl = string.Empty;
    private bool   _fallbackActivated;
    private ulong  _lastStartRequestAtMs;
    private ulong  _lastRestartAtMs;

    private Vector2I _lastViewportSize = Vector2I.Zero;
    private ulong    _nextSourceWarnAtMs;

    // FIX: ExternalTexture ilk _Process'te init edilmesi için bayrak
    private bool _pendingConnect = false;
    private int  _initFrameDelay = 0; // GL context için birkaç frame bekle

    private const float SOURCE_RECONNECT_INTERVAL_SEC = 0.5f;
    private const ulong SOURCE_WARN_THROTTLE_MS = 3000;
    private const ulong STREAM_START_GRACE_MS   = 12000;
    private const ulong STREAM_RESTART_COOLDOWN_MS = 2500;

    private const string SOURCE_SHADER_CODE = @"
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform sampler2D source_tex : source_color;
uniform float shift_uv = 0.0;
uniform float center_offset_uv = 0.0;
uniform float zoom_uv = 1.0;
uniform bool mirror_h = false;
void fragment() {
    vec2 uv = UV;
    if (mirror_h) { uv.x = 1.0 - uv.x; }
    uv = (uv - vec2(0.5)) / max(zoom_uv, 0.0001) + vec2(0.5 + center_offset_uv + shift_uv, 0.5);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        ALBEDO = vec3(0.0); ALPHA = 1.0; return;
    }
    vec4 src = texture(source_tex, uv);
    ALBEDO = src.rgb;
    ALPHA = 1.0;
}
";

    // =========================================================================
    // Godot lifecycle
    // =========================================================================

    public override void _Ready()
    {
        ResolveSceneNodes();
        EnsureMaterialsAndMeshes();
        SyncViewportAndGeometry(force: true);

        if (StartOnReady)
            StartSession();
    }

    public override void _Process(double delta)
    {
        SyncViewportAndGeometry(force: false);
        UpdateStereoShaderParameters();
        RefreshMainDisplayTexture();

        if (!_sessionActive)
            return;

        // FIX: ExternalTexture init'i _Ready'den birkaç frame sonraya ertele
        if (_pendingConnect)
        {
            _initFrameDelay++;
            if (_initFrameDelay >= 3) // 3 frame = GL context hazır
            {
                _pendingConnect = false;
                _initFrameDelay = 0;
                _sourceConnected = ConnectSourceTexture();
                if (!_sourceConnected)
                    ApplySourceTexture(null);
            }
            return;
        }

        if (_sourceConnected)
        {
            MonitorPluginStream((float)delta);
            return;
        }

        _reconnectTimer += (float)delta;
        if (_reconnectTimer < SOURCE_RECONNECT_INTERVAL_SEC)
            return;
        _reconnectTimer = 0f;
        _sourceConnected = ConnectSourceTexture();
    }

    public override void _ExitTree()
    {
        StopSession();
    }

    // =========================================================================
    // Public API
    // =========================================================================

    public void StartSession()
    {
        if (_sessionActive) return;
        _sessionActive = true;
        _pluginConfigured = false;
        _activeStreamUrl = (NetworkStreamUrl ?? string.Empty).Trim();
        _fallbackActivated = false;
        _lastStartRequestAtMs = 0;
        _lastRestartAtMs = 0;
        _streamHealthTimer = 0f;

        // FIX: Android'de GL hazır olsun diye _Process'e ertele
        if (OS.GetName() == "Android")
        {
            _pendingConnect = true;
            _initFrameDelay = 0;
            _sourceConnected = false;
        }
        else
        {
            _sourceConnected = ConnectSourceTexture();
            if (!_sourceConnected)
                ApplySourceTexture(null);
        }
    }

    public void StopSession()
    {
        _sessionActive = false;
        _sourceConnected = false;
        _pluginConfigured = false;
        _pendingConnect = false;
        _initFrameDelay = 0;
        _reconnectTimer = 0f;
        _streamHealthTimer = 0f;
        _activeStreamUrl = string.Empty;
        _fallbackActivated = false;
        _lastStartRequestAtMs = 0;
        _lastRestartAtMs = 0;
        StopPluginStream();
        _externalTexture = null;
        _androidPluginSingleton = null;
        ApplySourceTexture(null);
    }

    public void SetExternalTexture(Texture2D texture)
    {
        if (texture == null) return;
        _sourceConnected = true;
        ApplySourceTexture(texture);
    }

    // =========================================================================
    // Sahne kurulumu
    // =========================================================================

    private void ResolveSceneNodes()
    {
        _leftViewport      = GetNodeOrNull<SubViewport>(LeftEyeViewportPath);
        _rightViewport     = GetNodeOrNull<SubViewport>(RightEyeViewportPath);
        _leftEyeCamera     = GetNodeOrNull<Camera3D>(LeftEyeCameraPath);
        _rightEyeCamera    = GetNodeOrNull<Camera3D>(RightEyeCameraPath);
        _leftEyeMesh       = GetNodeOrNull<MeshInstance3D>(LeftEyeMeshPath);
        _rightEyeMesh      = GetNodeOrNull<MeshInstance3D>(RightEyeMeshPath);
        _mainDisplayCamera = GetNodeOrNull<Camera3D>(MainDisplayCameraPath);
        _mainDisplayMesh   = GetNodeOrNull<MeshInstance3D>(MainDisplayMeshPath);

        if (_leftViewport == null || _rightViewport == null ||
            _leftEyeMesh == null || _rightEyeMesh == null ||
            _mainDisplayMesh == null || _mainDisplayCamera == null)
        {
            GD.PrintErr("[Stereo3D] Scene node referansları eksik. StereoViewScene.tscn yapısını kontrol et.");
        }
    }

    private void EnsureMaterialsAndMeshes()
    {
        if (_sourceShader == null)
            _sourceShader = new Shader { Code = SOURCE_SHADER_CODE };

        if (_leftSourceMaterial == null)
            _leftSourceMaterial = new ShaderMaterial { Shader = _sourceShader };

        if (_rightSourceMaterial == null)
            _rightSourceMaterial = new ShaderMaterial { Shader = _sourceShader };

        if (_mainDisplayMaterial == null)
        {
            _mainDisplayMaterial = new StandardMaterial3D
            {
                ShadingMode = BaseMaterial3D.ShadingModeEnum.Unshaded,
                CullMode    = BaseMaterial3D.CullModeEnum.Disabled,
            };
        }

        if (_leftEyeMesh  != null) _leftEyeMesh.MaterialOverride  = _leftSourceMaterial;
        if (_rightEyeMesh != null) _rightEyeMesh.MaterialOverride = _rightSourceMaterial;
        if (_mainDisplayMesh != null) _mainDisplayMesh.MaterialOverride = _mainDisplayMaterial;

        EnsureQuadMesh(_leftEyeMesh);
        EnsureQuadMesh(_rightEyeMesh);
        EnsureQuadMesh(_mainDisplayMesh);

        if (_blackFallbackTexture == null)
        {
            var img = Image.CreateEmpty(2, 2, false, Image.Format.Rgb8);
            img.Fill(Colors.Black);
            _blackFallbackTexture = ImageTexture.CreateFromImage(img);
        }

        UpdateStereoShaderParameters();
    }

    private static void EnsureQuadMesh(MeshInstance3D target)
    {
        if (target == null || target.Mesh is QuadMesh) return;
        target.Mesh = new QuadMesh();
    }

    // =========================================================================
    // Viewport & Geometri
    // =========================================================================

    private void SyncViewportAndGeometry(bool force)
    {
        Vector2I targetSize = ResolveOutputSize();
        if (!force && targetSize == _lastViewportSize) return;
        _lastViewportSize = targetSize;
        ConfigureSubViewports(targetSize);
        AlignStereoEyeNodes(targetSize);
        ConfigureMainDisplayPlane(targetSize);
        RefreshMainDisplayTexture();
    }

    private Vector2I ResolveOutputSize()
    {
        if (MatchWindowSizeAtRuntime)
        {
            Vector2I ws = DisplayServer.WindowGetSize();
            if (ws.X > 0 && ws.Y > 0) return ws;
        }
        if (OutputWidth > 0 && OutputHeight > 0)
            return new Vector2I(OutputWidth, OutputHeight);
        Vector2I s = DisplayServer.WindowGetSize();
        return (s.X > 0 && s.Y > 0) ? s : new Vector2I(1280, 720);
    }

    private void ConfigureSubViewports(Vector2I size)
    {
        foreach (var vp in new[] { _leftViewport, _rightViewport })
        {
            if (vp == null) continue;
            vp.Size = size;
            if (vp.World3D == null) vp.World3D = new World3D();
            vp.RenderTargetUpdateMode = SubViewport.UpdateMode.Always;
            vp.TransparentBg = false;
        }
    }

    private void AlignStereoEyeNodes(Vector2I size)
    {
        if (_leftEyeCamera  != null) { _leftEyeCamera.Position  = Vector3.Zero; _leftEyeCamera.Rotation  = Vector3.Zero; }
        if (_rightEyeCamera != null) { _rightEyeCamera.Position = Vector3.Zero; _rightEyeCamera.Rotation = Vector3.Zero; }

        float leftFov  = _leftEyeCamera?.Fov  ?? _mainDisplayCamera?.Fov ?? 75f;
        float rightFov = _rightEyeCamera?.Fov ?? _mainDisplayCamera?.Fov ?? 75f;

        PlaceVideoMesh(_leftEyeMesh,  CalculatePlaneSize(size, MeshDistanceMeters, leftFov,  EyePlaneFillScale), MeshDistanceMeters);
        PlaceVideoMesh(_rightEyeMesh, CalculatePlaneSize(size, MeshDistanceMeters, rightFov, EyePlaneFillScale), MeshDistanceMeters);
    }

    private void ConfigureMainDisplayPlane(Vector2I size)
    {
        if (_mainDisplayCamera != null)
        {
            _mainDisplayCamera.Position = Vector3.Zero;
            _mainDisplayCamera.Rotation = Vector3.Zero;
            _mainDisplayCamera.Current  = true;
        }
        PlaceVideoMesh(_mainDisplayMesh,
            CalculatePlaneSize(size, MeshDistanceMeters, _mainDisplayCamera?.Fov ?? 75f, MainPlaneFillScale),
            MeshDistanceMeters);
    }

    private static Vector2 CalculatePlaneSize(Vector2I size, float distance, float fovDeg, float fillScale)
    {
        float d    = Mathf.Max(0.01f, distance);
        float fov  = Mathf.Clamp(fovDeg, 1f, 170f);
        float fill = Mathf.Max(1f, fillScale);
        float h    = 2f * d * Mathf.Tan(Mathf.DegToRad(fov) * 0.5f);
        float asp  = Mathf.Max(0.01f, (float)size.X / Mathf.Max(1f, size.Y));
        return new Vector2(h * asp * fill, h * fill);
    }

    private static void PlaceVideoMesh(MeshInstance3D mesh, Vector2 size, float distance)
    {
        if (mesh == null) return;
        if (mesh.Mesh is not QuadMesh quad) { quad = new QuadMesh(); mesh.Mesh = quad; }
        quad.Size = size;
        mesh.Position   = new Vector3(0f, 0f, -Mathf.Max(0.01f, distance));
        mesh.Rotation   = Vector3.Zero;
        mesh.CastShadow = GeometryInstance3D.ShadowCastingSetting.Off;
    }

    // =========================================================================
    // External Texture bağlantısı
    // =========================================================================

    private bool ConnectSourceTexture()
    {
        if (OS.GetName() != "Android")
        {
            WarnSourceOnce("[Stereo3D] External texture bridge yalnızca Android build'de aktif olur.");
            return false;
        }

        if (string.IsNullOrWhiteSpace(AndroidCameraSingletonName) ||
            !Engine.HasSingleton(AndroidCameraSingletonName))
        {
            WarnSourceOnce($"[Stereo3D] Android singleton '{AndroidCameraSingletonName}' bulunamadı.");
            return false;
        }

        _androidPluginSingleton = Engine.GetSingleton(AndroidCameraSingletonName);
        if (_androidPluginSingleton == null)
        {
            WarnSourceOnce($"[Stereo3D] Singleton '{AndroidCameraSingletonName}' alınamadı.");
            return false;
        }

        // FIX: ExternalTexture nesnesini burada (GL frame içinde) oluştur
        if (_externalTexture == null)
            _externalTexture = new ExternalTexture();

        ulong externalTextureId = _externalTexture.GetExternalTextureId();

        // FIX: ID 0 ise birkaç frame daha bekle (GL henüz allocate etmemiş olabilir)
        if (externalTextureId == 0)
        {
            WarnSourceOnce("[Stereo3D] ExternalTexture ID alınamadı — bir sonraki frame'de tekrar denenecek.");
            _externalTexture = null; // bir sonraki denemede yeniden oluştur
            return false;
        }

        int safeW = Mathf.Max(16, StreamWidth);
        int safeH = Mathf.Max(16, StreamHeight);

        bool configured = CallPluginBool("configure_external_texture", (long)externalTextureId, safeW, safeH);
        if (!configured)
        {
            string pluginError = TryGetPluginLastError();
            WarnSourceOnce(string.IsNullOrWhiteSpace(pluginError)
                ? "[Stereo3D] Plugin configure_external_texture başarısız oldu."
                : $"[Stereo3D] Plugin configure_external_texture hatası: {pluginError}");
            return false;
        }

        _pluginConfigured = true;

        if (AutoStartStream)
            StartPluginStream();
        else if (!string.IsNullOrWhiteSpace(GetEffectiveStreamUrl()))
            CallPluginBool("set_stream_url", GetEffectiveStreamUrl());

        ApplySourceTexture(_externalTexture);
        GD.Print($"[Stereo3D] External texture bridge hazır. texture_id={externalTextureId}, stream='{GetEffectiveStreamUrl()}'");
        return true;
    }

    // =========================================================================
    // Stream izleme & yönetim
    // =========================================================================

    private void MonitorPluginStream(float delta)
    {
        if (!AutoStartStream || _androidPluginSingleton == null || !_pluginConfigured) return;

        _streamHealthTimer += delta;
        if (_streamHealthTimer < Mathf.Max(0.2f, StreamHealthCheckIntervalSec)) return;
        _streamHealthTimer = 0f;

        bool active = CallPluginBool("is_stream_active");
        if (active) return;

        string pluginError = TryGetPluginLastError();
        ulong now = Time.GetTicksMsec();
        bool insideGrace = _lastStartRequestAtMs > 0 && (now - _lastStartRequestAtMs) < STREAM_START_GRACE_MS;
        bool starting    = CallPluginBool("is_stream_starting");

        if (insideGrace && (starting || string.IsNullOrWhiteSpace(pluginError))) return;
        if (_lastRestartAtMs > 0 && (now - _lastRestartAtMs) < STREAM_RESTART_COOLDOWN_MS) return;

        TryActivateStreamFallback(pluginError);
        _lastRestartAtMs = now;
        StartPluginStream();
    }

    private void StartPluginStream()
    {
        if (_androidPluginSingleton == null || !_pluginConfigured) return;

        for (int attempt = 0; attempt < 2; attempt++)
        {
            string url = GetEffectiveStreamUrl();
            if (string.IsNullOrWhiteSpace(url))
            {
                WarnSourceOnce("[Stereo3D] NetworkStreamUrl boş. Stream başlamıyor.");
                return;
            }

            bool urlOk = CallPluginBool("set_stream_url", url);
            if (!urlOk)
            {
                string err = TryGetPluginLastError();
                if (TryActivateStreamFallback(err)) continue;
                WarnSourceOnce(string.IsNullOrWhiteSpace(err)
                    ? "[Stereo3D] set_stream_url başarısız."
                    : $"[Stereo3D] set_stream_url hatası: {err}");
                return;
            }

            bool startOk = CallPluginBool("start_stream");
            if (startOk)
            {
                _lastStartRequestAtMs = Time.GetTicksMsec();
                return;
            }

            string startErr = TryGetPluginLastError();
            if (TryActivateStreamFallback(startErr)) continue;
            WarnSourceOnce(string.IsNullOrWhiteSpace(startErr)
                ? "[Stereo3D] start_stream başarısız."
                : $"[Stereo3D] start_stream hatası: {startErr}");
            return;
        }
    }

    private string GetEffectiveStreamUrl()
    {
        if (!string.IsNullOrWhiteSpace(_activeStreamUrl)) return _activeStreamUrl;
        _activeStreamUrl = (NetworkStreamUrl ?? string.Empty).Trim();
        return _activeStreamUrl;
    }

    private bool TryActivateStreamFallback(string reason)
    {
        if (!EnableRtspToHlsFallback || _fallbackActivated) return false;
        string current = GetEffectiveStreamUrl();
        if (string.IsNullOrWhiteSpace(current)) return false;
        if (!Uri.TryCreate(current, UriKind.Absolute, out Uri uri)) return false;
        string host = uri.Host;
        if (string.IsNullOrWhiteSpace(host)) return false;

        string path = uri.AbsolutePath?.Trim('/') ?? string.Empty;
        if (string.IsNullOrWhiteSpace(path)) path = "quest3";

        string fallbackUrl;
        if (string.Equals(uri.Scheme, "rtsp", StringComparison.OrdinalIgnoreCase))
        {
            int port = HlsPort > 0 ? HlsPort : 8888;
            fallbackUrl = $"http://{host}:{port}/{path}/index.m3u8";
        }
        else if (string.Equals(uri.Scheme, "http",  StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase))
        {
            if (path.EndsWith("index.m3u8", StringComparison.OrdinalIgnoreCase))
                path = path[..^"index.m3u8".Length].TrimEnd('/');
            if (string.IsNullOrWhiteSpace(path)) path = "quest3";
            int port = RtspPort > 0 ? RtspPort : 8554;
            fallbackUrl = $"rtsp://{host}:{port}/{path}";
        }
        else return false;

        if (string.Equals(current, fallbackUrl, StringComparison.OrdinalIgnoreCase)) return false;

        _activeStreamUrl = fallbackUrl;
        _fallbackActivated = true;
        GD.Print($"[Stereo3D] Stream fallback aktif: {_activeStreamUrl}. reason='{reason}'");
        return true;
    }

    private void StopPluginStream()
    {
        if (_androidPluginSingleton == null) return;
        try
        {
            if (_androidPluginSingleton.HasMethod("stop_stream"))
                _androidPluginSingleton.Call("stop_stream");
        }
        catch (Exception e)
        {
            GD.PrintErr("[Stereo3D] stop_stream çağrı hatası: " + e.Message);
        }
    }

    // =========================================================================
    // Plugin yardımcıları
    // =========================================================================

    private bool CallPluginBool(string method)
    {
        if (_androidPluginSingleton == null || !_androidPluginSingleton.HasMethod(method))
            return false;
        try
        {
            return VariantToBool(_androidPluginSingleton.Call(method));
        }
        catch (Exception e)
        {
            GD.PrintErr($"[Stereo3D] Plugin çağrı hatası ({method}): {e.Message}");
            return false;
        }
    }

    private bool CallPluginBool(string method, string arg0)
    {
        if (_androidPluginSingleton == null || !_androidPluginSingleton.HasMethod(method))
            return false;
        try
        {
            return VariantToBool(_androidPluginSingleton.Call(method, arg0));
        }
        catch (Exception e)
        {
            GD.PrintErr($"[Stereo3D] Plugin çağrı hatası ({method}): {e.Message}");
            return false;
        }
    }

    private bool CallPluginBool(string method, long arg0, int arg1, int arg2)
    {
        if (_androidPluginSingleton == null || !_androidPluginSingleton.HasMethod(method))
            return false;
        try
        {
            return VariantToBool(_androidPluginSingleton.Call(method, arg0, arg1, arg2));
        }
        catch (Exception e)
        {
            GD.PrintErr($"[Stereo3D] Plugin çağrı hatası ({method}): {e.Message}");
            return false;
        }
    }

    private static bool VariantToBool(Variant result)
    {
        return result.VariantType switch
        {
            Variant.Type.Bool => result.AsBool(),
            Variant.Type.Int  => result.AsInt64() != 0,
            // FIX: Nil → false (plugin çağrısı sessizce başarısız sayılır, true döndürme)
            Variant.Type.Nil  => false,
            _                 => true,
        };
    }

    private string TryGetPluginLastError()
    {
        if (_androidPluginSingleton == null || !_androidPluginSingleton.HasMethod("get_last_error"))
            return string.Empty;
        try
        {
            Variant v = _androidPluginSingleton.Call("get_last_error");
            return v.VariantType == Variant.Type.String ? v.AsString() : v.ToString();
        }
        catch { return string.Empty; }
    }

    // =========================================================================
    // Texture & shader
    // =========================================================================

    private void ApplySourceTexture(Texture2D source)
    {
        Texture2D safe = source ?? _blackFallbackTexture;
        _leftSourceMaterial?.SetShaderParameter("source_tex",  safe);
        _rightSourceMaterial?.SetShaderParameter("source_tex", safe);
    }

    private void UpdateStereoShaderParameters()
    {
        int refW = Mathf.Max(1, _lastViewportSize.X <= 0 ? ResolveOutputSize().X : _lastViewportSize.X);
        float shiftUv  = EyeTextureShiftPixels / refW;
        float centerUv = CenterOffsetPixels    / refW;
        float safeZoom = Mathf.Max(1.0f, EyeTextureZoom);

        if (_leftSourceMaterial != null)
        {
            _leftSourceMaterial.SetShaderParameter("shift_uv",         -shiftUv);
            _leftSourceMaterial.SetShaderParameter("center_offset_uv",  centerUv);
            _leftSourceMaterial.SetShaderParameter("zoom_uv",           safeZoom);
            _leftSourceMaterial.SetShaderParameter("mirror_h",          MirrorSourceHorizontally);
        }
        if (_rightSourceMaterial != null)
        {
            _rightSourceMaterial.SetShaderParameter("shift_uv",         shiftUv);
            _rightSourceMaterial.SetShaderParameter("center_offset_uv", centerUv);
            _rightSourceMaterial.SetShaderParameter("zoom_uv",          safeZoom);
            _rightSourceMaterial.SetShaderParameter("mirror_h",         MirrorSourceHorizontally);
        }
    }

    private void RefreshMainDisplayTexture()
    {
        if (_mainDisplayMaterial == null) return;
        Texture2D tex = UseLeftEyeForMainDisplay
            ? _leftViewport?.GetTexture()
            : _rightViewport?.GetTexture();
        _mainDisplayMaterial.AlbedoTexture = tex ?? _blackFallbackTexture;
    }

    private void WarnSourceOnce(string message)
    {
        ulong now = Time.GetTicksMsec();
        if (now < _nextSourceWarnAtMs) return;
        _nextSourceWarnAtMs = now + SOURCE_WARN_THROTTLE_MS;
        GD.PrintErr(message);
    }
}
