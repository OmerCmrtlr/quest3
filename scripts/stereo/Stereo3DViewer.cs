using Godot;
using System;

public partial class Stereo3DViewer : Node3D
{
    [ExportGroup("Camera Source")]
    [Export] public bool StartOnReady = true;
    [Export] public int CameraIndex = 0;
    [Export] public bool PreferNewestFeedOnStart = true;
    [Export] public bool EnableLocalCameraFallback = false;
    [Export] public string AndroidCameraSingletonName = "QuestExternalTexture";

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
    [Export] public NodePath LeftEyeViewportPath = new NodePath("LeftEyeViewport");
    [Export] public NodePath RightEyeViewportPath = new NodePath("RightEyeViewport");
    [Export] public NodePath LeftEyeCameraPath = new NodePath("LeftEyeViewport/LeftEyeRoot/LeftEyeCamera");
    [Export] public NodePath RightEyeCameraPath = new NodePath("RightEyeViewport/RightEyeRoot/RightEyeCamera");
    [Export] public NodePath LeftEyeMeshPath = new NodePath("LeftEyeViewport/LeftEyeRoot/LeftEyeVideoMesh");
    [Export] public NodePath RightEyeMeshPath = new NodePath("RightEyeViewport/RightEyeRoot/RightEyeVideoMesh");
    [Export] public NodePath MainDisplayCameraPath = new NodePath("MainDisplayCamera");
    [Export] public NodePath MainDisplayMeshPath = new NodePath("MainDisplayMesh");

    private SubViewport _leftViewport;
    private SubViewport _rightViewport;
    private Camera3D _leftEyeCamera;
    private Camera3D _rightEyeCamera;
    private MeshInstance3D _leftEyeMesh;
    private MeshInstance3D _rightEyeMesh;
    private Camera3D _mainDisplayCamera;
    private MeshInstance3D _mainDisplayMesh;

    private CameraFeed _activeFeed;
    private CameraTexture _cameraTexture;

    private Shader _sourceShader;
    private ShaderMaterial _leftSourceMaterial;
    private ShaderMaterial _rightSourceMaterial;
    private StandardMaterial3D _mainDisplayMaterial;
    private ImageTexture _blackFallbackTexture;

    private bool _sessionActive;
    private bool _sourceConnected;
    private float _reconnectTimer;
    private Vector2I _lastViewportSize = Vector2I.Zero;
    private ulong _nextSourceWarnAtMs;

    private const float SOURCE_RECONNECT_INTERVAL_SEC = 0.5f;
    private const ulong SOURCE_WARN_THROTTLE_MS = 3000;

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
    if (mirror_h) {
        uv.x = 1.0 - uv.x;
    }

