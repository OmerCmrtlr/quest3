extends Node
## Binary addon eksik olsa bile sahnenin kırılmasını engeller.
## GStreamerReceiver class'i bulunursa ona köprü olur.

@export var port: int = 5010
@export var auto_start: bool = false
@export var verbose_log: bool = true
@export var use_udp_jpeg_fallback: bool = true
@export var max_frame_bytes: int = 4000000
@export var udp_chunk_payload_bytes: int = 1200
@export var frame_assembly_timeout_ms: int = 350

const GST_EXTENSION_PATH := "res://addons/gstreamer/gstreamer.gdextension"
const PACKET_MAGIC_A := 0x51 # 'Q'
const PACKET_MAGIC_B := 0x4A # 'J'
const HEADER_SIZE := 12

var _backend: Node = null
var _receiving := false
var _warned_missing_backend := false
var _fallback_warned := false

var _udp := PacketPeerUDP.new()
var _udp_listening := false

var _active_frame_id := -1
var _active_total_chunks := 0
var _active_chunks: Array = []
var _active_received_count := 0
var _active_started_ms := 0

var _fallback_texture: ImageTexture = null
var _first_fallback_frame_logged := false

func _platform_extension_available() -> bool:
	var os_name := OS.get_name()
	if os_name == "Android":
		if use_udp_jpeg_fallback:
			# Android'de UDP fallback kullanılacaksa native backend'i zorlamayalım.
			return false

		return FileAccess.file_exists("res://addons/gstreamer/bin/libgstreamer_godot.android.template_debug.arm64.so") \
			or FileAccess.file_exists("res://addons/gstreamer/bin/libgstreamer_godot.android.template_release.arm64.so")

	if os_name == "Linux":
		return FileAccess.file_exists("res://addons/gstreamer/bin/libgstreamer_godot.linux.template_debug.x86_64.so") \
			or FileAccess.file_exists("res://addons/gstreamer/bin/libgstreamer_godot.linux.template_release.x86_64.so")

	return true

func _ensure_extension_loaded() -> void:
	if not FileAccess.file_exists(GST_EXTENSION_PATH):
		return

	if not _platform_extension_available():
		return

	if GDExtensionManager.is_extension_loaded(GST_EXTENSION_PATH):
		return

	var err := GDExtensionManager.load_extension(GST_EXTENSION_PATH)
	if err != OK and err != ERR_ALREADY_EXISTS:
		if verbose_log:
			push_warning("[GstFallback] gstreamer.gdextension yüklenemedi: %s" % err)

func _ready() -> void:
	set_process(true)
	_init_backend_if_available()
	if auto_start:
		start_receiving()

func _init_backend_if_available() -> void:
	if _backend != null:
		return

	_ensure_extension_loaded()

	if not ClassDB.class_exists("GStreamerReceiver"):
		_backend = null
		if verbose_log and not _warned_missing_backend and not use_udp_jpeg_fallback:
			push_warning("[GstFallback] GStreamerReceiver class bulunamadı. Binary addon eksik olabilir.")
			_warned_missing_backend = true
		return

	_backend = ClassDB.instantiate("GStreamerReceiver")
	if _backend == null:
		if verbose_log and not _warned_missing_backend:
			push_warning("[GstFallback] GStreamerReceiver instantiate edilemedi.")
			_warned_missing_backend = true
		return

	_backend.name = "BackendReceiver"
	add_child(_backend)

	_set_if_property_exists(_backend, "port", port)
	_set_if_property_exists(_backend, "auto_start", false)

	if verbose_log:
		print("[GstFallback] GStreamerReceiver backend aktif.")

func _start_udp_fallback_receiver() -> bool:
	if not use_udp_jpeg_fallback:
		return false

	if _udp_listening:
		return true

	var err := _udp.bind(port, "*")
	if err != OK:
		if verbose_log:
			push_warning("[GstFallback] UDP fallback dinleme açılamadı (port=%s, err=%s)" % [port, err])
		return false

	_udp_listening = true
	_reset_frame_assembly()

	if verbose_log:
		print("[GstFallback] UDP JPEG fallback dinleniyor: 0.0.0.0:%s" % port)
	return true

func _stop_udp_fallback_receiver() -> void:
	if _udp_listening:
		_udp.close()
	_udp_listening = false
	_reset_frame_assembly()

func _process(_delta: float) -> void:
	if _backend != null:
		return

	if not _receiving:
		return

	if not use_udp_jpeg_fallback:
		return

	if not _udp_listening:
		if not _start_udp_fallback_receiver():
			return

	_read_udp_frames()

func _read_u16_be(data: PackedByteArray, offset: int) -> int:
	return (int(data[offset]) << 8) | int(data[offset + 1])

