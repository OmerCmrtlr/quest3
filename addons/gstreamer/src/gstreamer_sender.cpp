#include "gstreamer_sender.h"

#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstring>

using namespace godot;

GStreamerSender::GStreamerSender() {}

GStreamerSender::~GStreamerSender() {
    _destroy_pipeline();
}

void GStreamerSender::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start_streaming"), &GStreamerSender::start_streaming);
    ClassDB::bind_method(D_METHOD("stop_streaming"), &GStreamerSender::stop_streaming);
    ClassDB::bind_method(D_METHOD("is_streaming"), &GStreamerSender::is_streaming);

    ClassDB::bind_method(D_METHOD("set_stream_width", "width"), &GStreamerSender::set_stream_width);
    ClassDB::bind_method(D_METHOD("get_stream_width"), &GStreamerSender::get_stream_width);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "stream_width"), "set_stream_width", "get_stream_width");

    ClassDB::bind_method(D_METHOD("set_stream_height", "height"), &GStreamerSender::set_stream_height);
    ClassDB::bind_method(D_METHOD("get_stream_height"), &GStreamerSender::get_stream_height);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "stream_height"), "set_stream_height", "get_stream_height");

    ClassDB::bind_method(D_METHOD("set_stream_fps", "fps"), &GStreamerSender::set_stream_fps);
    ClassDB::bind_method(D_METHOD("get_stream_fps"), &GStreamerSender::get_stream_fps);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "stream_fps"), "set_stream_fps", "get_stream_fps");

    ClassDB::bind_method(D_METHOD("set_bitrate", "bitrate"), &GStreamerSender::set_bitrate);
    ClassDB::bind_method(D_METHOD("get_bitrate"), &GStreamerSender::get_bitrate);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "bitrate"), "set_bitrate", "get_bitrate");

    ClassDB::bind_method(D_METHOD("set_host", "host"), &GStreamerSender::set_host);
    ClassDB::bind_method(D_METHOD("get_host"), &GStreamerSender::get_host);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "host"), "set_host", "get_host");

    ClassDB::bind_method(D_METHOD("set_port", "port"), &GStreamerSender::set_port);
    ClassDB::bind_method(D_METHOD("get_port"), &GStreamerSender::get_port);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "port"), "set_port", "get_port");

    ClassDB::bind_method(D_METHOD("set_auto_start", "auto_start"), &GStreamerSender::set_auto_start);
    ClassDB::bind_method(D_METHOD("get_auto_start"), &GStreamerSender::get_auto_start);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_start"), "set_auto_start", "get_auto_start");

    ADD_SIGNAL(MethodInfo("streaming_started"));
    ADD_SIGNAL(MethodInfo("streaming_stopped"));
    ADD_SIGNAL(MethodInfo("error_occurred", PropertyInfo(Variant::STRING, "message")));
}

// ---- SubViewport capture system ----

void GStreamerSender::_setup_capture_viewport() {
    if (_capture_viewport != nullptr) {
        return;
    }

    // SubViewport: ana viewport yerine bundan yakalama yapilacak
    // - CanvasLayer/TextureRect'i GORMEZ (feedback loop onlenir)
    // - Daha kucuk boyutta (640x480) readback yapar (GPU stall azalir)
    _capture_viewport = memnew(SubViewport);
    _capture_viewport->set_size(Vector2i(_width, _height));
    _capture_viewport->set_update_mode(SubViewport::UPDATE_DISABLED);
    _capture_viewport->set_clear_mode(SubViewport::CLEAR_MODE_ALWAYS);
    _capture_viewport->set_use_own_world_3d(false); // Ana sahnenin 3D dunyasini paylas
    _capture_viewport->set_as_audio_listener_3d(false);
    _capture_viewport->set_physics_object_picking(false);

    // SubViewport icin kamera: GStreamerSender'in transform'unu yansitir
    // NOT: make_current() CAGRILMAZ — ana viewport kamerasini degistirirdi (flash bug)
    // SubViewport kendi dunyasinda bu kamerayi otomatik kullanir.
    _capture_camera = memnew(Camera3D);
    _capture_viewport->add_child(_capture_camera);
    // _capture_camera->make_current();  // KALDIRILDI v4.2 — flash bug fix

    // INTERNAL_MODE_FRONT: editorde gorunmez, sahne dosyasina kaydedilmez
    add_child(_capture_viewport, false, Node::INTERNAL_MODE_FRONT);

    UtilityFunctions::print("[GStreamerSender] Capture SubViewport olusturuldu (",
        _width, "x", _height, ")");
}

void GStreamerSender::_teardown_capture_viewport() {
    if (_capture_viewport != nullptr) {
        _capture_viewport->queue_free();
        _capture_viewport = nullptr;
        _capture_camera = nullptr;
    }
}

