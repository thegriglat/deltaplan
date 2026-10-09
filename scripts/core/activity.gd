extends Node
## Activity (контракт S3, docs/contracts/steam.md): что сейчас делает пилот — для Rich Presence Steam
## (и чему угодно ещё). Пишут scenes/main.gd (меню/загрузка/пауза/итог) и Game (фаза, сеть, высота).
## Ключи: mode, place, net, zone_code, peers, alt_msl. `changed` — только при реальной смене значения.

signal changed

const DEFAULTS := {"mode": "menu", "place": "", "net": false, "zone_code": "", "peers": 0, "alt_msl": 0}
## Режимы «в полёте»: их выставляет Game по фазе пилота (остальные — main.gd).
const FLIGHT_MODES := ["launch", "flying", "landed"]

var _state: Dictionary = DEFAULTS.duplicate()


## Слить ключи в состояние; неизвестные ключи игнорируются. Сигнал — только если что-то изменилось.
func set_state(d: Dictionary) -> void:
	var dirty := false
	for k: String in d:
		if DEFAULTS.has(k) and _state[k] != d[k]:
			_state[k] = d[k]
			dirty = true
	if dirty:
		changed.emit()


func state() -> Dictionary:
	return _state.duplicate()


## Режим по фазе пилота (Glider.phase()).
static func mode_for_phase(phase: String) -> String:
	match phase:
		"flying":
			return "flying"
		"landed", "failed":
			return "landed"
	return "launch"  # standing / walking / running


## Отображаемое имя места на языке игры: точка с карты — запись «недавних» рядом, иначе координаты;
## локация — tr её имени (и площадки, если задана).
static func place_name(s: FlightSettings) -> String:
	if s == null:
		return ""
	if s.has_pick():
		for p: Dictionary in RecentPlaces.list():
			var d := RecentPlaces.distance_m(s.pick_lat, s.pick_lon, float(p.get("lat", 0.0)), float(p.get("lon", 0.0)))
			if d <= RecentPlaces.DEDUP_DISTANCE_M:
				return RecentPlaces.display_name(p)
		return RecentPlaces.display_name({"lat": s.pick_lat, "lon": s.pick_lon})
	var loc: Dictionary = Locations.config(s.location_id)
	return TranslationServer.translate(String(loc.get("name", s.location_id)))
