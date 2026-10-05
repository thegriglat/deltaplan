class_name AchievementFeed
extends RefCounted
## Поток событий полёта для ачивок (контракт S2, docs/contracts/steam.md): словари ctx / s / fin.
## Трекер (ST-6) о Game и планере ничего не знает — слушает эти сигналы (через автозагрузку
## Achievements, если она есть). Game создаёт одну ленту, зовёт begin / tick / finish / cancel.

signal flight_started(ctx: Dictionary)
signal flight_sample(s: Dictionary)
signal flight_finished(fin: Dictionary)

## Период выборки, с.
const SAMPLE_PERIOD_S := 1.0
## Спираль: поворот не меньше этого (как FlightStats.CIRCLING_TURN_RATE_DEG_S) не меньше столько, с.
const CIRCLING_MIN_S := 3.0
## «Рядом» для near_climbing_live: по горизонтали, м; набор выше, м/с.
const NEAR_RADIUS_M := 200.0
const NEAR_VARIO_MS := 0.5

var active := false

var _game: Game
var _t := 0.0
var _acc := 0.0
var _turn_s := 0.0
var _circling := false
var _last_track := NAN
var _seen_others: Dictionary = {}  # id → true: отрывались за этот полёт


func _init(game: Game = null) -> void:
	_game = game


## Отрыв: ctx по S2. Повторный вызов в том же полёте — игнорируется.
func begin(tel: Telemetry) -> void:
	if active or _game == null:
		return
	active = true
	_t = 0.0
	_acc = 0.0
	_turn_s = 0.0
	_circling = false
	_last_track = NAN
	_seen_others.clear()
	flight_started.emit(_make_ctx(tel))


## Шаг физики в воздухе; раз в секунду — flight_sample.
func tick(dt: float, tel: Telemetry) -> void:
	if not active:
		return
	_t += dt
	_acc += dt
	_update_circling(dt, tel)
	if _acc >= SAMPLE_PERIOD_S:
		_acc -= SAMPLE_PERIOD_S
		_scan_others()
		flight_sample.emit(_make_sample(tel))


## Итог: ровно один flight_finished на begin; без begin — ничего.
func finish(kind: String, info: Dictionary, tel: Telemetry) -> void:
	if not active:
		return
	active = false
	var fin := info.duplicate()
	fin["kind"] = kind
	fin["land_pos"] = tel.position
	fin["land_alt_msl"] = tel.altitude_msl
	_scan_others()
	var others := _others_now()
	fin["others_total"] = _seen_others.size()
	fin["others_airborne"] = int(others.airborne)
	fin["live_peers"] = int(others.live_peers)
	flight_finished.emit(fin)


## Полёт брошен без посадки (меню, «Ещё раз», буксир): flight_finished не шлётся.
func cancel() -> void:
	active = false


# ---------------------------------------------------------------- словари


func _make_ctx(tel: Telemetry) -> Dictionary:
	var s := _game.settings
	var wind := _wind_at_launch(tel.position)
	return {
		"place_key": place_key(s),
		"wing": s.wing,
		"net": _game.net != null,
		"launch_pos": tel.position,
		"launch_alt_msl": tel.altitude_msl,
		"wind_ms": wind.x,
		"wind_from_deg": wind.y,
	}


func _make_sample(tel: Telemetry) -> Dictionary:
	var others := _others_now()
	return {
		"t": _t,
		"pos": tel.position,
		"alt_msl": tel.altitude_msl,
		"agl": tel.altitude_agl,
		"vario": tel.vario,
		"circling": _circling,
		"cloud_base_msl": _cloud_base_msl(),
		"sun_elev_deg": _sun_elev_deg(),
		"others_airborne": int(others.airborne),
		"near_climbing_live": _near_climbing_live(tel.position),
	}


## "<location_id>/<site_id>", для точки с карты — "pick/<lat 3 знака>,<lon 3 знака>".
static func place_key(s: FlightSettings) -> String:
	if not is_nan(s.pick_lat) and not is_nan(s.pick_lon):
		return "pick/%.3f,%.3f" % [s.pick_lat, s.pick_lon]
	return "%s/%s" % [s.location_id, s.site_id]