void GStreamerSender::_sync_capture_camera() {
    if (_capture_camera == nullptr) {
        return;
    }

    // GStreamerSender kamerasinin transform ve projection parametrelerini kopyala
    _capture_camera->set_global_transform(get_global_transform());
    _capture_camera->set_fov(get_fov());
    _capture_camera->set_near(get_near());
    _capture_camera->set_far(get_far());
    _capture_camera->set_projection(get_projection());
    _capture_camera->set_cull_mask(get_cull_mask());

    if (get_projection() == Camera3D::PROJECTION_ORTHOGONAL) {
        _capture_camera->set_size(get_size());
    }
}

// ---- Godot lifecycle ----

void GStreamerSender::_ready() {
    set_process(true);
    _setup_capture_viewport();

    if (_auto_start) {
        call_deferred("start_streaming");
    }
}

bool GStreamerSender::_create_pipeline() {
    _pipeline = gst_pipeline_new("sender-pipeline");
    if (!_pipeline) {
        UtilityFunctions::printerr("[GStreamerSender] Pipeline olusturulamadi");
        emit_signal("error_occurred", String("Pipeline olusturulamadi"));
        return false;
    }

    _appsrc = gst_element_factory_make("appsrc", "source");
    GstElement *convert = gst_element_factory_make("videoconvert", "convert");
    GstElement *encoder = gst_element_factory_make("x264enc", "encoder");
    GstElement *payloader = gst_element_factory_make("rtph264pay", "pay");
    GstElement *sink = gst_element_factory_make("udpsink", "sink");

    if (!_appsrc || !convert || !encoder || !payloader || !sink) {
        String missing;
        if (!_appsrc) missing = missing + "appsrc ";
        if (!convert) missing = missing + "videoconvert ";
        if (!encoder) missing = missing + "x264enc(gstreamer1.0-plugins-ugly gerekli) ";
        if (!payloader) missing = missing + "rtph264pay ";
        if (!sink) missing = missing + "udpsink ";

        UtilityFunctions::printerr("[GStreamerSender] Eksik element(ler): ", missing);
        emit_signal("error_occurred", String("Eksik GStreamer element: ") + missing);

        if (_appsrc) { gst_object_unref(_appsrc); _appsrc = nullptr; }
        if (convert)   gst_object_unref(convert);
        if (encoder)   gst_object_unref(encoder);
        if (payloader) gst_object_unref(payloader);
        if (sink)      gst_object_unref(sink);
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
        return false;
    }

    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "RGB",
        "width", G_TYPE_INT, (gint)_width,
        "height", G_TYPE_INT, (gint)_height,
        "framerate", GST_TYPE_FRACTION, (gint)_fps, (gint)1,
        nullptr);
    g_object_set(G_OBJECT(_appsrc),
        "caps", caps,
        "stream-type", (gint)0,
        "format", GST_FORMAT_TIME,
        "is-live", TRUE,
        "do-timestamp", TRUE,
        nullptr);
    gst_caps_unref(caps);

    g_object_set(G_OBJECT(encoder),
        "tune", (guint)0x00000004,   // zerolatency
        "speed-preset", (guint)1,    // ultrafast
        "bitrate", (guint)_bitrate,
        "key-int-max", (guint)30,
        nullptr);

    g_object_set(G_OBJECT(payloader),
        "pt", (guint)96,
        "config-interval", (gint)1,
        nullptr);

    CharString host_utf8 = _host.utf8();
    g_object_set(G_OBJECT(sink),
        "host", host_utf8.get_data(),
        "port", (gint)_port,
        "sync", FALSE,
        "async", FALSE,
        nullptr);

    gst_bin_add_many(GST_BIN(_pipeline), _appsrc, convert, encoder, payloader, sink, nullptr);

    if (!gst_element_link_many(_appsrc, convert, encoder, payloader, sink, nullptr)) {
        UtilityFunctions::printerr("[GStreamerSender] Pipeline elemanlari baglanamadi");
        emit_signal("error_occurred", String("Pipeline elemanlari baglanamadi"));
        _destroy_pipeline();
        return false;
    }

    GstStateChangeReturn ret = gst_element_set_state(_pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        UtilityFunctions::printerr("[GStreamerSender] Pipeline PLAYING durumuna gecilemedi");
        emit_signal("error_occurred", String("Pipeline baslatilamadi"));
        _destroy_pipeline();
        return false;
    }

    _is_streaming = true;
    _frame_count = 0;
    _time_accumulator = 0.0;
    UtilityFunctions::print("[GStreamerSender] Streaming baslatildi (",
        _width, "x", _height, " @ ", _fps, "fps, ",
        _bitrate, "kbps -> ", _host, ":", _port, ")");
    emit_signal("streaming_started");
    return true;
}

void GStreamerSender::_destroy_pipeline() {
    _is_streaming = false;
    if (_pipeline) {
        gst_element_set_state(_pipeline, GST_STATE_NULL);
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
    }
    _appsrc = nullptr;
}

