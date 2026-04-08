import { useState } from "react";

// ── Dosya içerikleri ──────────────────────────────────────────────────────────

const FILES: { label: string; path: string; lang: string; content: string }[] = [
  {
    label: "project.godot",
    path: "project.godot",
    lang: "ini",
    content: `; Engine configuration file.
config_version=5

[application]

config/name="Quest3"
run/main_scene="res://scenes/StereoViewScene.tscn"
config/features=PackedStringArray("4.6", "C#", "Forward Plus")
config/icon="res://icon.svg"

[dotnet]

project/assembly_name="Quest3"

[physics]

3d/physics_engine="Jolt Physics"

[rendering]

rendering_device/driver.windows="d3d12"
textures/vram_compression/import_etc2_astc=true`,
  },
  {
    label: "Quest3.csproj",
    path: "Quest3.csproj",
    lang: "xml",
    content: `<Project Sdk="Godot.NET.Sdk/4.6.0">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <EnableDynamicLoading>true</EnableDynamicLoading>
    <RootNamespace>Quest3</RootNamespace>
    <Nullable>disable</Nullable>
  </PropertyGroup>
</Project>`,
  },
  {
    label: "scenes/StereoViewScene.tscn",
    path: "scenes/StereoViewScene.tscn",
    lang: "gdscene",
    content: `[gd_scene format=3 uid="uid://fbrnmf23wfff"]

[ext_resource type="Script" path="res://scripts/stereo/Stereo3DViewer.cs" id="1_stereo"]

; ── QuadMesh kaynakları ──────────────────────────────────────────────────────
; Sol göz, sağ göz ve ana ekran için ayrı QuadMesh.
; Boyutlar runtime'da Stereo3DViewer tarafından hesaplanır.

[sub_resource type="QuadMesh" id="1_quad_left"]
size = Vector2(1, 1)

[sub_resource type="QuadMesh" id="2_quad_right"]
size = Vector2(1, 1)

[sub_resource type="QuadMesh" id="3_quad_main"]
size = Vector2(1, 1)

; ── Kök sahne ────────────────────────────────────────────────────────────────
[node name="StereoViewScene" type="Node3D"]
script = ExtResource("1_stereo")
StartOnReady               = true
EnableLocalCameraFallback  = false
OutputWidth                = 0
OutputHeight               = 0
MatchWindowSizeAtRuntime   = true
MeshDistanceMeters         = 2.0
EyePlaneFillScale          = 1.15
MainPlaneFillScale         = 1.2
UseLeftEyeForMainDisplay   = true

; ── Ana ekran kamerası (tablet / default viewport) ───────────────────────────
[node name="MainDisplayCamera" type="Camera3D" parent="."]
current = true
fov     = 75.0

; ── Ana ekran mesh (sol göz viewport çıktısı buraya basılır) ─────────────────
[node name="MainDisplayMesh" type="MeshInstance3D" parent="."]
mesh     = SubResource("3_quad_main")
position = Vector3(0, 0, -2)

; ── Sol göz SubViewport ───────────────────────────────────────────────────────
; Her iki viewport da aynı 3D origin'de oturur;
; yalnızca shader'daki shift_uv parametresi farklıdır.
[node name="LeftEyeViewport" type="SubViewport" parent="."]
size                     = Vector2i(1280, 720)
render_target_update_mode = 4

[node name="LeftEyeRoot" type="Node3D" parent="LeftEyeViewport"]

[node name="LeftEyeCamera" type="Camera3D" parent="LeftEyeViewport/LeftEyeRoot"]
current = true
fov     = 75.0

[node name="LeftEyeVideoMesh" type="MeshInstance3D" parent="LeftEyeViewport/LeftEyeRoot"]
mesh     = SubResource("1_quad_left")
position = Vector3(0, 0, -2)

; ── Sağ göz SubViewport ───────────────────────────────────────────────────────
[node name="RightEyeViewport" type="SubViewport" parent="."]
size                     = Vector2i(1280, 720)
render_target_update_mode = 4

[node name="RightEyeRoot" type="Node3D" parent="RightEyeViewport"]

[node name="RightEyeCamera" type="Camera3D" parent="RightEyeViewport/RightEyeRoot"]
current = true
fov     = 75.0

[node name="RightEyeVideoMesh" type="MeshInstance3D" parent="RightEyeViewport/RightEyeRoot"]
mesh     = SubResource("2_quad_right")
position = Vector3(0, 0, -2)`,
  },
  {
    label: "scripts/stereo/Stereo3DViewer.cs",
    path: "scripts/stereo/Stereo3DViewer.cs",
    lang: "csharp",
    content: `using Godot;
using System;

/// <summary>
/// Quest3 External-Texture-Only Stereo Viewer
/// ─────────────────────────────────────────────────────────────────────────────
/// MİMARİ:
///   • Sahnede iki SubViewport (LeftEyeViewport / RightEyeViewport) bulunur.
///   • Her iki viewport da tam olarak aynı 3D origin'de durur; aralarında
///     fiziksel kamera offseti YOKTUR. Stereo fark yalnızca shader'daki
///     shift_uv değeriyle sağlanır (texture-space shift).
///   • Android'de Engine.HasSingleton("QuestExternalTexture") true ise
///     singleton.get_camera_texture() ile Texture2D alınır ve doğrudan
///     her iki göz mesh'inin ShaderMaterial'ine bağlanır.
///   • Fallback tamamen kapalıdır (EnableLocalCameraFallback = false).
///   • Tabletteki/default viewport: sol göz SubViewport çıktısı full-screen
///     MainDisplayMesh'e basılır. 2D UI veya overlay öğesi yoktur.
///   • UDP / GStreamer / ağ katmanı yoktur; sıfır ek gecikme.
/// </summary>
public partial class Stereo3DViewer : Node3D
{
    // ── Export: Kaynak ────────────────────────────────────────────────────────
    [ExportGroup("Camera Source")]
    [Export] public bool   StartOnReady                = true;
    [Export] public bool   EnableLocalCameraFallback   = false;
    [Export] public string AndroidCameraSingletonName  = "QuestExternalTexture";

    // ── Export: Stereo parametreleri ─────────────────────────────────────────
    [ExportGroup("Stereo View")]
    /// <summary>
    /// Sağ göz için +, sol göz için − uygulanır (piksel cinsinden).
    /// External texture tek kare içerdiğinden bu değer
    /// gözler arası küçük perspektif farkını simüle eder.
    /// </summary>
    [Export] public float EyeTextureShiftPixels  = 1.5f;
    [Export] public float EyeTextureZoom         = 1.0f;
    [Export] public float CenterOffsetPixels     = 0.0f;
    [Export] public bool  MirrorSourceHorizontally = false;

    // ── Export: Çıkış / Geometri ──────────────────────────────────────────────
    [ExportGroup("Output")]
    [Export] public int   OutputWidth              = 0;
    [Export] public int   OutputHeight             = 0;
    [Export] public bool  MatchWindowSizeAtRuntime = true;
    [Export] public float MeshDistanceMeters       = 2.0f;
    [Export(PropertyHint.Range, "1.0,3.0,0.01")] public float EyePlaneFillScale  = 1.15f;
    [Export(PropertyHint.Range, "1.0,3.0,0.01")] public float MainPlaneFillScale = 1.2f;
    [Export] public bool  UseLeftEyeForMainDisplay = true;

    // ── Export: Sahne yolları ─────────────────────────────────────────────────
    [ExportGroup("Node Paths")]
    [Export] public NodePath LeftEyeViewportPath  = new("LeftEyeViewport");
    [Export] public NodePath RightEyeViewportPath = new("RightEyeViewport");
    [Export] public NodePath LeftEyeCameraPath    = new("LeftEyeViewport/LeftEyeRoot/LeftEyeCamera");
    [Export] public NodePath RightEyeCameraPath   = new("RightEyeViewport/RightEyeRoot/RightEyeCamera");
    [Export] public NodePath LeftEyeMeshPath      = new("LeftEyeViewport/LeftEyeRoot/LeftEyeVideoMesh");
    [Export] public NodePath RightEyeMeshPath     = new("RightEyeViewport/RightEyeRoot/RightEyeVideoMesh");
    [Export] public NodePath MainDisplayCameraPath = new("MainDisplayCamera");
    [Export] public NodePath MainDisplayMeshPath   = new("MainDisplayMesh");

    // ── Özel alanlar ─────────────────────────────────────────────────────────
    private SubViewport    _leftViewport;
    private SubViewport    _rightViewport;
    private Camera3D       _leftEyeCamera;
    private Camera3D       _rightEyeCamera;
    private MeshInstance3D _leftEyeMesh;
    private MeshInstance3D _rightEyeMesh;
    private Camera3D       _mainDisplayCamera;
    private MeshInstance3D _mainDisplayMesh;

    private ShaderMaterial    _leftSourceMaterial;
    private ShaderMaterial    _rightSourceMaterial;
    private StandardMaterial3D _mainDisplayMaterial;
    private ImageTexture      _blackFallback;

    private bool    _sessionActive;
    private bool    _sourceConnected;
    private float   _reconnectTimer;
    private Vector2I _lastViewportSize = Vector2I.Zero;
    private ulong   _nextWarnMs;

    private const float RECONNECT_SEC    = 0.5f;
    private const ulong WARN_THROTTLE_MS = 3000;

    // ── Shader: external texture → quad ──────────────────────────────────────
    private const string SOURCE_SHADER = @"
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D source_tex : source_color;
uniform float shift_uv         = 0.0;
uniform float center_offset_uv = 0.0;
uniform float zoom_uv          = 1.0;
uniform bool  mirror_h         = false;

void fragment() {
    vec2 uv = UV;
    if (mirror_h) uv.x = 1.0 - uv.x;

    // Merkez-tabanlı zoom + yatay kaydırma (stereo shift)
    uv = (uv - vec2(0.5)) / max(zoom_uv, 0.0001)
       + vec2(0.5 + center_offset_uv + shift_uv, 0.5);

    // UV sınır dışına çıkarsa siyah göster (artifact yok)
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        ALBEDO = vec3(0.0);
        ALPHA  = 1.0;
        return;
    }

    vec4 src = texture(source_tex, uv);
    ALBEDO = src.rgb;
    ALPHA  = 1.0;
}
";

    // ── _Ready ────────────────────────────────────────────────────────────────
    public override void _Ready()
    {
        RequestCameraPermission();
        ResolveNodes();
        BuildMaterials();
        SyncGeometry(force: true);
        if (StartOnReady) StartSession();
    }

    // ── Oturum ───────────────────────────────────────────────────────────────
    public void StartSession()
    {
        if (_sessionActive) return;
        _sessionActive   = true;
        _sourceConnected = TryConnect();
        if (!_sourceConnected) ApplyTexture(null);
    }

    public void StopSession()
    {
        _sessionActive   = false;
        _sourceConnected = false;
        _reconnectTimer  = 0f;
        ApplyTexture(null);
    }

    // ── _Process ──────────────────────────────────────────────────────────────
    public override void _Process(double delta)
    {
        SyncGeometry(force: false);
        UpdateShaderParams();
        FlushMainDisplay();

        if (!_sessionActive || _sourceConnected) return;

        _reconnectTimer += (float)delta;
        if (_reconnectTimer < RECONNECT_SEC) return;
        _reconnectTimer  = 0f;
        _sourceConnected = TryConnect();
    }

    public override void _ExitTree() => StopSession();

    // ── Sahne nodelarını çöz ──────────────────────────────────────────────────
    private void ResolveNodes()
    {
        _leftViewport      = GetNodeOrNull<SubViewport>(LeftEyeViewportPath);
        _rightViewport     = GetNodeOrNull<SubViewport>(RightEyeViewportPath);
        _leftEyeCamera     = GetNodeOrNull<Camera3D>(LeftEyeCameraPath);
        _rightEyeCamera    = GetNodeOrNull<Camera3D>(RightEyeCameraPath);
        _leftEyeMesh       = GetNodeOrNull<MeshInstance3D>(LeftEyeMeshPath);
        _rightEyeMesh      = GetNodeOrNull<MeshInstance3D>(RightEyeMeshPath);
        _mainDisplayCamera = GetNodeOrNull<Camera3D>(MainDisplayCameraPath);
        _mainDisplayMesh   = GetNodeOrNull<MeshInstance3D>(MainDisplayMeshPath);

        if (_leftViewport  == null || _rightViewport  == null ||
            _leftEyeMesh   == null || _rightEyeMesh   == null ||
            _mainDisplayMesh == null || _mainDisplayCamera == null)
        {
            GD.PrintErr("[Stereo3D] Eksik sahne nodeları – StereoViewScene.tscn yapısını kontrol et.");
        }
    }

    // ── Materyal / mesh kurulumu ──────────────────────────────────────────────
    private void BuildMaterials()
    {
        var shader = new Shader { Code = SOURCE_SHADER };

        _leftSourceMaterial  = new ShaderMaterial { Shader = shader };
        _rightSourceMaterial = new ShaderMaterial { Shader = shader };

        _mainDisplayMaterial = new StandardMaterial3D
        {
            ShadingMode = BaseMaterial3D.ShadingModeEnum.Unshaded,
            CullMode    = BaseMaterial3D.CullModeEnum.Disabled,
        };

        AssignMaterial(_leftEyeMesh,    _leftSourceMaterial);
        AssignMaterial(_rightEyeMesh,   _rightSourceMaterial);
        AssignMaterial(_mainDisplayMesh, _mainDisplayMaterial);

        EnsureQuad(_leftEyeMesh);
        EnsureQuad(_rightEyeMesh);
        EnsureQuad(_mainDisplayMesh);

        // 2×2 siyah fallback texture (bağlantı yokken artifact engeller)
        var img = Image.CreateEmpty(2, 2, false, Image.Format.Rgb8);
        img.Fill(Colors.Black);
        _blackFallback = ImageTexture.CreateFromImage(img);

        UpdateShaderParams();
    }

    private static void AssignMaterial(MeshInstance3D m, Material mat)
    {
        if (m != null) m.MaterialOverride = mat;
    }

    private static void EnsureQuad(MeshInstance3D m)
    {
        if (m != null && m.Mesh is not QuadMesh)
            m.Mesh = new QuadMesh();
    }

    // ── Viewport + geometri senkronizasyonu ──────────────────────────────────
    private void SyncGeometry(bool force)
    {
        var size = ResolveSize();
        if (!force && size == _lastViewportSize) return;
        _lastViewportSize = size;

        ConfigViewport(_leftViewport,  size);
        ConfigViewport(_rightViewport, size);

        float fovL = _leftEyeCamera?.Fov  ?? _mainDisplayCamera?.Fov ?? 75f;
        float fovR = _rightEyeCamera?.Fov ?? _mainDisplayCamera?.Fov ?? 75f;
        float fovM = _mainDisplayCamera?.Fov ?? 75f;

        // Her iki kamera da tam olarak aynı pozisyonda → stereo shift shader'da
        ZeroCamera(_leftEyeCamera);
        ZeroCamera(_rightEyeCamera);
        ZeroCamera(_mainDisplayCamera);
        if (_mainDisplayCamera != null) _mainDisplayCamera.Current = true;

        PlaceMesh(_leftEyeMesh,    PlaneSize(size, MeshDistanceMeters, fovL, EyePlaneFillScale),  MeshDistanceMeters);
        PlaceMesh(_rightEyeMesh,   PlaneSize(size, MeshDistanceMeters, fovR, EyePlaneFillScale),  MeshDistanceMeters);
        PlaceMesh(_mainDisplayMesh, PlaneSize(size, MeshDistanceMeters, fovM, MainPlaneFillScale), MeshDistanceMeters);

        FlushMainDisplay();
    }

    private static void ConfigViewport(SubViewport vp, Vector2I size)
    {
        if (vp == null) return;
        vp.Size                   = size;
        vp.RenderTargetUpdateMode = SubViewport.UpdateMode.Always;
        vp.TransparentBg          = false;
        vp.World3D              ??= new World3D();
    }

    private static void ZeroCamera(Camera3D cam)
    {
        if (cam == null) return;
        cam.Position = Vector3.Zero;
        cam.Rotation = Vector3.Zero;
    }

    private Vector2I ResolveSize()
    {
        if (MatchWindowSizeAtRuntime)
        {
            var ws = DisplayServer.WindowGetSize();
            if (ws.X > 0 && ws.Y > 0) return ws;
        }
        if (OutputWidth > 0 && OutputHeight > 0)
            return new Vector2I(OutputWidth, OutputHeight);
        var s = DisplayServer.WindowGetSize();
        return (s.X > 0 && s.Y > 0) ? s : new Vector2I(1280, 720);
    }

    private static Vector2 PlaneSize(Vector2I res, float dist, float fov, float fill)
    {
        float d  = Mathf.Max(0.01f, dist);
        float f  = Mathf.Clamp(fov, 1f, 170f);
        float sc = Mathf.Max(1f, fill);
        float h  = 2f * d * Mathf.Tan(Mathf.DegToRad(f) * 0.5f);
        float ar = Mathf.Max(0.01f, (float)res.X / Mathf.Max(1f, res.Y));
        return new Vector2(h * ar * sc, h * sc);
    }

    private static void PlaceMesh(MeshInstance3D m, Vector2 sz, float dist)
    {
        if (m == null) return;
        if (m.Mesh is not QuadMesh q) { q = new QuadMesh(); m.Mesh = q; }
        q.Size       = sz;
        m.Position   = new Vector3(0f, 0f, -Mathf.Max(0.01f, dist));
        m.Rotation   = Vector3.Zero;
        m.CastShadow = GeometryInstance3D.ShadowCastingSetting.Off;
    }

    // ── Texture bağlama ───────────────────────────────────────────────────────
    private bool TryConnect()
    {
        var tex = GetAndroidTexture();
        if (tex == null)
        {
            ThrottleWarn("[Stereo3D] Android singleton 'QuestExternalTexture' bulunamadı; fallback kapalı.");
            return false;
        }
        ApplyTexture(tex);
        GD.Print("[Stereo3D] External texture bağlandı.");
        return true;
    }

    private Texture2D GetAndroidTexture()
    {
        if (OS.GetName() != "Android")                          return null;
        if (string.IsNullOrWhiteSpace(AndroidCameraSingletonName)) return null;
        if (!Engine.HasSingleton(AndroidCameraSingletonName))   return null;

        try
        {
            var singleton = Engine.GetSingleton(AndroidCameraSingletonName);
            if (singleton == null || !singleton.HasMethod("get_camera_texture")) return null;

            var result = singleton.Call("get_camera_texture");
            if (result.VariantType != Variant.Type.Object) return null;
            return result.AsGodotObject() as Texture2D;
        }
        catch (Exception e)
        {
            GD.PrintErr("[Stereo3D] Singleton okuma hatası: " + e.Message);
            return null;
        }
    }

    private void ApplyTexture(Texture2D src)
    {
        var safe = src ?? _blackFallback;
        _leftSourceMaterial?.SetShaderParameter("source_tex",  safe);
        _rightSourceMaterial?.SetShaderParameter("source_tex", safe);
    }

    // ── Shader parametrelerini güncelle ──────────────────────────────────────
    private void UpdateShaderParams()
    {
        int   w      = Mathf.Max(1, _lastViewportSize.X > 0 ? _lastViewportSize.X : ResolveSize().X);
        float shift  = EyeTextureShiftPixels / w;
        float center = CenterOffsetPixels    / w;
        float zoom   = Mathf.Max(1f, EyeTextureZoom);

        SetEyeParams(_leftSourceMaterial,  -shift, center, zoom);
        SetEyeParams(_rightSourceMaterial,  shift, center, zoom);
    }

    private void SetEyeParams(ShaderMaterial m, float shift, float center, float zoom)
    {
        if (m == null) return;
        m.SetShaderParameter("shift_uv",         shift);
        m.SetShaderParameter("center_offset_uv", center);
        m.SetShaderParameter("zoom_uv",          zoom);
        m.SetShaderParameter("mirror_h",         MirrorSourceHorizontally);
    }

    // ── Ana ekrana sol/sağ göz viewport çıktısını bas ────────────────────────
    private void FlushMainDisplay()
    {
        if (_mainDisplayMaterial == null) return;
        var vp  = UseLeftEyeForMainDisplay ? _leftViewport : _rightViewport;
        var tex = vp?.GetTexture() ?? (Texture2D)_blackFallback;
        _mainDisplayMaterial.AlbedoTexture = tex;
    }

    // ── Yardımcı ─────────────────────────────────────────────────────────────
    private void ThrottleWarn(string msg)
    {
        ulong now = Time.GetTicksMsec();
        if (now < _nextWarnMs) return;
        _nextWarnMs = now + WARN_THROTTLE_MS;
        GD.PrintErr(msg);
    }

    private static void RequestCameraPermission()
    {
        try { if (OS.GetName() == "Android") OS.RequestPermission("android.permission.CAMERA"); }
        catch { /* sessiz geç */ }
    }
}`,
  },
  {
    label: "export_presets.cfg (özet)",
    path: "export_presets.cfg",
    lang: "ini",
    content: `[preset.0]

name="Quest3"
platform="Android"
runnable=true
export_path="build/android/Quest3-debug.apk"

[preset.0.options]

gradle_build/use_gradle_build=true
architectures/arm64-v8a=true
package/unique_name="com.bnfnc.quest3"
package/name="Quest3"
package/signed=true
screen/immersive_mode=true
xr_features/xr_mode=0          ; VR runtime açık bırakın (OpenXR plugin gerekirse 1)
screen/background_color=Color(0, 0, 0, 1)

permissions/camera=true         ; Kamera izni zorunlu

dotnet/android_use_linux_bionic=false
dotnet/include_debug_symbols=true`,
  },
];