# ---------------------------------------------------------------- источники


## Vector2(скорость на 10 м над стартом, м/с; откуда дует, ° по компасу); NAN — неизвестно.
func _wind_at_launch(pos: Vector3) -> Vector2:
	var air := _game.air
	if air == null or not air.has_method("mean_wind_at"):
		return Vector2(NAN, NAN)
	var ground_y := _game.terrain.height_at(pos.x, pos.z)
	var w: Vector3 = air.call("mean_wind_at", Vector3(pos.x, ground_y + 10.0, pos.z))
	var speed := Vector2(w.x, w.z).length()
	if speed < 0.05:
		return Vector2(speed, NAN)  # штиль — направления нет
	# Вектор — куда дует (x — восток, −z — север); компас «откуда» = на 180° от него.
	var to_deg := rad_to_deg(atan2(w.x, -w.z))
	return Vector2(speed, fposmod(to_deg + 180.0, 360.0))


## Нижняя кромка кучевых, м над морем; NAN — воздух без облаков (CalmAir) или «голубой» день.
func _cloud_base_msl() -> float:
	var air := _game.air
	if air == null or not air.has_method("get_cloudbase_msl"):
		return NAN
	var w: Variant = air.get("weather")
	if w is Dictionary and float((w as Dictionary).get("dry_thermal_fraction", 0.0)) >= 0.999:
		return NAN
	return float(air.call("get_cloudbase_msl"))


func _sun_elev_deg() -> float:
	var clock := _game.sky.clock if _game.sky != null else null
	if clock == null:
		return NAN
	return clock.angles().y


func _update_circling(dt: float, tel: Telemetry) -> void:
	if dt <= 0.0:
		return
	if not is_nan(_last_track):
		var rate := absf(wrapf(tel.track_deg - _last_track, -180.0, 180.0)) / dt
		if rate >= FlightStats.CIRCLING_TURN_RATE_DEG_S:
			_turn_s += dt
		else:
			_turn_s = 0.0
	_last_track = tel.track_deg
	_circling = _turn_s >= CIRCLING_MIN_S


## Другие пилоты (живые и боты): {id: {airborne, live, pos, vario}}.
func _others() -> Dictionary:
	var out := {}
	var net := _game.net
	if net != null:
		var pilots: Object = net.pilots
		if pilots == null or net.zone == null:
			return out
		var me := String(net.zone.my_id)
		for id: String in pilots.call("get_pilot_ids"):
			if id == me:
				continue
			var s: Dictionary = pilots.call("sample", id)
			if s.is_empty():
				continue
			var vel: Vector3 = s.get("vel", Vector3.ZERO)
			out["n:" + id] = {
				"airborne": String(s.get("phase", "")) == "FLY",
				"live": not bool(s.get("is_bot", false)),
				"pos": s.get("pos", Vector3.ZERO),
				"vario": vel.y,
			}
		return out
	if _game.bots != null:
		for a in _game.bots.agents:
			out["b:%d" % a.id] = {
				"airborne": a.is_airborne(),
				"live": false,
				"pos": a.telemetry().position,
				"vario": a.telemetry().vario,
			}
	return out


func _scan_others() -> void:
	var all := _others()
	for k: String in all:
		if bool(all[k].airborne):
			_seen_others[k] = true


func _others_now() -> Dictionary:
	var all := _others()
	var air := 0
	var live := 0
	for k: String in all:
		if bool(all[k].airborne):
			air += 1
		if bool(all[k].live):
			live += 1
	return {"airborne": air, "live_peers": live if _game.net != null else 0}


func _near_climbing_live(pos: Vector3) -> int:
	if _game.net == null:
		return 0
	var n := 0
	var all := _others()
	for k: String in all:
		var o: Dictionary = all[k]
		if not bool(o.live) or not bool(o.airborne):
			continue
		var p: Vector3 = o.pos
		if Vector2(p.x - pos.x, p.z - pos.z).length() <= NEAR_RADIUS_M and float(o.vario) > NEAR_VARIO_MS:
			n += 1
	return n
