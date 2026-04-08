using Godot;
using System;

public partial class CameraExternalTextureSender : Node
{
    [Export] public bool AutoStart = true;
    [Export] public string AndroidCameraSingletonName = "QuestExternalTexture";

    private Texture2D _currentTexture;
    private bool _running;

    public override void _Ready()
    {
        if (AutoStart)
            StartCapture();
    }

    public void StartCapture()
    {
        if (_running)
            return;

        RequestCameraPermissionIfNeeded();

        Texture2D pluginTexture = TryGetTextureFromAndroidSingleton();
        if (pluginTexture != null)
        {
            _currentTexture = pluginTexture;
            _running = true;
            GD.Print("[ExtTexture] Android singleton external texture bağlı.");
            return;
        }

        GD.PrintErr($"[ExtTexture] External texture singleton '{AndroidCameraSingletonName}' bulunamadı veya get_camera_texture() Texture2D döndürmedi.");
    }

    public void StopCapture()
    {
        if (!_running)
            return;

        _running = false;
        _currentTexture = null;
    }

    public Texture2D GetExternalTexture()
    {
        return _currentTexture;
    }

    public bool IsRunning()
    {
        return _running;
    }

    public override void _ExitTree()
    {
        StopCapture();
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
            GD.PrintErr("[ExtTexture] Android singleton texture okuma hatası: " + e.Message);
            return null;
        }
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