// ── Mimari kartları ───────────────────────────────────────────────────────────

const ARCH_STEPS = [
  {
    icon: "📱",
    title: "Java Singleton (Android Plugin)",
    desc: 'QuestExternalTexture singleton, Quest3 kamera donanımından ham frame\'i OpenGL ExternalTexture olarak tutar. Godot\'dan Engine.GetSingleton("QuestExternalTexture").Call("get_camera_texture") ile Texture2D olarak alınır.',
    color: "from-violet-600 to-violet-800",
  },
  {
    icon: "🎮",
    title: "Stereo3DViewer._Ready()",
    desc: "Node3D kökü başlarken sahne nodeları çözülür, shader materialler oluşturulur, SubViewport boyutları pencere boyutuna eşitlenir, mesh geometry frustum hesabıyla ölçeklenir.",
    color: "from-blue-600 to-blue-800",
  },
  {
    icon: "👁️",
    title: "İki SubViewport – Tek Origin",
    desc: "LeftEyeViewport ve RightEyeViewport tam aynı noktada bulunur. Fiziksel kamera offseti yoktur. Stereo fark yalnızca shader'daki shift_uv (±EyeTextureShiftPixels/width) ile sağlanır.",
    color: "from-cyan-600 to-cyan-800",
  },
  {
    icon: "🖼️",
    title: "External Texture → QuadMesh",
    desc: "get_camera_texture() ile alınan Texture2D doğrudan her iki göz mesh'inin ShaderMaterial.source_tex parametresine atanır. UDP/GStreamer/network katmanı yoktur; sıfır ek gecikme.",
    color: "from-emerald-600 to-emerald-800",
  },
  {
    icon: "🖥️",
    title: "Tablet / Default Viewport",
    desc: "MainDisplayCamera sahnenin gerçek kamerası. MainDisplayMesh, her frame UseLeftEyeForMainDisplay seçimine göre sol ya da sağ SubViewport.GetTexture() ile beslenir. 2D overlay/UI/çizgi yoktur.",
    color: "from-amber-600 to-amber-800",
  },
  {
    icon: "🥽",
    title: "Quest3 VR Çıkışı",
    desc: "OpenXR runtime devreye girdiğinde sol/sağ göz SubViewport'ları ayrı lens distortion ile render edilir. Mesh 3D space'te olduğu için VR compositor doğrudan kullanır.",
    color: "from-rose-600 to-rose-800",
  },
];