func _read_u32_be(data: PackedByteArray, offset: int) -> int:
	return (int(data[offset]) << 24) | (int(data[offset + 1]) << 16) | (int(data[offset + 2]) << 8) | int(data[offset + 3])

func _reset_frame_assembly() -> void:
	_active_frame_id = -1
	_active_total_chunks = 0
	_active_chunks.clear()
	_active_received_count = 0
	_active_started_ms = 0

func _begin_frame(frame_id: int, chunk_count: int, now_ms: int) -> void:
	_active_frame_id = frame_id
	_active_total_chunks = chunk_count
	_active_chunks = []
	_active_chunks.resize(chunk_count)
	for i in range(chunk_count):
		_active_chunks[i] = null
	_active_received_count = 0
	_active_started_ms = now_ms

func _read_udp_frames() -> void:
	var now_ms := Time.get_ticks_msec()

	if _active_frame_id >= 0 and now_ms - _active_started_ms > frame_assembly_timeout_ms:
		_reset_frame_assembly()

	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		if _udp.get_packet_error() != OK:
			continue

		if packet.size() <= HEADER_SIZE:
			continue

		if int(packet[0]) != PACKET_MAGIC_A or int(packet[1]) != PACKET_MAGIC_B:
			continue

		var frame_id := _read_u32_be(packet, 2)
		var chunk_index := _read_u16_be(packet, 6)
		var chunk_count := _read_u16_be(packet, 8)
		var payload_len := _read_u16_be(packet, 10)

		if chunk_count <= 0 or chunk_count > 4096:
			continue
		if chunk_index < 0 or chunk_index >= chunk_count:
			continue
		if payload_len <= 0 or payload_len > max_frame_bytes:
			continue
		if payload_len > packet.size() - HEADER_SIZE:
			continue

		if _active_frame_id < 0:
			_begin_frame(frame_id, chunk_count, now_ms)
		elif frame_id > _active_frame_id:
			_begin_frame(frame_id, chunk_count, now_ms)
		elif frame_id < _active_frame_id:
			continue
		elif chunk_count != _active_total_chunks:
			_begin_frame(frame_id, chunk_count, now_ms)

		if _active_chunks[chunk_index] == null:
			var chunk := packet.slice(HEADER_SIZE, HEADER_SIZE + payload_len)
			_active_chunks[chunk_index] = chunk
			_active_received_count += 1

		if _active_received_count >= _active_total_chunks:
			var merged := PackedByteArray()
			for i in range(_active_total_chunks):
				var part = _active_chunks[i]
				if part == null:
					merged = PackedByteArray()
					break

				merged.append_array(part)
				if merged.size() > max_frame_bytes:
					merged = PackedByteArray()
					if verbose_log and not _fallback_warned:
						push_warning("[GstFallback] UDP frame boyutu limit aştı: %s" % merged.size())
						_fallback_warned = true
					break

			if merged.size() > 0:
				_decode_and_store_frame(merged)

			_reset_frame_assembly()

func _decode_and_store_frame(frame_bytes: PackedByteArray) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(frame_bytes)
	if err != OK:
		return

	if _fallback_texture == null:
		_fallback_texture = ImageTexture.create_from_image(img)
	else:
		_fallback_texture.update(img)

	if verbose_log and not _first_fallback_frame_logged:
		print("[GstFallback] UDP fallback ile ilk frame alındı.")
		_first_fallback_frame_logged = true

func _set_if_property_exists(target: Object, prop_name: String, value) -> void:
	for prop in target.get_property_list():
		if String(prop.name) == prop_name:
			target.set(prop_name, value)
			return

func start_receiving() -> void:
	_init_backend_if_available()
	if _backend == null:
		_receiving = _start_udp_fallback_receiver()
		return

	if _backend.has_method("start_receiving"):
		_backend.call("start_receiving")

	_receiving = true

func stop_receiving() -> void:
	if _backend != null and _backend.has_method("stop_receiving"):
		_backend.call("stop_receiving")
	_stop_udp_fallback_receiver()
	_receiving = false

func is_receiving() -> bool:
	if _backend != null and _backend.has_method("is_receiving"):
		return bool(_backend.call("is_receiving"))

	if use_udp_jpeg_fallback:
		var has_texture := _fallback_texture != null
		return _receiving and (_udp_listening or has_texture)

	return _receiving

func is_backend_available() -> bool:
	_init_backend_if_available()
	if _backend != null:
		return true

	return use_udp_jpeg_fallback

func get_texture():
	if _backend != null and _backend.has_method("get_texture"):
		return _backend.call("get_texture")

	if _fallback_texture != null:
		return _fallback_texture

	return null

func _exit_tree() -> void:
	stop_receiving()
