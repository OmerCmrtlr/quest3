#include "gstreamer_camera.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>
#include <cstdio>

using namespace godot;

GStreamerCamera::GStreamerCamera() {}

GStreamerCamera::~GStreamerCamera() {
    _destroy_pipeline();
}

void GStreamerCamera::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start_capture"), &GStreamerCamera::start_capture);
    ClassDB::bind_method(D_METHOD("stop_capture"), &GStreamerCamera::stop_capture);
    ClassDB::bind_method(D_METHOD("is_capturing"), &GStreamerCamera::is_capturing);
    ClassDB::bind_method(D_METHOD("get_texture"), &GStreamerCamera::get_texture);

    ClassDB::bind_method(D_METHOD("set_device", "device"), &GStreamerCamera::set_device);
    ClassDB::bind_method(D_METHOD("get_device"), &GStreamerCamera::get_device);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "device"), "set_device", "get_device");

    ClassDB::bind_method(D_METHOD("set_capture_width", "width"), &GStreamerCamera::set_capture_width);
    ClassDB::bind_method(D_METHOD("get_capture_width"), &GStreamerCamera::get_capture_width);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "capture_width"), "set_capture_width", "get_capture_width");

    ClassDB::bind_method(D_METHOD("set_capture_height", "height"), &GStreamerCamera::set_capture_height);
    ClassDB::bind_method(D_METHOD("get_capture_height"), &GStreamerCamera::get_capture_height);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "capture_height"), "set_capture_height", "get_capture_height");

    ClassDB::bind_method(D_METHOD("set_auto_start", "auto_start"), &GStreamerCamera::set_auto_start);
    ClassDB::bind_method(D_METHOD("get_auto_start"), &GStreamerCamera::get_auto_start);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_start"), "set_auto_start", "get_auto_start");

    ClassDB::bind_method(D_METHOD("set_stream_port", "port"), &GStreamerCamera::set_stream_port);
    ClassDB::bind_method(D_METHOD("get_stream_port"), &GStreamerCamera::get_stream_port);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "stream_port"), "set_stream_port", "get_stream_port");

    ClassDB::bind_method(D_METHOD("set_stream_bitrate", "kbps"), &GStreamerCamera::set_stream_bitrate);
    ClassDB::bind_method(D_METHOD("get_stream_bitrate"), &GStreamerCamera::get_stream_bitrate);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "stream_bitrate"), "set_stream_bitrate", "get_stream_bitrate");

    ClassDB::bind_method(D_METHOD("set_stream_host", "host"), &GStreamerCamera::set_stream_host);
    ClassDB::bind_method(D_METHOD("get_stream_host"), &GStreamerCamera::get_stream_host);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "stream_host"), "set_stream_host", "get_stream_host");

    ADD_SIGNAL(MethodInfo("capture_started"));
    ADD_SIGNAL(MethodInfo("capture_stopped"));
    ADD_SIGNAL(MethodInfo("frame_received"));
    ADD_SIGNAL(MethodInfo("error_occurred", PropertyInfo(Variant::STRING, "message")));
}

void GStreamerCamera::_ready() {
    set_process(true);
    if (_auto_start) {
        call_deferred("start_capture");
    }
}

