extends TextureRect
## GStreamerReceiver veya GStreamerCamera'dan gelen texture'ı ekrana yansıtır.

@export var receiver_path: NodePath
@export var source_retry_interval_sec: float = 1.0

var _source: Node = null
var _source_type := ""
var _first_frame_logged := false
var _retry_timer := 0.0
var _warned_empty_path := false
var _warned_not_found := false
var _warned_unsupported := false

func _ready() -> void:
	_retry_timer = max(0.1, source_retry_interval_sec)
	_find_source()

func _find_source() -> void:
	if receiver_path.is_empty():
		if not _warned_empty_path:
			push_error("[ReceiverDisplay] receiver_path boş")
			_warned_empty_path = true
		return

	_warned_empty_path = false

	_source = get_node_or_null(receiver_path)
	if _source == null:
		if not _warned_not_found:
			push_warning("[ReceiverDisplay] Kaynak bulunamadı: %s" % receiver_path)
			_warned_not_found = true
		return

	_warned_not_found = false

	if _source.has_method("is_receiving"):
		_source_type = "receiver"
	elif _source.has_method("is_capturing"):
		_source_type = "camera"
	else:
		_source_type = "unknown"
		if not _warned_unsupported:
			push_warning("[ReceiverDisplay] Kaynak bulundu ama receiver/camera API metodu yok. Texture bekleniyor.")
			_warned_unsupported = true
		return

	_warned_unsupported = false

func _is_source_active() -> bool:
	if _source == null:
		return false

	if _source_type == "receiver" and _source.has_method("is_receiving"):
		return _source.call("is_receiving")

	if _source_type == "camera" and _source.has_method("is_capturing"):
		return _source.call("is_capturing")

	if _source.has_method("is_receiving"):
		return _source.call("is_receiving")

	if _source.has_method("is_capturing"):
		return _source.call("is_capturing")

	return false

func _process(_delta: float) -> void:
	if _source == null:
		_retry_timer += _delta
		if _retry_timer >= max(0.1, source_retry_interval_sec):
			_retry_timer = 0.0
			_find_source()
		return

	if not is_instance_valid(_source):
		_source = null
		_source_type = ""
		return

	if _is_source_active():
		if not _source.has_method("get_texture"):
			return

		var tex = _source.call("get_texture")
		if tex != null:
			texture = tex
			if not _first_frame_logged:
				print("[ReceiverDisplay] İlk texture alındı.")
				_first_frame_logged = true