    uv = (uv - vec2(0.5)) / max(zoom_uv, 0.0001) + vec2(0.5 + center_offset_uv + shift_uv, 0.5);

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        ALBEDO = vec3(0.0);
        ALPHA = 1.0;
        return;
    }

    vec4 src = texture(source_tex, uv);
    ALBEDO = src.rgb;
    ALPHA = 1.0;
}
";

    public override void _Ready()
    {
        RequestCameraPermissionIfNeeded();
        ResolveSceneNodes();
        EnsureMaterialsAndMeshes();
        SyncViewportAndGeometry(force: true);

        if (StartOnReady)
            StartSession();
    }

    public void StartSession()
    {
        if (_sessionActive)
            return;

        _sessionActive = true;
        _sourceConnected = ConnectSourceTexture();
        if (!_sourceConnected)
            ApplySourceTexture(null);
    }

    public void StopSession()
    {
        _sessionActive = false;
        _sourceConnected = false;
        _reconnectTimer = 0f;

        if (_activeFeed != null)
        {
            try { _activeFeed.FeedIsActive = false; } catch { }
            _activeFeed = null;
        }

        _cameraTexture = null;
        ApplySourceTexture(null);
    }

    public override void _Process(double delta)
    {
        SyncViewportAndGeometry(force: false);
        UpdateStereoShaderParameters();
        RefreshMainDisplayTexture();

        if (!_sessionActive)
            return;

        if (_sourceConnected)
            return;

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

    public void SetExternalTexture(Texture2D texture)
    {
        if (texture == null)
            return;

        _sourceConnected = true;
        ApplySourceTexture(texture);
    }

    private void ResolveSceneNodes()
    {
        _leftViewport = GetNodeOrNull<SubViewport>(LeftEyeViewportPath);
        _rightViewport = GetNodeOrNull<SubViewport>(RightEyeViewportPath);
        _leftEyeCamera = GetNodeOrNull<Camera3D>(LeftEyeCameraPath);
        _rightEyeCamera = GetNodeOrNull<Camera3D>(RightEyeCameraPath);
        _leftEyeMesh = GetNodeOrNull<MeshInstance3D>(LeftEyeMeshPath);
        _rightEyeMesh = GetNodeOrNull<MeshInstance3D>(RightEyeMeshPath);
        _mainDisplayCamera = GetNodeOrNull<Camera3D>(MainDisplayCameraPath);
        _mainDisplayMesh = GetNodeOrNull<MeshInstance3D>(MainDisplayMeshPath);

        if (_leftViewport == null || _rightViewport == null || _leftEyeMesh == null || _rightEyeMesh == null || _mainDisplayMesh == null || _mainDisplayCamera == null)
            GD.PrintErr("[Stereo3D] Scene node referansları eksik. StereoViewScene.tscn yapısını kontrol et.");
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
                CullMode = BaseMaterial3D.CullModeEnum.Disabled,
            };
        }

        if (_leftEyeMesh != null)
            _leftEyeMesh.MaterialOverride = _leftSourceMaterial;
        if (_rightEyeMesh != null)
            _rightEyeMesh.MaterialOverride = _rightSourceMaterial;
        if (_mainDisplayMesh != null)
            _mainDisplayMesh.MaterialOverride = _mainDisplayMaterial;

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
        if (target == null)
            return;

        if (target.Mesh is QuadMesh)
            return;

        target.Mesh = new QuadMesh();
    }

    private void SyncViewportAndGeometry(bool force)
    {
        Vector2I targetSize = ResolveOutputSize();
        if (!force && targetSize == _lastViewportSize)
            return;

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
            Vector2I windowSize = DisplayServer.WindowGetSize();
            if (windowSize.X > 0 && windowSize.Y > 0)
                return windowSize;
        }

        if (OutputWidth > 0 && OutputHeight > 0)
            return new Vector2I(OutputWidth, OutputHeight);

        Vector2I size = DisplayServer.WindowGetSize();
        if (size.X <= 0 || size.Y <= 0)
            return new Vector2I(1280, 720);

        return size;
    }

    private void ConfigureSubViewports(Vector2I size)
    {
        if (_leftViewport != null)
        {
            _leftViewport.Size = size;
            if (_leftViewport.World3D == null)
                _leftViewport.World3D = new World3D();
            _leftViewport.RenderTargetUpdateMode = SubViewport.UpdateMode.Always;
            _leftViewport.TransparentBg = false;
        }

        if (_rightViewport != null)
        {
            _rightViewport.Size = size;
            if (_rightViewport.World3D == null)
                _rightViewport.World3D = new World3D();
            _rightViewport.RenderTargetUpdateMode = SubViewport.UpdateMode.Always;
            _rightViewport.TransparentBg = false;
        }
    }

    private void AlignStereoEyeNodes(Vector2I size)
    {
        if (_leftEyeCamera != null)
        {
            _leftEyeCamera.Position = Vector3.Zero;
            _leftEyeCamera.Rotation = Vector3.Zero;
        }

        if (_rightEyeCamera != null)
        {
            _rightEyeCamera.Position = Vector3.Zero;
            _rightEyeCamera.Rotation = Vector3.Zero;
        }

        float leftFov = _leftEyeCamera?.Fov ?? _mainDisplayCamera?.Fov ?? 75.0f;
        float rightFov = _rightEyeCamera?.Fov ?? _mainDisplayCamera?.Fov ?? 75.0f;

        Vector2 leftPlaneSize = CalculatePlaneSize(size, MeshDistanceMeters, leftFov, EyePlaneFillScale);
        Vector2 rightPlaneSize = CalculatePlaneSize(size, MeshDistanceMeters, rightFov, EyePlaneFillScale);

        PlaceVideoMesh(_leftEyeMesh, leftPlaneSize, MeshDistanceMeters);
        PlaceVideoMesh(_rightEyeMesh, rightPlaneSize, MeshDistanceMeters);
    }

    private void ConfigureMainDisplayPlane(Vector2I size)
    {
        if (_mainDisplayCamera != null)
        {
            _mainDisplayCamera.Position = Vector3.Zero;
            _mainDisplayCamera.Rotation = Vector3.Zero;
            _mainDisplayCamera.Current = true;
        }

        Vector2 planeSize = CalculatePlaneSize(size, MeshDistanceMeters, _mainDisplayCamera?.Fov ?? 75.0f, MainPlaneFillScale);
        PlaceVideoMesh(_mainDisplayMesh, planeSize, MeshDistanceMeters);
    }

    private static Vector2 CalculatePlaneSize(Vector2I size, float distance, float fovDegrees, float fillScale)
    {
        float safeDistance = Mathf.Max(0.01f, distance);
        float safeFov = Mathf.Clamp(fovDegrees, 1.0f, 170.0f);
        float safeFillScale = Mathf.Max(1.0f, fillScale);
        float fovRad = Mathf.DegToRad(safeFov);
        float planeHeight = 2.0f * safeDistance * Mathf.Tan(fovRad * 0.5f);
        float aspect = Mathf.Max(0.01f, (float)size.X / Mathf.Max(1.0f, size.Y));
        float planeWidth = planeHeight * aspect;
        return new Vector2(planeWidth * safeFillScale, planeHeight * safeFillScale);
    }

    private static void PlaceVideoMesh(MeshInstance3D meshNode, Vector2 size, float distance)
    {
        if (meshNode == null)
            return;

        if (meshNode.Mesh is not QuadMesh quad)
        {
            quad = new QuadMesh();
            meshNode.Mesh = quad;
        }

        quad.Size = size;
        meshNode.Position = new Vector3(0f, 0f, -Mathf.Max(0.01f, distance));
        meshNode.Rotation = Vector3.Zero;
        meshNode.CastShadow = GeometryInstance3D.ShadowCastingSetting.Off;
    }

    private bool ConnectSourceTexture()
    {
        Texture2D pluginTexture = TryGetTextureFromAndroidSingleton();
        if (pluginTexture != null)
        {
            ApplySourceTexture(pluginTexture);
            GD.Print("[Stereo3D] Android singleton external texture kaynağı bağlandı.");
            return true;
        }

        if (!EnableLocalCameraFallback)
        {
            WarnSourceOnce("[Stereo3D] Android external texture singleton bulunamadı; fallback kapalı.");
            return false;
        }

        CameraServer.SetMonitoringFeeds(true);
        var feeds = CameraServer.Feeds();
        if (feeds == null || feeds.Count == 0)
        {
            WarnSourceOnce("[Stereo3D] Kamera feed bulunamadı. Camera Feed ve izinleri kontrol et.");
            return false;
        }

        int selectedIndex = Mathf.Clamp(CameraIndex, 0, feeds.Count - 1);
        if (PreferNewestFeedOnStart && CameraIndex <= 0 && feeds.Count > 1)
            selectedIndex = feeds.Count - 1;

        CameraFeed feed = feeds[selectedIndex];
        if (!TryActivateFeed(feed))
        {
            WarnSourceOnce("[Stereo3D] Kamera feed aktif edilemedi. Format/izin kontrolü gerekli.");
            return false;
        }

        _activeFeed = feed;
        _cameraTexture = new CameraTexture
        {
            CameraFeedId = feed.GetId(),
            CameraIsActive = true,
        };

        ApplySourceTexture(_cameraTexture);
        GD.Print($"[Stereo3D] Lokal kamera feed bağlandı. index={selectedIndex}");
        return true;
    }

    private Texture2D TryGetTextureFromAndroidSingleton()
    {
        if (OS.GetName() != "Android")
            return null;

        if (string.IsNullOrWhiteSpace(AndroidCameraSingletonName))
            return null;

        if (!Engine.HasSingleton(AndroidCameraSingletonName))
            return null;

        try
        {
            GodotObject singleton = Engine.GetSingleton(AndroidCameraSingletonName);
            if (singleton == null || !singleton.HasMethod("get_camera_texture"))
                return null;

            Variant result = singleton.Call("get_camera_texture");
            if (result.VariantType != Variant.Type.Object)
                return null;

            GodotObject obj = result.AsGodotObject();
            return obj as Texture2D;
        }
        catch (Exception e)
        {
            GD.PrintErr("[Stereo3D] Android singleton texture okuma hatası: " + e.Message);
            return null;
        }
    }

    private void ApplySourceTexture(Texture2D source)
    {
        Texture2D safe = source ?? _blackFallbackTexture;

        if (_leftSourceMaterial != null)
            _leftSourceMaterial.SetShaderParameter("source_tex", safe);
        if (_rightSourceMaterial != null)
            _rightSourceMaterial.SetShaderParameter("source_tex", safe);
    }

    private void UpdateStereoShaderParameters()
    {
        int referenceWidth = Mathf.Max(1, _lastViewportSize.X <= 0 ? ResolveOutputSize().X : _lastViewportSize.X);
        float shiftUv = EyeTextureShiftPixels / referenceWidth;
        float centerUv = CenterOffsetPixels / referenceWidth;
        float safeZoom = Mathf.Max(1.0f, EyeTextureZoom);

        if (_leftSourceMaterial != null)
        {
            _leftSourceMaterial.SetShaderParameter("shift_uv", -shiftUv);
            _leftSourceMaterial.SetShaderParameter("center_offset_uv", centerUv);
            _leftSourceMaterial.SetShaderParameter("zoom_uv", safeZoom);
            _leftSourceMaterial.SetShaderParameter("mirror_h", MirrorSourceHorizontally);
        }

        if (_rightSourceMaterial != null)
        {
            _rightSourceMaterial.SetShaderParameter("shift_uv", shiftUv);
            _rightSourceMaterial.SetShaderParameter("center_offset_uv", centerUv);
            _rightSourceMaterial.SetShaderParameter("zoom_uv", safeZoom);
            _rightSourceMaterial.SetShaderParameter("mirror_h", MirrorSourceHorizontally);
        }
    }

    private void RefreshMainDisplayTexture()
    {
        if (_mainDisplayMaterial == null)
            return;

        Texture2D tex = null;
        if (UseLeftEyeForMainDisplay)
        {
            if (_leftViewport != null)
                tex = _leftViewport.GetTexture();
        }
        else
        {
            if (_rightViewport != null)
                tex = _rightViewport.GetTexture();
        }

        _mainDisplayMaterial.AlbedoTexture = tex ?? _blackFallbackTexture;
    }

    private static bool TryActivateFeed(CameraFeed feed)
    {
        if (feed == null)
            return false;

        try
        {
            if (!feed.FeedIsActive)
            {
                if (!TryPrepareFeedFormat(feed))
                    return false;

                feed.FeedIsActive = true;
            }

            return feed.FeedIsActive;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryPrepareFeedFormat(CameraFeed feed)
    {
        try
        {
            Variant formatsVariant = feed.Call("get_formats");
            if (formatsVariant.VariantType != Variant.Type.Array)
                return false;

            var formats = formatsVariant.AsGodotArray();
            if (formats.Count == 0)
                return false;

            Variant firstFormat = formats[0];
            if (firstFormat.VariantType != Variant.Type.Dictionary)
                return false;

            feed.Call("set_format", 0, firstFormat.AsGodotDictionary());
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void WarnSourceOnce(string message)
    {
        ulong now = Time.GetTicksMsec();
        if (now < _nextSourceWarnAtMs)
            return;

        _nextSourceWarnAtMs = now + SOURCE_WARN_THROTTLE_MS;
        GD.PrintErr(message);
    }

    private static void RequestCameraPermissionIfNeeded()
    {
        try
        {
            if (OS.GetName() == "Android")
                OS.RequestPermission("android.permission.CAMERA");
        }
        catch
        {
            // Sessiz geç.
        }
    }
}