// ── Yardımcı: kopyala ─────────────────────────────────────────────────────────

function useCopy() {
  const [copied, setCopied] = useState<string | null>(null);
  const copy = (id: string, text: string) => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(id);
      setTimeout(() => setCopied(null), 1800);
    });
  };
  return { copied, copy };
}

// ── Syntax highlight (minimal, CSS-class tabanlı) ─────────────────────────────

function highlight(code: string, lang: string): React.ReactNode {
  if (lang === "csharp") {
    const lines = code.split("\n");
    return lines.map((line, i) => {
      const isComment  = /^\s*(\/\/|\/\*|\*)/.test(line);
      const isKeyword  = /\b(public|private|static|override|void|bool|int|float|string|var|new|return|if|null|try|catch|using|partial|class|const)\b/.test(line);
      const isAttr     = /^\s*\[/.test(line);
      const isString   = /\"[^\"]*\"/.test(line);

      let cls = "text-slate-300";
      if (isComment) cls = "text-slate-500 italic";
      else if (isAttr) cls = "text-yellow-400";
      else if (isKeyword && !isComment) cls = "text-blue-300";

      return (
        <span key={i} className={`block ${cls}`}>
          {isString && !isComment
            ? line.replace(/"([^"]*)"/g, (_, g) => `\x00${g}\x01`)
                  .split("\x00")
                  .map((part, pi) =>
                    pi % 2 === 1
                      ? <span key={pi} className="text-orange-300">"{part}"</span>
                      : part
                  )
            : line}
        </span>
      );
    });
  }

  return code.split("\n").map((line, i) => {
    const isComment = line.trim().startsWith(";") || line.trim().startsWith("//");
    return (
      <span key={i} className={`block ${isComment ? "text-slate-500 italic" : "text-slate-200"}`}>
        {line}
      </span>
    );
  });
}

