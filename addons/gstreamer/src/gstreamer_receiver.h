#ifndef GSTREAMER_RECEIVER_H
#define GSTREAMER_RECEIVER_H

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

class GStreamerReceiver : public Node {
    GDCLASS(GStreamerReceiver, Node)

private:
    GstElement *_pipeline = nullptr;
    GstElement *_appsink = nullptr;

    bool _is_receiving = false;

    // Thread-safe frame aktarimi (GStreamer thread -> Godot main thread)
    // std::vector kullanilir - Godot tipleri thread-safe degil
    std::mutex _frame_mutex;
    std::vector<uint8_t> _raw_buffer;
    int _frame_width = 0;
    int _frame_height = 0;
    std::atomic<bool> _has_new_frame{false};
    uint64_t _received_frame_count = 0;

    // Cikis texture'u (main thread'de guncellenir)
    Ref<ImageTexture> _texture;

    // Export properties
    int _port = 5005;
    bool _auto_start = true;

    bool _create_pipeline();
    void _destroy_pipeline();

    // GStreamer callback (GStreamer streaming thread'inde cagrilir)
    // Dogru imza: GstAppSink* (GstElement* degil)
    static GstFlowReturn _on_new_sample(GstAppSink *sink, gpointer user_data);

protected:
    static void _bind_methods();

public:
    GStreamerReceiver();
    ~GStreamerReceiver();

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    void start_receiving();
    void stop_receiving();
    bool is_receiving() const;
    Ref<ImageTexture> get_texture() const;

    void set_port(int p_port);
    int get_port() const;
    void set_auto_start(bool p_auto);
    bool get_auto_start() const;
};

} // namespace godot

#endif // GSTREAMER_RECEIVER_H
