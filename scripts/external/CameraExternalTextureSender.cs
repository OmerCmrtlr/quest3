using Godot;
using System;

public partial class CameraExternalTextureSender : Node
{
    [Export] public bool AutoStart = true;
    [Export] public int CameraIndex = 0;
    [Export] public bool PreferNewestFeedOnStart = true;
    [Export] public bool EnableLocalCameraFallback = false;
    [Export] public string AndroidCameraSingletonName = "QuestExternalTexture";

    private CameraFeed _cameraFeed;
    private CameraTexture _cameraTexture;
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

        if (!EnableLocalCameraFallback)
        {
            GD.PrintErr("[ExtTexture] Android singleton bulunamadı ve local fallback kapalı.");
            return;
        }

        CameraServer.SetMonitoringFeeds(true);
        var feeds = CameraServer.Feeds();
        if (feeds == null || feeds.Count == 0)
        {
            GD.PrintErr("[ExtTexture] Kamera feed bulunamadı. Camera Feed ve izinleri kontrol et.");
            return;
        }

        int idx = Mathf.Clamp(CameraIndex, 0, feeds.Count - 1);
        if (PreferNewestFeedOnStart && CameraIndex <= 0 && feeds.Count > 1)
            idx = feeds.Count - 1;

        CameraFeed feed = feeds[idx];
        if (!TryActivateFeed(feed))
        {
            GD.PrintErr("[ExtTexture] Kamera feed aktif edilemedi.");
            return;
        }

        _cameraFeed = feed;
        _cameraTexture = new CameraTexture
        {
            CameraFeedId = feed.GetId(),
            CameraIsActive = true,
        };

        _currentTexture = _cameraTexture;
        _running = true;
        GD.Print($"[ExtTexture] Lokal kamera feed bağlı. index={idx}");
    }

    public void StopCapture()
    {
        if (!_running)
            return;

        _running = false;

        if (_cameraFeed != null)
        {
            try { _cameraFeed.FeedIsActive = false; } catch { }
            _cameraFeed = null;
        }

        _cameraTexture = null;
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