// ── Ana bileşen ───────────────────────────────────────────────────────────────

export default function App() {
  const [activeFile, setActiveFile] = useState(0);
  const { copied, copy } = useCopy();

  const file = FILES[activeFile];

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 font-mono">
      {/* Header */}
      <header className="sticky top-0 z-50 bg-slate-900/95 backdrop-blur border-b border-slate-700/60 px-4 py-3 flex items-center gap-3">
        <span className="text-2xl">🥽</span>
        <div>
          <h1 className="text-base font-bold tracking-tight text-white leading-none">
            Quest3 · External Texture Only · Stereo 3D Viewer
          </h1>
          <p className="text-xs text-slate-400 mt-0.5">
            Godot 4.6 · C# · Android · VR · Minimum Gecikme
          </p>
        </div>
        <div className="ml-auto flex items-center gap-2">
          <span className="hidden sm:flex items-center gap-1.5 text-xs bg-emerald-900/50 text-emerald-300 border border-emerald-700/50 px-2.5 py-1 rounded-full">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
            Fallback Kapalı
          </span>
          <span className="hidden sm:flex items-center gap-1.5 text-xs bg-violet-900/50 text-violet-300 border border-violet-700/50 px-2.5 py-1 rounded-full">
            <span className="w-1.5 h-1.5 rounded-full bg-violet-400" />
            External Texture Only
          </span>
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-4 py-8 space-y-10">

        {/* Mimari akış kartları */}
        <section>
          <h2 className="text-sm font-semibold uppercase tracking-widest text-slate-400 mb-4">
            Mimari Akış
          </h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
            {ARCH_STEPS.map((s, i) => (
              <div
                key={i}
                className={`relative rounded-xl p-4 bg-gradient-to-br ${s.color} bg-opacity-20 border border-white/10 overflow-hidden`}
              >
                <div className="absolute top-2 right-3 text-xs text-white/25 font-bold">0{i + 1}</div>
                <div className="text-2xl mb-2">{s.icon}</div>
                <h3 className="text-sm font-semibold text-white mb-1">{s.title}</h3>
                <p className="text-xs text-white/70 leading-relaxed">{s.desc}</p>
              </div>
            ))}
          </div>
        </section>

        {/* Mimari şema */}
        <section>
          <h2 className="text-sm font-semibold uppercase tracking-widest text-slate-400 mb-4">
            Sahne Ağacı
          </h2>
          <div className="bg-slate-900 border border-slate-700/60 rounded-xl p-5 overflow-x-auto">
            <pre className="text-xs leading-6 text-slate-300 whitespace-pre">{`StereoViewScene  [Node3D]  ← Stereo3DViewer.cs
│
├── MainDisplayCamera  [Camera3D]  current=true  fov=75
│     └── MainDisplayMesh  [MeshInstance3D]  QuadMesh
│           └── StandardMaterial3D ← AlbedoTexture = LeftEyeViewport.GetTexture()
│                                    (her frame güncellenir, 2D UI yok)
│
├── LeftEyeViewport   [SubViewport]  UpdateMode=Always
│   └── LeftEyeRoot   [Node3D]  position=(0,0,0)  ← Sağ göz ile AYNI NOKTA
│       ├── LeftEyeCamera   [Camera3D]  fov=75
│       └── LeftEyeVideoMesh [MeshInstance3D]  QuadMesh
│             └── ShaderMaterial  shift_uv = -EyeShift/W
│                                 source_tex = QuestExternalTexture.get_camera_texture()
│
└── RightEyeViewport  [SubViewport]  UpdateMode=Always
    └── RightEyeRoot  [Node3D]  position=(0,0,0)  ← Sol göz ile AYNI NOKTA
        ├── RightEyeCamera  [Camera3D]  fov=75
        └── RightEyeVideoMesh [MeshInstance3D]  QuadMesh
              └── ShaderMaterial  shift_uv = +EyeShift/W
                                  source_tex = QuestExternalTexture.get_camera_texture()

Android Plugin (Java) ──→ JNI ──→ Engine.GetSingleton("QuestExternalTexture")
                                         └── .Call("get_camera_texture") → Texture2D
`}</pre>
          </div>
        </section>

        {/* Önemli notlar */}
        <section className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div className="bg-amber-950/40 border border-amber-700/40 rounded-xl p-4">
            <h3 className="text-sm font-bold text-amber-300 mb-2">⚡ Gecikme – Neden Minimum?</h3>
            <ul className="text-xs text-amber-200/80 space-y-1 list-disc list-inside">
              <li>Network katmanı yok (UDP/TCP/GStreamer yok)</li>
              <li>Encode/decode yok – ham OpenGL texture doğrudan bağlanır</li>
              <li>Her frame SubViewport.UpdateMode.Always ile anında render</li>
              <li>Shader sadece UV kaydırma yapar, pixel başına 1 texture fetch</li>
            </ul>
          </div>
          <div className="bg-cyan-950/40 border border-cyan-700/40 rounded-xl p-4">
            <h3 className="text-sm font-bold text-cyan-300 mb-2">🖥️ Tablet Test Modu</h3>
            <ul className="text-xs text-cyan-200/80 space-y-1 list-disc list-inside">
              <li>MainDisplayCamera default viewport → tam ekran</li>
              <li>2D overlay, çizgi, split-screen yok</li>
              <li>Sol göz SubViewport çıktısı tek görüntü olarak gösterilir</li>
              <li>Android singleton yoksa siyah ekran (fallback kapalı)</li>
            </ul>
          </div>
          <div className="bg-violet-950/40 border border-violet-700/40 rounded-xl p-4">
            <h3 className="text-sm font-bold text-violet-300 mb-2">🥽 Quest3 VR Modu</h3>
            <ul className="text-xs text-violet-200/80 space-y-1 list-disc list-inside">
              <li>OpenXR runtime sol/sağ SubViewport'ı ayrı lens distortion ile render eder</li>
              <li>Her iki mesh 3D space'te → VR compositor doğrudan kullanır</li>
              <li>EyeTextureShiftPixels ile stereo derinlik ayarı yapılır</li>
            </ul>
          </div>
          <div className="bg-rose-950/40 border border-rose-700/40 rounded-xl p-4">
            <h3 className="text-sm font-bold text-rose-300 mb-2">⚠️ Geliştirici Notları</h3>
            <ul className="text-xs text-rose-200/80 space-y-1 list-disc list-inside">
              <li>Ubuntu 22 TR + Godot 4.6 + .NET 8 ile geliştirildi</li>
              <li>Export: arm64-v8a, gradle build, immersive mode</li>
              <li>Java köprüsü olmadan Android'de siyah ekran görünür (bu normaldir)</li>
              <li>EnableLocalCameraFallback = false → kesinlikle kapalı</li>
            </ul>
          </div>
        </section>

        {/* Dosya gezgini */}
        <section>
          <h2 className="text-sm font-semibold uppercase tracking-widest text-slate-400 mb-4">
            Proje Dosyaları
          </h2>
          <div className="flex flex-col lg:flex-row gap-0 rounded-xl overflow-hidden border border-slate-700/60">
            {/* Sidebar */}
            <div className="lg:w-64 bg-slate-900 border-b lg:border-b-0 lg:border-r border-slate-700/60 flex lg:flex-col overflow-x-auto lg:overflow-x-visible">
              {FILES.map((f, i) => (
                <button
                  key={i}
                  onClick={() => setActiveFile(i)}
                  className={`flex-shrink-0 lg:flex-shrink text-left px-4 py-3 text-xs transition-colors border-b border-slate-800/60 last:border-b-0 truncate ${
                    i === activeFile
                      ? "bg-slate-700/70 text-white font-semibold"
                      : "text-slate-400 hover:bg-slate-800/50 hover:text-slate-200"
                  }`}
                >
                  <span className="mr-1.5 opacity-60">
                    {f.lang === "csharp" ? "⚙️" : f.lang === "xml" ? "📦" : f.lang === "gdscene" ? "🎬" : "📄"}
                  </span>
                  {f.label}
                </button>
              ))}
            </div>

            {/* Kod paneli */}
            <div className="flex-1 bg-slate-950 flex flex-col">
              <div className="flex items-center justify-between px-4 py-2.5 border-b border-slate-700/60 bg-slate-900/50">
                <span className="text-xs text-slate-400">{file.path}</span>
                <button
                  onClick={() => copy(file.path, file.content)}
                  className={`text-xs px-3 py-1 rounded-md transition-all ${
                    copied === file.path
                      ? "bg-emerald-600 text-white"
                      : "bg-slate-700 hover:bg-slate-600 text-slate-300"
                  }`}
                >
                  {copied === file.path ? "✓ Kopyalandı" : "Kopyala"}
                </button>
              </div>
              <div className="overflow-auto flex-1 max-h-[520px]">
                <pre className="p-4 text-xs leading-5 min-w-max">
                  {highlight(file.content, file.lang)}
                </pre>
              </div>
            </div>
          </div>
        </section>

        {/* Java köprüsü rehberi */}
        <section>
          <h2 className="text-sm font-semibold uppercase tracking-widest text-slate-400 mb-4">
            Java Köprüsü – Minimum Gereksinim
          </h2>
          <div className="bg-slate-900 border border-slate-700/60 rounded-xl overflow-hidden">
            <div className="flex items-center justify-between px-4 py-2.5 border-b border-slate-700/60 bg-slate-800/50">
              <span className="text-xs text-slate-400">QuestExternalTexture.java (şablon)</span>
              <button
                onClick={() => copy("java", JAVA_BRIDGE)}
                className={`text-xs px-3 py-1 rounded-md transition-all ${
                  copied === "java"
                    ? "bg-emerald-600 text-white"
                    : "bg-slate-700 hover:bg-slate-600 text-slate-300"
                }`}
              >
                {copied === "java" ? "✓ Kopyalandı" : "Kopyala"}
              </button>
            </div>
            <pre className="p-4 text-xs leading-5 overflow-auto max-h-80 text-slate-300 whitespace-pre">
              {JAVA_BRIDGE}
            </pre>
          </div>
        </section>

      </main>

      <footer className="border-t border-slate-800 px-4 py-4 text-center text-xs text-slate-600 mt-10">
        Quest3 · External Texture Only · Godot 4.6 C# · arm64-v8a · Ubuntu 22 TR
      </footer>
    </div>
  );
}

