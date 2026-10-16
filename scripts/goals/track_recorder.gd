class_name TrackRecorder
extends RefCounted
## Запись телеметрии в FlightTrack (GL-К5): не чаще 1 Гц, только в воздухе.

const PERIOD_S := 1.0

var _track := FlightTrack.new()
var _fn := Callable()
var _t0 := NAN
var _last_t := -INF


## local_to_latlon: Callable(x, z) -> Vector2(lat, lon).
func start(local_to_latlon: Callable) -> void:
	_track = FlightTrack.new()
	_track.source = "last"
	_fn = local_to_latlon
	_t0 = NAN
	_last_t = -INF


func update(t: Telemetry) -> void:
	if t.on_ground or not _fn.is_valid():
		return
	if t.time_s - _last_t < PERIOD_S:
		return
	if is_nan(_t0):
		_t0 = t.time_s
	var ll: Vector2 = _fn.call(t.position.x, t.position.z)
	_track.append(ll.x, ll.y, t.position.y, t.time_s - _t0)
	_last_t = t.time_s


func track() -> FlightTrack:
	return _track
