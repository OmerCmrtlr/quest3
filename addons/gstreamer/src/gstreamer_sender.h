#ifndef GSTREAMER_SENDER_H
#define GSTREAMER_SENDER_H

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

#include <gst/gst.h>
#include <gst/app/gstappsrc.h>

namespace godot {

class GStreamerSender : public Camera3D {
    GDCLASS(GStreamerSender, Camera3D)

private:
    GstElement *_pipeline = nullptr;
    GstElement *_appsrc = nullptr;

    bool _is_streaming = false;
    uint64_t _frame_count = 0;
    double _time_accumulator = 0.0;

    // SubViewport capture system
    SubViewport *_capture_viewport = nullptr;
    Camera3D *_capture_camera = nullptr;

    void _setup_capture_viewport();
    void _teardown_capture_viewport();
    void _sync_capture_camera();

    // Export properties (v4.0: 1280x720, 6Mbps — sahne + kamera ayri portlarda)
    int _width = 1280;
    int _height = 720;
    int _fps = 30;
    int _bitrate = 2000;
    String _host = "127.0.0.1";
    int _port = 5002;
    bool _auto_start = true;

    bool _create_pipeline();
    void _destroy_pipeline();

protected:
    static void _bind_methods();

public:
    GStreamerSender();
    ~GStreamerSender();

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    void start_streaming();
    void stop_streaming();
    bool is_streaming() const;

    void set_stream_width(int p_width);
    int get_stream_width() const;
    void set_stream_height(int p_height);
    int get_stream_height() const;
    void set_stream_fps(int p_fps);
    int get_stream_fps() const;
    void set_bitrate(int p_bitrate);
    int get_bitrate() const;
    void set_host(const String &p_host);
    String get_host() const;
    void set_port(int p_port);
    int get_port() const;
    void set_auto_start(bool p_auto);
    bool get_auto_start() const;
};

} // namespace godot

#endif // GSTREAMER_SENDER_H
