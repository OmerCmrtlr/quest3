#include "gstreamer_receiver.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>
#include <cstdio>

using namespace godot;

GStreamerReceiver::GStreamerReceiver() {}

GStreamerReceiver::~GStreamerReceiver() {
    _destroy_pipeline();
}

void GStreamerReceiver::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start_receiving"), &GStreamerReceiver::start_receiving);
    ClassDB::bind_method(D_METHOD("stop_receiving"), &GStreamerReceiver::stop_receiving);
    ClassDB::bind_method(D_METHOD("is_receiving"), &GStreamerReceiver::is_receiving);
    ClassDB::bind_method(D_METHOD("get_texture"), &GStreamerReceiver::get_texture);

    ClassDB::bind_method(D_METHOD("set_port", "port"), &GStreamerReceiver::set_port);
    ClassDB::bind_method(D_METHOD("get_port"), &GStreamerReceiver::get_port);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "port"), "set_port", "get_port");

    ClassDB::bind_method(D_METHOD("set_auto_start", "auto_start"), &GStreamerReceiver::set_auto_start);
    ClassDB::bind_method(D_METHOD("get_auto_start"), &GStreamerReceiver::get_auto_start);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_start"), "set_auto_start", "get_auto_start");

    ADD_SIGNAL(MethodInfo("receiving_started"));
    ADD_SIGNAL(MethodInfo("receiving_stopped"));
    ADD_SIGNAL(MethodInfo("frame_received"));
    ADD_SIGNAL(MethodInfo("error_occurred", PropertyInfo(Variant::STRING, "message")));
}

void GStreamerReceiver::_ready() {
    set_process(true);
    if (_auto_start) {
        call_deferred("start_receiving");
    }
}

bool GStreamerReceiver::_create_pipeline() {
    _pipeline = gst_pipeline_new("receiver-pipeline");
    if (!_pipeline) {
        UtilityFunctions::printerr("[GStreamerReceiver] Pipeline olusturulamadi");
        emit_signal("error_occurred", String("Pipeline olusturulamadi"));
        return false;
    }

    GstElement *src = gst_element_factory_make("udpsrc", "source");
    GstElement *capsfilter = gst_element_factory_make("capsfilter", "filter");
    GstElement *depay = gst_element_factory_make("rtph264depay", "depay");
    GstElement *decoder = gst_element_factory_make("avdec_h264", "decoder");
    GstElement *convert = gst_element_factory_make("videoconvert", "convert");
    _appsink = gst_element_factory_make("appsink", "sink");

    if (!src || !capsfilter || !depay || !decoder || !convert || !_appsink) {
        String missing;
        if (!src)        missing = missing + "udpsrc ";
        if (!capsfilter) missing = missing + "capsfilter ";
        if (!depay)      missing = missing + "rtph264depay(gstreamer1.0-plugins-good gerekli) ";
        if (!decoder)    missing = missing + "avdec_h264(gstreamer1.0-plugins-ugly/libav gerekli) ";
        if (!convert)    missing = missing + "videoconvert ";
        if (!_appsink)   missing = missing + "appsink ";

        UtilityFunctions::printerr("[GStreamerReceiver] Eksik element(ler): ", missing);
        emit_signal("error_occurred", String("Eksik GStreamer element: ") + missing);

        // Olusturulmus elemanlari temizle
        if (src)        gst_object_unref(src);
        if (capsfilter) gst_object_unref(capsfilter);
        if (depay)      gst_object_unref(depay);
        if (decoder)    gst_object_unref(decoder);
        if (convert)    gst_object_unref(convert);
        if (_appsink)   { gst_object_unref(_appsink); _appsink = nullptr; }
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
        return false;
    }

    // --- udpsrc port ayari ---
    g_object_set(G_OBJECT(src), "port", (gint)_port, nullptr);

    // --- RTP caps filtresi (ai_vision_tracking.py ile uyumlu) ---
    GstCaps *rtp_caps = gst_caps_new_simple("application/x-rtp",
        "media", G_TYPE_STRING, "video",
        "clock-rate", G_TYPE_INT, (gint)90000,
        "encoding-name", G_TYPE_STRING, "H264",
        "payload", G_TYPE_INT, (gint)96,
        nullptr);
    g_object_set(G_OBJECT(capsfilter), "caps", rtp_caps, nullptr);
    gst_caps_unref(rtp_caps);

    // --- appsink ayarlari ---
    // RGB cikti, tek buffer, fazlasini at, senkronizasyon yok
    GstCaps *sink_caps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "RGB",
        nullptr);

    // Callback tabanlı yaklasim (sinyal yerine daha verimli)
    GstAppSinkCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.new_sample = GStreamerReceiver::_on_new_sample;
    gst_app_sink_set_callbacks(GST_APP_SINK(_appsink), &callbacks, this, nullptr);

    g_object_set(G_OBJECT(_appsink),
        "max-buffers", (guint)1,
        "drop", TRUE,
        "sync", FALSE,
        "caps", sink_caps,
        nullptr);
    gst_caps_unref(sink_caps);

    // Elemanlari pipeline'a ekle
    gst_bin_add_many(GST_BIN(_pipeline),
        src, capsfilter, depay, decoder, convert, _appsink, nullptr);

    // Elemanlari bagla
    if (!gst_element_link_many(src, capsfilter, depay, decoder, convert, _appsink, nullptr)) {
        UtilityFunctions::printerr("[GStreamerReceiver] Pipeline elemanlari baglanamadi");
        emit_signal("error_occurred", String("Pipeline elemanlari baglanamadi"));
        _destroy_pipeline();
        return false;
    }

    // Pipeline'i baslat
    GstStateChangeReturn ret = gst_element_set_state(_pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        UtilityFunctions::printerr("[GStreamerReceiver] Pipeline baslatilamadi");
        emit_signal("error_occurred", String("Pipeline baslatilamadi"));
        _destroy_pipeline();
        return false;
    }

    _is_receiving = true;
    UtilityFunctions::print("[GStreamerReceiver] UDP port ", _port, " dinleniyor");
    emit_signal("receiving_started");
    return true;
}

