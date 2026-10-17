extends Node
## Вероятность встретить воздушный шар и Ан-2 за полёт 20 и 40 минут (живой мир: пасхалки
## встречаются почти в каждом полёте при подходящих условиях). Считается по условиям из
## configs/easter_eggs.json на реальных локациях: сезон апрель–октябрь, ветер 2 м/с, ясно,
## пилот у первого старта. Часы старта — фиксированный список экрана «Полёт…».
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_meet

const An2 := preload("res://scripts/world_objects/easter_eggs/an2.gd")
const HOURS := [9.0, 12.0, 15.0, 20.0]
const LAT := 51.0
const SEEDS := 24

static var _cache := {}

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


func _place(id: String) -> EggPlace:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		_cache[id] = EggPlace.build(t, Objs.new())
	return _cache[id]


static func sun_elev_deg(month: int, hour: float) -> float:
	var doy := (month - 1) * 30.4 + 15.0
	var dec := deg_to_rad(23.44) * sin(TAU * (284.0 + doy) / 365.0)
	var lat := deg_to_rad(LAT)
	var ha := deg_to_rad(15.0 * (hour - 12.0))
	return rad_to_deg(asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)))


func _ctx(p: EggPlace, month: int, hour: float, seed_v: int) -> EggContext:
	var c := EggContext.new()
	c.world_key = "meet%d" % seed_v
	c.place = p
	c.month = month
	c.hour = hour
	c.sun_elev_deg = sun_elev_deg(month, hour)
	c.wind_ms = 2.0
	c.wind_from_deg = 45.0 * (seed_v % 8)
	c.sky = "clear"
	c.height_at = p.height_at
	var st := p.start_sites()
	c.pilot_pos = st[0].position if not st.is_empty() else Vector3.ZERO
	return c


## Шар: доля (сезон × сид ветра) полётов с появлением; момент — равномерно в window_s.
func _balloon(p: EggPlace, start_h: float, cfg: Dictionary) -> float:
	var w: Array = cfg.window_s
	var hit := 0
	var n := 0
	for month in range(4, 11):
		for sd in SEEDS:
			var t0 := lerpf(float(w[0]), float(w[1]), (sd % 6) / 5.0)
			var c := _ctx(p, month, start_h + t0 / 3600.0, sd)
			n += 1
			if EggBalloon.can_appear(c, cfg):
				hit += 1
	return float(hit) / n * float(cfg.chance)


## Ан-2: P(трасса найдена) на локации (по сидам); P(встреча за minutes) по окнам slot_s.
func _an2(p: EggPlace, start_h: float, minutes: float, cfg: Dictionary) -> Array:
	var found := 0
	for sd in SEEDS:
		var egg := An2.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 5000 + sd
		egg.begin(_ctx(p, 7, 12.0, sd), cfg, rng, 0.0)
		if egg.track_ok:
			found += 1
		egg.free()
	var p_track := float(found) / SEEDS
	var slot := float(cfg.slot_s)
	var q_slot := minf(1.0, slot / float(cfg.mean_interval_s))
	var months: Array = cfg.months
	var total := 0.0
	var nm := 0
	for month in range(4, 11):
		var miss := 1.0
		for k in int(minutes * 60.0 / slot):
			var hr := start_h + (k + 0.5) * slot / 3600.0
			var ok := (
				sun_elev_deg(month, hr) > float(cfg.sun_min_deg)
				and month >= int(months[0])
				and month <= int(months[1])
			)
			if ok:
				miss *= 1.0 - q_slot * p_track
		total += 1.0 - miss
		nm += 1
	return [p_track, total / nm]


func test_meeting_probability() -> void:
	var cfg: Dictionary = Config.get_config("easter_eggs").eggs
	print("         МЕТКА_ВСТРЕЧИ локация  час_старта  шар  Ан-2_трасса  Ан-2_20мин  Ан-2_40мин")
	var sums := {}
	for id in ["askarovo", "altai", "aushkul", "ongudai"]:
		var p := _place(id)
		for h in HOURS:
			var b := _balloon(p, h, cfg.balloon)
			var a20 := _an2(p, h, 20.0, cfg.an2)
			var a40 := _an2(p, h, 40.0, cfg.an2)
			print(
				(
					"         MEET %-9s %4.0f   %.2f   %.2f   %.2f   %.2f"
					% [id, h, b, a20[0], a20[1], a40[1]]
				)
			)
			sums[id] = sums.get(id, []) + [b, a20[1], a40[1]]
	for id in sums:
		var v: Array = sums[id]
		var nb := 0.0
		var n20 := 0.0
		var n40 := 0.0
		for i in HOURS.size():
			nb += v[i * 3]
			n20 += v[i * 3 + 1]
			n40 += v[i * 3 + 2]
		print(
			(
				"         MEET среднее по часам %-9s шар %.2f  Ан-2 20 мин %.2f  40 мин %.2f"
				% [id, nb / HOURS.size(), n20 / HOURS.size(), n40 / HOURS.size()]
			)
		)
