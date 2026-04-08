#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include <gst/gst.h>

#include "gstreamer_sender.h"
#include "gstreamer_receiver.h"
#include "gstreamer_camera.h"

using namespace godot;

void initialize_gstreamer_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    // GStreamer'i modul yuklenirken bir kez baslat
    gst_init(nullptr, nullptr);

    ClassDB::register_class<GStreamerSender>();
    ClassDB::register_class<GStreamerReceiver>();
    ClassDB::register_class<GStreamerCamera>();
}

void uninitialize_gstreamer_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    // gst_deinit() kasitli olarak cagrilmaz - Godot kapanirken
    // node'lar hala aktif olabilir ve GStreamer thread'leri calisabilir.
}

extern "C" {
GDExtensionBool GDE_EXPORT gstreamer_library_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {

    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_gstreamer_module);
    init_obj.register_terminator(uninitialize_gstreamer_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
