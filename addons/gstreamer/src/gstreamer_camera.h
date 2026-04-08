#ifndef GSTREAMER_CAMERA_H
#define GSTREAMER_CAMERA_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <gst/gst.h>
#include <gst/app/gstappsink.h>

#include <mutex>
#include <atomic>
#include <vector>

namespace godot {

class GStreamerCamera : public Node {
    GDCLASS(GStreamerCamera, Node)

private:
    GstElement *_pipeline = nullptr;
    GstElement *_appsink = nullptr;

    bool _is_capturing = false;

    // Thread-safe frame aktarimi (GStreamer thread -> Godot main thread)
    std::mutex _frame_mutex;
    std::vector<uint8_t> _raw_buffer;
    int _frame_width = 0;
    int _frame_height = 0;
    std::atomic<bool> _has_new_frame{false};

    // Cikis texture'u (main thread'de guncellenir)
    Ref<ImageTexture> _texture;

    // Export properties (v4.1 uyumlu: autovideosrc, device bos=varsayilan)
    String _device = "";  // bos=autovideosrc, /dev/video2=v4l2src ile USB kamera
    int _width = 1280;
    int _height = 720;
    bool _auto_start = true;
    int _stream_port = 5006;   // Kamera Python dinler (sahne 5002'de)
    int _stream_bitrate = 2000;
    String _stream_host = "127.0.0.1";

    bool _create_pipeline();
    void _destroy_pipeline();

    static GstFlowReturn _on_new_sample(GstAppSink *sink, gpointer user_data);

protected:
    static void _bind_methods();

public:
    GStreamerCamera();
    ~GStreamerCamera();

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    void start_capture();
    void stop_capture();
    bool is_capturing() const;
    Ref<ImageTexture> get_texture() const;

    void set_device(const String &p_device);
    String get_device() const;
    void set_capture_width(int p_width);
    int get_capture_width() const;
    void set_capture_height(int p_height);
    int get_capture_height() const;
    void set_auto_start(bool p_auto);
    bool get_auto_start() const;
    void set_stream_port(int p_port);
    int get_stream_port() const;
    void set_stream_bitrate(int p_kbps);
    int get_stream_bitrate() const;
    void set_stream_host(const String &p_host);
    String get_stream_host() const;
};

} // namespace godot

#endif // GSTREAMER_CAMERA_H
