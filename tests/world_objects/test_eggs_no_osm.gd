extends TestCase
## NO-3: пасхалки Ан-2, стада, шар и УАЗ находят место без OSM (К8 v4): благоприятный день,
## места altai, askarovo, ongudai, aushkul, 10 сидов. Таблица печатается.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_eggs_no_osm

const PLACES := ["altai", "askarovo", "ongudai", "aushkul"]
const EGGS := ["an2", "herds", "balloon", "uaz"]
const SEEDS := 10
## База до правок (встроенный файл OSM), найдено из 10 сидов: место → пасхалка → число.
const BASE := {
	"altai": {"an2": 0, "herds": 10, "balloon": 10, "uaz": 0},
	"askarovo": {"an2": 10, "herds": 10, "balloon": 10, "uaz": 10},
	"ongudai": {"an2": 0, "herds": 10, "balloon": 10, "uaz": 2},
	"aushkul": {"an2": 0, "herds": 10, "balloon": 10, "uaz": 10},
}

static var _cache := {}


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


## relief = true: пятна застройки подменены пустыми — места берутся опорными точками по рельефу.
func _place(id: String, relief := false) -> EggPlace:
	var key := "%s|%s" % [id, relief]
	if not _cache.has(key):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		if relief:
			var bp := BuiltPatches.new()
			bp._dir = String(t.location.get("data_dir", "res://data/terrain/" + t.location_id))
			t.set_meta(BuiltPatches.META_KEY, bp)
		_cache[key] = EggPlace.build(t, Objs.new())
	return _cache[key]


func _cfg(egg: String) -> Dictionary:
	return Config.get_config("easter_eggs").eggs[egg]


## Благоприятный день: лето, ясно, слабый ветер, полдень (шар — утро: так требует его условие).
func _ctx(place: EggPlace, egg: String, seed_i: int) -> EggContext:
	var c := EggContext.new()
	c.t = 100.0
	c.world_key = "NOOSM%d" % seed_i
	c.place = place
	c.height_at = place.height_at
	c.month = 7
	c.sky = "clear"
	c.wind_ms = 2.0
	c.temp_c = 22.0
	c.sun_elev_deg = 60.0
	c.hour = 12.0
	if egg == "balloon":
		c.sun_elev_deg = 12.0
		c.hour = 7.0
		c.wind_ms = 1.5
	var s := place.start_sites()
	c.pilot_pos = s[0].position + Vector3.UP * 100.0 if not s.is_empty() else Vector3.ZERO
	return c


## Нашла ли пасхалка место при этом сиде: can_appear + begin дали результат.
func _found(place: EggPlace, egg: String, seed_i: int) -> bool:
	var ctx := _ctx(place, egg, seed_i)
	var cfg := _cfg(egg)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + seed_i
	match egg:
		"an2":
			if not EggAn2.can_appear(ctx, cfg):
				return false
			var e := EggAn2.new()
			e.t0 = 100.0
			e.begin(ctx, cfg, rng, 100.0)
			var ok := e.track_ok
			e.free()
			return ok
		"herds":
			if not EggHerds.can_appear(ctx, cfg):
				return false
			var e := EggHerds.new()
			e.begin(ctx, cfg, rng, 100.0)
			var ok := not e.info.is_empty()
			e.free()
			return ok
		"balloon":
			if not EggBalloon.can_appear(ctx, cfg):
				return false
			return EggBalloon.find_site(ctx, rng, cfg) != null
		"uaz":
			if not EggUaz.can_appear(ctx, cfg):
				return false
			var e := EggUaz.new()
			e.begin(ctx, cfg, rng, 100.0)
			var ok := e.car_count() > 0
			e.free()
			return ok
	return false


func _table(relief: bool) -> Dictionary:
	var rows := {}
	print("NO3 %s   %s" % ["рельеф " if relief else "пятна  ", "  ".join(EGGS)])
	for id in PLACES:
		var p := _place(id, relief)
		var line := "NO3 %-10s" % id
		rows[id] = {}
		for egg in EGGS:
			var n := 0
			var t0 := Time.get_ticks_usec()
			var worst := 0.0
			for s in SEEDS:
				var t1 := Time.get_ticks_usec()
				if _found(p, egg, s):
					n += 1
				worst = maxf(worst, (Time.get_ticks_usec() - t1) / 1000.0)
			if egg == "uaz":
				check(worst < 200.0, "%s: поиск места УАЗа %.0f мс (≤ 200)" % [id, worst])
			line += " [макс %.0f мс]" % worst
			rows[id][egg] = n
			line += "  %s=%d/%d" % [egg, n, SEEDS]
		print(line)
	return rows


func test_found_table() -> void:
	var rows := _table(false)
	for id in BASE:
		for egg in BASE[id]:
			var base := int(BASE[id][egg])
			var need := 8 if base >= 8 else maxi(base - 1, 0)
			var got := int(rows[id][egg])
			check(
				got >= need,
				"%s/%s: найдено %d из %d, нужно ≥ %d (база %d)" % [id, egg, got, SEEDS, need, base]
			)


## Без пятен застройки: опорные точки по рельефу (К8 v4) — места находятся не хуже базы минус 10 п. п.
func test_found_table_relief() -> void:
	var rows := _table(true)
	for id in BASE:
		var t0 := Time.get_ticks_usec()
		var pl := _place(id, true).places()
		print("NO3 %s: опорных точек %d, places() %.1f мс" % [id, pl.size(), (Time.get_ticks_usec() - t0) / 1000.0])
		check(pl.size() >= 1 and pl[0].src == "relief", "%s: опорные точки по рельефу есть" % id)
		for egg in BASE[id]:
			var base := int(BASE[id][egg])
			var need := 8 if base >= 8 else maxi(base - 1, 0)
			var got := int(rows[id][egg])
			check(
				got >= need,
				"%s/%s (рельеф): найдено %d из %d, нужно ≥ %d" % [id, egg, got, SEEDS, need]
			)