void GStreamerSender::_process(double delta) {
    // SubViewport kamerasini her frame guncelle (render icin hazir olsun)
    _sync_capture_camera();

    if (!_is_streaming || !_appsrc) {
        return;
    }

    // Frame rate limiting: sadece 1/_fps saniyede bir yakalama yap
    _time_accumulator += delta;
    double frame_interval = 1.0 / (double)_fps;
    if (_time_accumulator < frame_interval) {
        return;
    }
    _time_accumulator -= frame_interval;
    // Biriken fazla zamani sinirla (baslangicta buyuk delta tasmasi onlenir)
    if (_time_accumulator > frame_interval) {
        _time_accumulator = 0.0;
    }

    // SubViewport'tan yakalama (ana viewport etkilenmez, CanvasLayer gormez)
    if (_capture_viewport == nullptr) {
        return;
    }

    Ref<ViewportTexture> vp_tex = _capture_viewport->get_texture();
    if (vp_tex.is_null()) {
        return;
    }

    Ref<Image> img = vp_tex->get_image();
    if (img.is_null()) {
        if (_frame_count == 0) {
            UtilityFunctions::printerr("[GStreamerSender] SubViewport image NULL!");
        }
        return;
    }

    // SubViewport zaten _width x _height boyutunda, normalde resize gerekmez
    if (img->get_width() != _width || img->get_height() != _height) {
        img->resize(_width, _height);
    }

    if (img->get_format() != Image::FORMAT_RGB8) {
        img->convert(Image::FORMAT_RGB8);
    }

    PackedByteArray data = img->get_data();
    int64_t size = data.size();
    if (size <= 0) {
        if (_frame_count == 0) {
            UtilityFunctions::printerr("[GStreamerSender] Image data bos! format=",
                (int)img->get_format(), " w=", img->get_width(), " h=", img->get_height());
        }
        return;
    }

    GstBuffer *buffer = gst_buffer_new_allocate(nullptr, (gsize)size, nullptr);
    if (!buffer) {
        return;
    }

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
        gst_buffer_unref(buffer);
        return;
    }
    memcpy(map.data, data.ptr(), (size_t)size);
    gst_buffer_unmap(buffer, &map);

    guint64 duration_ns = 1000000000ULL / (guint64)_fps;
    GST_BUFFER_PTS(buffer) = _frame_count * duration_ns;
    GST_BUFFER_DURATION(buffer) = duration_ns;

    gst_app_src_push_buffer(GST_APP_SRC(_appsrc), buffer);
    _frame_count++;

    if (_frame_count == 1 || _frame_count % 30 == 0) {
        UtilityFunctions::print("[GStreamerSender] Frame #", (uint64_t)_frame_count,
            " gonderildi (", (int64_t)size, " bytes, ", img->get_width(), "x", img->get_height(), ")");
    }
}

void GStreamerSender::_exit_tree() {
    stop_streaming();
    _teardown_capture_viewport();
}

void GStreamerSender::start_streaming() {
    if (_is_streaming) {
        return;
    }

    // SubViewport rendering'i aktifle
    if (_capture_viewport != nullptr) {
        _capture_viewport->set_update_mode(SubViewport::UPDATE_ALWAYS);
    }

    _create_pipeline();
}

void GStreamerSender::stop_streaming() {
    if (!_is_streaming) {
        return;
    }
    _destroy_pipeline();

    // SubViewport rendering'i durdur (GPU tasarrufu)
    if (_capture_viewport != nullptr) {
        _capture_viewport->set_update_mode(SubViewport::UPDATE_DISABLED);
    }

    UtilityFunctions::print("[GStreamerSender] Streaming durduruldu");
    emit_signal("streaming_stopped");
}

bool GStreamerSender::is_streaming() const {
    return _is_streaming;
}

void GStreamerSender::set_stream_width(int p_width) {
    _width = p_width;
    if (_capture_viewport != nullptr) {
        _capture_viewport->set_size(Vector2i(_width, _height));
    }
}
int GStreamerSender::get_stream_width() const { return _width; }

void GStreamerSender::set_stream_height(int p_height) {
    _height = p_height;
    if (_capture_viewport != nullptr) {
        _capture_viewport->set_size(Vector2i(_width, _height));
    }
}
int GStreamerSender::get_stream_height() const { return _height; }

void GStreamerSender::set_stream_fps(int p_fps) { _fps = p_fps; }
int GStreamerSender::get_stream_fps() const { return _fps; }
void GStreamerSender::set_bitrate(int p_bitrate) { _bitrate = p_bitrate; }
int GStreamerSender::get_bitrate() const { return _bitrate; }
void GStreamerSender::set_host(const String &p_host) { _host = p_host; }
String GStreamerSender::get_host() const { return _host; }
void GStreamerSender::set_port(int p_port) { _port = p_port; }
int GStreamerSender::get_port() const { return _port; }
void GStreamerSender::set_auto_start(bool p_auto) { _auto_start = p_auto; }
bool GStreamerSender::get_auto_start() const { return _auto_start; }