bool GStreamerCamera::_create_pipeline() {
    _pipeline = gst_pipeline_new("camera-pipeline");
    if (!_pipeline) {
        UtilityFunctions::printerr("[GStreamerCamera] Pipeline olusturulamadi");
        emit_signal("error_occurred", String("Pipeline olusturulamadi"));
        return false;
    }

    bool do_stream = (_stream_port > 0 && _stream_port < 65536);

    // v4.1 uyumlu: autovideosrc — platformdan bagimsiz, kamera calisir
    // device bos = varsayilan kamera, dolu = v4l2src ile belirtilen cihaz
    GstElement *src = nullptr;
    if (_device.length() > 0) {
        src = gst_element_factory_make("v4l2src", "source");
        if (src) {
            CharString dev_utf8 = _device.utf8();
            g_object_set(G_OBJECT(src), "device", dev_utf8.get_data(), nullptr);
        }
    }
    if (!src) {
        src = gst_element_factory_make("autovideosrc", "source");
    }

    GstElement *convert = gst_element_factory_make("videoconvert", "convert");
    GstElement *scale = gst_element_factory_make("videoscale", "scale");
    GstElement *capsfilter = gst_element_factory_make("capsfilter", "filter");
    _appsink = gst_element_factory_make("appsink", "sink");

    if (!src || !convert || !scale || !capsfilter || !_appsink) {
        String missing = "autovideosrc/v4l2src/videoconvert/videoscale/capsfilter/appsink ";
        UtilityFunctions::printerr("[GStreamerCamera] Eksik element(ler): ", missing);
        if (src) gst_object_unref(src);
        if (convert) gst_object_unref(convert);
        if (scale) gst_object_unref(scale);
        if (capsfilter) gst_object_unref(capsfilter);
        if (_appsink) { gst_object_unref(_appsink); _appsink = nullptr; }
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
        return false;
    }

    GstCaps *sink_caps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "RGB",
        "width", G_TYPE_INT, (gint)_width,
        "height", G_TYPE_INT, (gint)_height,
        nullptr);
    g_object_set(G_OBJECT(capsfilter), "caps", sink_caps, nullptr);
    gst_caps_unref(sink_caps);

    GstAppSinkCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.new_sample = GStreamerCamera::_on_new_sample;
    gst_app_sink_set_callbacks(GST_APP_SINK(_appsink), &callbacks, this, nullptr);
    g_object_set(G_OBJECT(_appsink), "max-buffers", (guint)1, "drop", TRUE, "sync", FALSE, nullptr);

    if (do_stream) {
        GstElement *t = gst_element_factory_make("tee", "tee");
        GstElement *e = gst_element_factory_make("x264enc", "enc");
        if (!t || !e) {
            UtilityFunctions::printerr("[GStreamerCamera] UDP stream icin eksik element (x264enc?)");
            if (t) gst_object_unref(t);
            if (e) gst_object_unref(e);
            do_stream = false;
        }
    }
    if (!do_stream) {
        gst_bin_add_many(GST_BIN(_pipeline), src, convert, scale, capsfilter, _appsink, nullptr);
        if (!gst_element_link_many(src, convert, scale, capsfilter, _appsink, nullptr)) {
            UtilityFunctions::printerr("[GStreamerCamera] Pipeline elemanlari baglanamadi");
            emit_signal("error_occurred", String("Pipeline elemanlari baglanamadi"));
            _destroy_pipeline();
            return false;
        }
    } else {
        GstElement *tee = gst_element_factory_make("tee", "tee");
        GstElement *q1 = gst_element_factory_make("queue", "q1");
        GstElement *q2 = gst_element_factory_make("queue", "q2");
        GstElement *conv2 = gst_element_factory_make("videoconvert", "conv2");
        GstElement *enc = gst_element_factory_make("x264enc", "enc");
        GstElement *pay = gst_element_factory_make("rtph264pay", "pay");
        GstElement *udpsink = gst_element_factory_make("udpsink", "udpsink");
        if (!tee || !q1 || !q2 || !conv2 || !enc || !pay || !udpsink) {
            UtilityFunctions::printerr("[GStreamerCamera] UDP branch eksik element");
            if (tee) gst_object_unref(tee);
            if (q1) gst_object_unref(q1);
            if (q2) gst_object_unref(q2);
            if (conv2) gst_object_unref(conv2);
            if (enc) gst_object_unref(enc);
            if (pay) gst_object_unref(pay);
            if (udpsink) gst_object_unref(udpsink);
            gst_bin_add_many(GST_BIN(_pipeline), src, convert, scale, capsfilter, _appsink, nullptr);
            gst_element_link_many(src, convert, scale, capsfilter, _appsink, nullptr);
        } else {
            g_object_set(G_OBJECT(enc), "tune", (guint)0x4, "speed-preset", (guint)1,
                "key-int-max", (guint)30, nullptr);
            if (_stream_bitrate > 0 && _stream_bitrate <= 20000) {
                g_object_set(G_OBJECT(enc), "bitrate", (guint)_stream_bitrate, nullptr);
            }
            g_object_set(G_OBJECT(pay), "pt", (guint)96, "config-interval", (gint)1, nullptr);
            CharString host_utf8 = _stream_host.utf8();
            g_object_set(G_OBJECT(udpsink), "host", host_utf8.get_data(),
                "port", (gint)_stream_port, "sync", FALSE, "async", FALSE, nullptr);

            gst_bin_add_many(GST_BIN(_pipeline),
                src, convert, scale, capsfilter, tee, q1, _appsink, q2, conv2, enc, pay, udpsink, nullptr);
            gst_element_link_many(src, convert, scale, capsfilter, tee, nullptr);
            gst_element_link_many(tee, q1, _appsink, nullptr);
            gst_element_link_many(tee, q2, conv2, enc, pay, udpsink, nullptr);
        }
    }

    // Pipeline'i baslat
    GstStateChangeReturn ret = gst_element_set_state(_pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        UtilityFunctions::printerr("[GStreamerCamera] Pipeline baslatilamadi (kamera erisim hatasi?)");
        emit_signal("error_occurred", String("Pipeline baslatilamadi - kamera erisim hatasi olabilir"));
        _destroy_pipeline();
        return false;
    }

    _is_capturing = true;
    String msg = String("[GStreamerCamera] Kamera baslatildi (") + String::num(_width) + "x" + String::num(_height);
    if (_device.length() > 0) msg += ", device=" + _device;
    if (_stream_port > 0) msg += ", UDP->" + _stream_host + ":" + String::num(_stream_port);
    msg += ")";
    UtilityFunctions::print(msg);
    emit_signal("capture_started");
    return true;
}