// ── Java köprüsü şablonu ──────────────────────────────────────────────────────

const JAVA_BRIDGE = `package com.bnfnc.quest3;

import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;

/**
 * QuestExternalTexture – Godot Android Plugin
 *
 * Bu sınıf Engine.GetSingleton("QuestExternalTexture") ile erişilir.
 * get_camera_texture() metodu Godot'a bir RID (ExternalTexture) döner;
 * C# tarafında bu otomatik olarak Texture2D'ye çevrilir.
 *
 * Quest3 kamera API'si (com.oculus.camera veya Android CameraX)
 * ile SurfaceTexture elde edip OpenGL ExternalTexture'a bağlayın.
 */
public class QuestExternalTexture extends GodotPlugin {

    private int   _glTextureId   = -1;
    private long  _godotTexId    = 0;   // Godot RenderingServer texture RID
    private SurfaceTexture _surfaceTexture;

    public QuestExternalTexture(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "QuestExternalTexture";
    }

    /**
     * Godot C# tarafı bu metodu çağırır:
     *   singleton.Call("get_camera_texture") → Texture2D
     *
     * Dönüş değeri: RenderingServer'a kayıtlı ExternalTexture RID
     * (Godot otomatik olarak Texture2D nesnesine sarar)
     */
    public long get_camera_texture() {
        if (_glTextureId == -1) {
            initGLTexture();
        }
        // RID'yi Godot'a döndür
        return _godotTexId;
    }

    private void initGLTexture() {
        int[] ids = new int[1];
        GLES20.glGenTextures(1, ids, 0);
        _glTextureId = ids[0];

        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, _glTextureId);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);

        _surfaceTexture = new SurfaceTexture(_glTextureId);
        _surfaceTexture.setOnFrameAvailableListener(st -> st.updateTexImage());

        // TODO: SurfaceTexture'ı Quest kamera API'sine bağla
        // openCamera(_surfaceTexture);

        // TODO: RenderingServer'a kaydet ve _godotTexId'yi al
        // _godotTexId = RenderingServer.textureCreate...
    }
}`;