void GStreamerReceiver::_destroy_pipeline() {
    _is_receiving = false;
    if (_pipeline) {
        // GST_STATE_NULL tum callback'lerin bitmesini bekler
        gst_element_set_state(_pipeline, GST_STATE_NULL);
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
    }
    _appsink = nullptr;
    _has_new_frame.store(false);
}

GstFlowReturn GStreamerReceiver::_on_new_sample(GstAppSink *sink, gpointer user_data) {
    GStreamerReceiver *self = static_cast<GStreamerReceiver *>(user_data);

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

    // Frame boyutlarini caps'ten al
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

    // Thread-safe: frame verisini std::vector'e kopyala
    // (Godot tipleri thread-safe degil, bu yuzden raw C++ kullaniriz)
    {
        std::lock_guard<std::mutex> lock(self->_frame_mutex);
        self->_frame_width = (int)width;
        self->_frame_height = (int)height;
        self->_raw_buffer.resize(map.size);
        memcpy(self->_raw_buffer.data(), map.data, map.size);
        self->_received_frame_count++;
    }
    self->_has_new_frame.store(true);

    // Debug: GStreamer thread'inde olduğu icin fprintf kullan (thread-safe)
    if (self->_received_frame_count == 1) {
        fprintf(stdout, "[GStreamerReceiver] Godot-to-Godot CALISIYOR! Ilk frame alindi (%dx%d, %zu bytes)\n",
            width, height, map.size);
        fflush(stdout);
    }
    if (self->_received_frame_count % 30 == 0) {
        fprintf(stdout, "[GStreamerReceiver] %lu frame alindi\n",
            (unsigned long)self->_received_frame_count);
        fflush(stdout);
    }

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);

    return GST_FLOW_OK;
}

void GStreamerReceiver::_process(double delta) {
    if (!_is_receiving) {
        return;
    }

    if (!_has_new_frame.load()) {
        return;
    }

    int w = 0, h = 0;
    PackedByteArray godot_data;

    // Thread-safe: frame verisini oku ve Godot tipine donustur (main thread'de)
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

    // Image olustur ve texture'u guncelle
    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGB8, godot_data);
    if (img.is_null()) {
        return;
    }

    if (_texture.is_null()) {
        _texture = ImageTexture::create_from_image(img);
    } else {
        _texture->update(img);
    }

    emit_signal("frame_received");
}

void GStreamerReceiver::_exit_tree() {
    stop_receiving();
}

void GStreamerReceiver::start_receiving() {
    if (_is_receiving) {
        return;
    }
    _create_pipeline();
}

void GStreamerReceiver::stop_receiving() {
    if (!_is_receiving) {
        return;
    }
    _destroy_pipeline();
    UtilityFunctions::print("[GStreamerReceiver] Durduruldu");
    emit_signal("receiving_stopped");
}

bool GStreamerReceiver::is_receiving() const {
    return _is_receiving;
}

Ref<ImageTexture> GStreamerReceiver::get_texture() const {
    return _texture;
}

void GStreamerReceiver::set_port(int p_port) { _port = p_port; }
int GStreamerReceiver::get_port() const { return _port; }
void GStreamerReceiver::set_auto_start(bool p_auto) { _auto_start = p_auto; }
bool GStreamerReceiver::get_auto_start() const { return _auto_start; }