void GStreamerCamera::_destroy_pipeline() {
    _is_capturing = false;
    if (_pipeline) {
        gst_element_set_state(_pipeline, GST_STATE_NULL);
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
    }
    _appsink = nullptr;
    _has_new_frame.store(false);
}

GstFlowReturn GStreamerCamera::_on_new_sample(GstAppSink *sink, gpointer user_data) {
    GStreamerCamera *self = static_cast<GStreamerCamera *>(user_data);

    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) {
        return GST_FLOW_ERROR;
    }

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    if (!buffer) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    GstCaps *caps = gst_sample_get_caps(sample);
    if (!caps || gst_caps_get_size(caps) == 0) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    GstStructure *s = gst_caps_get_structure(caps, 0);
    gint width = 0, height = 0;
    if (!gst_structure_get_int(s, "width", &width) ||
        !gst_structure_get_int(s, "height", &height) ||
        width <= 0 || height <= 0) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_ERROR;
    }

    // Thread-safe: frame verisini kopyala
    {
        std::lock_guard<std::mutex> lock(self->_frame_mutex);
        self->_frame_width = (int)width;
        self->_frame_height = (int)height;
        self->_raw_buffer.resize(map.size);
        memcpy(self->_raw_buffer.data(), map.data, map.size);
    }
    self->_has_new_frame.store(true);

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);

    return GST_FLOW_OK;
}

void GStreamerCamera::_process(double delta) {
    if (!_is_capturing) {
        return;
    }

    if (!_has_new_frame.load()) {
        return;
    }

    int w = 0, h = 0;
    PackedByteArray godot_data;

    {
        std::lock_guard<std::mutex> lock(_frame_mutex);
        if (_raw_buffer.empty()) {
            _has_new_frame.store(false);
            return;
        }
        w = _frame_width;
        h = _frame_height;
        godot_data.resize((int64_t)_raw_buffer.size());
        memcpy(godot_data.ptrw(), _raw_buffer.data(), _raw_buffer.size());
        _has_new_frame.store(false);
    }

    if (w <= 0 || h <= 0 || godot_data.size() == 0) {
        return;
    }

    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGB8, godot_data);
    if (img.is_null()) {
        return;
    }

    if (_texture.is_null()) {
        _texture = ImageTexture::create_from_image(img);
        UtilityFunctions::print("[GStreamerCamera] Texture olusturuldu! Kamera goruntusu aktif. (",
            w, "x", h, ")");
    } else {
        _texture->update(img);
    }

    emit_signal("frame_received");
}

void GStreamerCamera::_exit_tree() {
    stop_capture();
}

void GStreamerCamera::start_capture() {
    if (_is_capturing) {
        return;
    }
    _create_pipeline();
}

void GStreamerCamera::stop_capture() {
    if (!_is_capturing) {
        return;
    }
    _destroy_pipeline();
    UtilityFunctions::print("[GStreamerCamera] Kamera durduruldu");
    emit_signal("capture_stopped");
}

bool GStreamerCamera::is_capturing() const {
    return _is_capturing;
}

Ref<ImageTexture> GStreamerCamera::get_texture() const {
    return _texture;
}

void GStreamerCamera::set_device(const String &p_device) { _device = p_device; }
String GStreamerCamera::get_device() const { return _device; }
void GStreamerCamera::set_capture_width(int p_width) { _width = p_width; }
int GStreamerCamera::get_capture_width() const { return _width; }
void GStreamerCamera::set_capture_height(int p_height) { _height = p_height; }
int GStreamerCamera::get_capture_height() const { return _height; }
void GStreamerCamera::set_auto_start(bool p_auto) { _auto_start = p_auto; }
bool GStreamerCamera::get_auto_start() const { return _auto_start; }
void GStreamerCamera::set_stream_port(int p_port) { _stream_port = p_port; }
int GStreamerCamera::get_stream_port() const { return _stream_port; }
void GStreamerCamera::set_stream_bitrate(int p_kbps) { _stream_bitrate = p_kbps; }
int GStreamerCamera::get_stream_bitrate() const { return _stream_bitrate; }
void GStreamerCamera::set_stream_host(const String &p_host) { _stream_host = p_host; }
String GStreamerCamera::get_stream_host() const { return _stream_host; }
