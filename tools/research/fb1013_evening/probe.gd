extends Node
## FBW-1 (feedback-1013): термики вечером осенью при облачности — сценарий пилота через сцену игры
## (main.tscn → _fly), как видит пилот: 15.10 20:00 поясного, облачно, ветер 7 м/с «в старт»,
## горный старт; контроль — 15.07 13:00 ясно. Места: встроенные (Онгудай, Аушкуль, Алтай) и два
## «рантайм-места» (кеш точки user://locations/pt_…: рельеф Онгудая, центр перенесён на 43,3° и
## 58,0° с. ш., пояс — по долготе, как у точки с карты).
##
## Печатает по строке на (место, условие) и пишет csv (--out). Колонки — COLS. Путь термиков:
## «поле» (масштаб 2 из поля AirThermals, GPU) или «аналитика» (headless / нет GPU).
## Для пути поля без GPU (headless) — вход поля на CPU (AirPlace.domain_case, как AirRuntime): H, z_i,
## w* у старта; рождения и w считаются тем путём, что включён.
##
## Аргументы (после --): --out=<csv> --places=a,b --conds=evening,day --minutes=10
## Запуск: tools/research/fb1013_evening/run.sh (headless) или run_gpu.sh (окно, поле).

const MAIN_SCENE := preload("res://scenes/main.tscn")
const COLS := "place,cond,lat,lon,utc,path,psi_deg,sunset_h,heat_w,duty,s_max,z_i_agl,h_2km_mean,h_2km_max,h_dom_max,h_land_max,h_land_max_name,h_built,h_water,wstar,births_10min,alive_t0,thw_max,thw_mean,thw_pos_frac,bub_max,betw_max,betw_mean,gw_total_max,gw_total_mean,gw_mean,gw_therm,gw_sink,gw_turb_max,gw_turb_sd,gw_mean_max,wind_ratio,city_frac,city_h,city_w_max,city_w_mean,city_calm_max,city_therm_max,city_sigma,city_lee_frac"
## Ветер меню, км/ч (7 м/с).
const WIND_KMH := 25.2
## Высота колдуна над стартом, м.
const SOCK_AGL := 6.0
## Встроенные места: id → [место, старт].
const BUILTIN := {
	"ongudai": ["ongudai", "kayancha_south"],
	"aushkul": ["aushkul", "aushtau_east"],
	"altai": ["altai", "sinyukha_west"],
}
## Рантайм-места: id → [исходное место, старт, широта, долгота центра].
const VIRTUAL := {
	"pt43": ["ongudai", "kayancha_south", 43.30, 42.50],
	"pt58": ["ongudai", "kayancha_south", 58.00, 60.00],
}
const CONDS := {
	"evening": {"month": 10, "day": 15, "hour": 20.0, "sky": "overcast"},
	"day": {"month": 7, "day": 15, "hour": 13.0, "sky": "clear"},
}

var _a := {}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	Locations.fixtures_root = "res://tests/fixtures/locations"
	await get_tree().process_frame
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var places := String(_a.get("places", "ongudai,aushkul,altai,pt43,pt58")).split(",")
	var conds := String(_a.get("conds", "evening,day")).split(",")
	var minutes := float(_a.get("minutes", "10"))
	var out := String(_a.get("out", ""))
	for id: String in VIRTUAL:
		_make_virtual(id)
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	var rows: Array[PackedStringArray] = []
	var fa: FileAccess = null
	if out != "":
		fa = FileAccess.open(out, FileAccess.WRITE)
		fa.store_line(COLS)
	print("FB1013 " + COLS)
	for p: String in places:
		for cn: String in conds:
			var row := await _one(main, game, p, cn, minutes)
			rows.append(row)
			var line := ",".join(row)
			print("FB1013 " + line)
			if fa != null:
				fa.store_line(line)
				fa.flush()
	if fa != null:
		fa.close()
	_verdict(rows)
	main.queue_free()


## ИТОГ (FBW-К2 v3): вечер — ψ < 0, H ≤ 0 на всех классах суши, кроме застройки (ночной спад к
## пределу — контрактный тест), w* = 0 у старта, рождений 0, пузырей нет (w пузырей ≤ 0,05 м/с),
## термическая w над «городом» ≤ 1 м/с; день — H > 0 у старта, термики есть
## (рождения или живые у старта, w пузырей ≥ 0,5 м/с).
static func _verdict(rows: Array[PackedStringArray]) -> void:
	var col := {}
	var names := COLS.split(",")
	for i in names.size():
		col[names[i]] = i
	var bad: PackedStringArray = []
	for r in rows:
		var v := func(k: String) -> float: return float(r[col[k]])
		var tag := "%s/%s" % [r[0], r[1]]
		if r[1] == "evening":
			if v.call("psi_deg") >= 0.0:
				bad.append(tag + ": ψ ≥ 0")
			if v.call("h_land_max") > 0.0:
				bad.append(tag + ": H суши > 0 (%s)" % r[col["h_land_max"]])
			if v.call("h_2km_mean") > 0.0 and v.call("wstar") > 0.0:
				bad.append(tag + ": H у старта > 0, w* %s" % r[col["wstar"]])
			if v.call("births_10min") > 0.0:
				bad.append(tag + ": рождений %s" % r[col["births_10min"]])
			if v.call("bub_max") > 0.05:
				bad.append(tag + ": пузыри %s м/с" % r[col["bub_max"]])
			if v.call("city_therm_max") > 1.0:
				bad.append(tag + ": над городом термики %s м/с" % r[col["city_therm_max"]])
		else:
			if v.call("h_2km_mean") <= 0.0:
				bad.append(tag + ": днём H у старта ≤ 0")
			if v.call("births_10min") + v.call("alive_t0") <= 0.0 or v.call("bub_max") < 0.5:
				bad.append(tag + ": днём нет термиков")
	if bad.is_empty():
		print("ИТОГ: термики вечером OK")
	else:
		print("ИТОГ: термики вечером НЕ OK — " + "; ".join(bad))


## Рантайм-место id: копия файлов исходного места в кеш точек, центр и старты перенесены (старт — в той
## же точке рельефа), пояса в конфиге нет — по долготе.
func _make_virtual(id: String) -> void:
	var v: Array = VIRTUAL[id]
	var src_id: String = v[0]
	var lat := float(v[2])
	var lon := float(v[3])
	var key := "pt_fb1013_" + id
	var dst := Locations.cache_dir().path_join(key)
	DirAccess.make_dir_recursive_absolute(dst)
	var src := Locations.fixtures_root.path_join(src_id)
	for f in DirAccess.get_files_at(src):
		if f == "build.json" or f == "meta.json":
			continue
		DirAccess.copy_absolute(src.path_join(f), dst.path_join(f))
	for f: String in ["build.json", "meta.json"]:
		var b: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(src.path_join(f)))
		b.center_lat = lat
		b.center_lon = lon
		if b.has("key"):
			b.key = key
		_write_json(dst.path_join(f), b)
	var cfg: Dictionary = Config.get_config("locations/" + src_id).duplicate(true)
	var c_lat := float(cfg.center_lat)
	var c_lon := float(cfg.center_lon)
	cfg.center_lat = lat
	cfg.center_lon = lon
	cfg.erase("utc_offset_h")
	cfg.name = key
	for k: String in ["start_sites", "landing_sites"]:
		for s: Dictionary in cfg.get(k, []):
			if not s.has("lat"):
				continue
			var xz := TerrainGeo.latlon_to_local(float(s.lat), float(s.lon), c_lat, c_lon)
			var ll := TerrainGeo.local_to_latlon(xz.x, xz.y, lat, lon)
			s.lat = ll.x
			s.lon = ll.y
	_write_json(dst.path_join("location.json"), cfg)
	Locations.invalidate(key)


static func _write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "\t"))
	f.close()


func _one(main: Node, game: Game, place: String, cn: String, minutes: float) -> PackedStringArray:
	var c: Dictionary = CONDS[cn]
	var s := FlightSettings.defaults()
	if BUILTIN.has(place):
		s.location_id = BUILTIN[place][0]
		s.site_id = BUILTIN[place][1]
	else:
		s.location_id = "pt_fb1013_" + place
		s.site_id = VIRTUAL[place][1]
	s.month = int(c.month)
	s.day = int(c.day)
	s.start_hour = float(c.hour)
	s.sky = String(c.sky)
	s.temperature_c = roundf(WeatherModel.typical_max_c(s.month, s.day))
	s.wind_speed_kmh = WIND_KMH
	s.wind_into_launch = true
	await main.call("_fly", s)
	game.set_physics_process(false)
	var air: Atmosphere = game.air
	var st: Dictionary = game.get_start()
	var p0: Vector3 = st.position
	var hd := deg_to_rad(float(st.heading_deg))
	var fwd := Vector3(sin(hd), 0.0, -cos(hd))
	air.focus_node = null
	air.set_focus(p0)
	var clock: SunClock = game.sky.clock
	var ctx: Dictionary = game._weather_context()
	var wd: Dictionary = air.weather.get("_derived", {})
	var path := "поле" if air.is_air_field_on() else "аналитика"
	var psi := clock.angles().y
	# вход поля на CPU (как AirRuntime: место, условия, k = 1)
	var fin := _field_inputs(game, p0)
	# часы атмосферы: t0 — сейчас; 10 мин шагом 5 с — рождения, w термиков, w у земли
	var t0 := air.time_s
	var alive_t0 := 0
	for th: AtmoThermal in air.field.thermals.values():
		if not th.is_static and _near(th.src, p0, 2000.0):
			alive_t0 += 1
	var born := {}
	var thw := []
	var bub := []
	var betw := []
	var g := {"tot": [], "mean": [], "therm": [], "sink": [], "turb": [], "mn": []}
	var n_steps := int(minutes * 60.0 / 5.0)
	for i in n_steps:
		air.step(5.0)
		for th: AtmoThermal in air.field.thermals.values():
			if th.is_static or th.t_birth < t0 or not _near(th.src, p0, 2000.0):
				continue
			born[th.id] = true
		if i % 4 == 0:
			_sample_thermal_w(air, p0, thw, bub, betw)
			_sample_ground(air, p0, fwd, g)
	# w над «городом»: 30/60/100 м над землёй, центр и 4 точки в 200 м, 3 мин шагом 2 с
	var city := []
	var city_th := []
	var city_calm := []
	var city_sig := []
	var city_lee := []
	var cp: Vector3 = fin.city
	if is_finite(cp.x):
		for i in 90:
			air.step(2.0)
			for o: Vector2 in [Vector2.ZERO, Vector2(200, 0), Vector2(-200, 0), Vector2(0, 200), Vector2(0, -200)]:
				var gx := cp.x + o.x
				var gz := cp.z + o.y
				var gh := float(air.ground.sample(gx, gz).x)
				for agl: float in [30.0, 60.0, 100.0]:
					var p := Vector3(gx, gh + agl, gz)
					city.append(air.air_velocity_at(p).y)
					city_sig.append(air._last_sigma)
					# под линией тени гребня против ветра (подветренная зона аналитики)
					var gsp := air.ground.sample(gx, gz)
					city_lee.append(1.0 if float(gsp.w) - p.y > -air._lee_shear else 0.0)
					air.turbulence_enabled = false
					city_calm.append(air.air_velocity_at(p).y)
					air.turbulence_enabled = true
					city_th.append(air.field.sample(p).x)
	var wm := air.mean_wind_at(p0 + Vector3.UP * SOCK_AGL)
	var ratio := Vector2(wm.x, wm.z).length() / (WIND_KMH / 3.6)
	var thw_st := _stats(thw)
	var row := PackedStringArray([
		place, cn, "%.2f" % float(ctx.lat), "%.2f" % float(ctx.lon), "%.0f" % float(ctx.utc_offset_h),
		path, "%.1f" % psi, "%.2f" % float(wd.get("sunset_h", NAN)), "%.3f" % float(wd.get("heat", NAN)),
		"%.3f" % float(air.weather.get("thermal_duty", NAN)),
		"%.2f" % float(air.weather.thermal_strength_ms[1]),
		"%.0f" % fin.z_i_agl, "%.1f" % fin.h_mean, "%.1f" % fin.h_max, "%.1f" % fin.h_dom_max,
		"%.1f" % fin.h_land_max, fin.h_land_name, "%.1f" % fin.h_built, "%.1f" % fin.h_water, "%.2f" % fin.wstar,
		str(born.size()), str(alive_t0),
		"%.2f" % thw_st.max, "%.3f" % thw_st.mean, "%.3f" % thw_st.pos,
		"%.2f" % _stats(bub).max, "%.2f" % _stats(betw).max, "%.3f" % _stats(betw).mean,
		"%.2f" % _stats(g.tot).max, "%.2f" % _stats(g.tot).mean, "%.2f" % _stats(g.mean).mean,
		"%.2f" % _stats(g.therm).mean, "%.2f" % _stats(g.sink).mean, "%.2f" % _stats(g.turb).max,
		"%.2f" % _stats(g.turb).sd, "%.2f" % _stats(g.mn).max, "%.2f" % ratio,
		"%.2f" % float(fin.city_frac), "%.1f" % float(fin.city_h), "%.2f" % _stats(city).max,
		"%.2f" % _stats(city).mean, "%.2f" % _stats(city_calm).max, "%.2f" % _stats(city_th).max,
		"%.2f" % _stats(city_sig).mean, "%.2f" % _stats(city_lee).mean,
	])
	return row


static func _near(a: Vector3, b: Vector3, r: float) -> bool:
	return Vector2(a.x - b.x, a.z - b.z).length() <= r


## Термическая составляющая w (ThermalField.sample: пузыри + «между» поля) на 20–300 м над землёй
## в круге 2 км от старта; отдельно — только пузыри (без источников поля в выборке) и «между»
## (w_conv поля без ожидаемого потока пузырей).
static func _sample_thermal_w(
	air: Atmosphere, p0: Vector3, out: Array, bub: Array, betw: Array
) -> void:
	var src := air.field.air_src
	for r: float in [0.0, 500.0, 1000.0, 1500.0, 2000.0]:
		var nb := 1 if r == 0.0 else 8
		for b in nb:
			var a := TAU * b / nb
			var x := p0.x + r * sin(a)
			var z := p0.z - r * cos(a)
			var h := float(air.ground.sample(x, z).x)
			for agl: float in [20.0, 50.0, 100.0, 200.0, 300.0]:
				var p := Vector3(x, h + agl, z)
				var all := air.field.sample(p).x
				air.field.air_src = null
				var only_b := air.field.sample(p).x
				air.field.air_src = src
				out.append(all)
				bub.append(only_b)
				betw.append(all - only_b)


## w у земли перед стартом (0, 50, 100, 200 м вперёд по курсу, 5/15/30 м над землёй) по
## составляющим: среднее (поле/склон), термики (с гашением у земли), фоновое опускание, болтанка.
static func _sample_ground(air: Atmosphere, p0: Vector3, fwd: Vector3, g: Dictionary) -> void:
	for d: float in [0.0, 50.0, 100.0, 200.0]:
		var q := p0 + fwd * d
		var gs := air.ground.sample(q.x, q.z)
		for agl: float in [5.0, 15.0, 30.0]:
			var p := Vector3(q.x, float(gs.x) + agl, q.z)
			var tot := air.air_velocity_at(p).y
			air.turbulence_enabled = false
			var calm := air.air_velocity_at(p).y
			air.turbulence_enabled = true
			var th := air.field.sample(p)
			var fade := minf(agl / air._ground_fade, 1.0)
			var therm := fade * th.x
			var sink := fade * air._bg_sink * (1.0 - th.y)
			g.tot.append(tot)
			g.therm.append(therm)
			g.sink.append(sink)
			g.mean.append(calm - therm - sink)
			g.mn.append(calm - therm - sink)
			g.turb.append(tot - calm)


static func _stats(a: Array) -> Dictionary:
	if a.is_empty():
		return {"max": NAN, "mean": NAN, "pos": NAN, "sd": NAN}
	var mx := -INF
	var sm := 0.0
	var pos := 0
	for v: float in a:
		mx = maxf(mx, v)
		sm += v
		if v > 0.05:
			pos += 1
	var mean := sm / a.size()
	var v2 := 0.0
	for v: float in a:
		v2 += (v - mean) * (v - mean)
	return {"max": mx, "mean": mean, "pos": float(pos) / a.size(), "sd": sqrt(v2 / a.size())}


## Вход поля на CPU (AirPlace.domain_case, как AirRuntime._domain, k = 1): H в круге 2 км от старта
## (среднее, макс.), макс. по области, наибольший H чистого класса (горизонталь, солнце класса,
## облачность дня), z_i над долиной, w* Дирдорфа по среднему H.
static func _field_inputs(game: Game, p0: Vector3) -> Dictionary:
	var rt: AirRuntime = game.air_runtime
	var place: Dictionary = rt._place
	var cond: Dictionary = rt.conditions_fn.call()
	var out := {
		"city": Vector3(NAN, NAN, NAN), "city_frac": NAN, "city_h": NAN,
		"z_i_agl": NAN, "h_mean": NAN, "h_max": NAN, "h_dom_max": NAN, "h_land_max": NAN,
		"h_land_name": "", "h_water": NAN, "h_built": NAN, "wstar": NAN,
	}
	if place.get("detail") == null:
		return out
	var c: AirCase = AirRuntime._domain(place, cond, 1.0, AirRuntime.DX)
	if c == null:
		return out
	var ctx := AirPlace.context(place.detail, place.loc, WeatherModel.config())
	out.z_i_agl = c.z_i - float(ctx.valley_msl_m)
	var sm := 0.0
	var n := 0
	var mx := -INF
	var dmx := -INF
	var hc_sum := 0.0
	for j in c.ny:
		for i in c.nx:
			var q := j * c.nx + i
			var v := c.heat[q] if q < c.heat.size() else 0.0
			dmx = maxf(dmx, v)
			var x := c.x0 + (i + 0.5) * c.dx
			var z := -(c.y0 + (j + 0.5) * c.dx)
			if Vector2(x - p0.x, z - p0.z).length() <= 2000.0:
				sm += v
				hc_sum += c.hc[q]
				n += 1
				mx = maxf(mx, v)
	if n > 0:
		out.h_mean = sm / n
		out.h_max = mx
		out.wstar = WindField.deardorff_wstar(sm / n, c.z_i, hc_sum / n)
	out.h_dom_max = dmx
	# клетка с наибольшей долей застройки в 15 км от старта — «город»
	var cells := AirPlace.cell_surface(
		place.get("surface"), place.get("water"), place.detail, c.x0, c.y0, c.dx, c.nx, c.ny
	)
	if not cells.is_empty():
		var nc := SurfaceLayer.CLASS_COUNT
		var best := 0.0
		for j in c.ny:
			for i in c.nx:
				var q := j * c.nx + i
				var x := c.x0 + (i + 0.5) * c.dx
				var z := -(c.y0 + (j + 0.5) * c.dx)
				var fb: float = cells.fr[q * nc + SurfaceLayer.BUILT]
				if fb > best and Vector2(x - p0.x, z - p0.z).length() <= 15000.0:
					best = fb
					out.city = Vector3(x, 0.0, z)
					out.city_frac = fb
					out.city_h = c.heat[q] if q < c.heat.size() else NAN
	var cls := _class_flux(ctx, cond)
	out.h_land_max = cls.h
	out.h_land_name = cls.name
	out.h_water = cls.water
	out.h_built = cls.built
	return out


## Наибольший H чистого класса суши (горизонталь, влажность m_norm) и H воды (water_flux) в час условий.
static func _class_flux(ctx: Dictionary, cond: Dictionary) -> Dictionary:
	var scfg := SurfaceHeat.config()
	var wcfg := WeatherModel.config()
	var hour := float(cond.hour)
	var heating := SurfaceHeating.new()
	heating.setup(float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day), float(ctx.utc_offset_h), wcfg)
	var sun := heating.directions(hour)
	if sun.is_empty():
		sun.resize(SurfaceLayer.CLASS_COUNT)
		sun.fill(heating.sun_at(hour))
	var skyp := WeatherModel.sky_params(String(cond.sky), wcfg)
	var sky := {
		cover = float(skyp.get("cover", 0.0)), sky_heat = float(skyp.get("heat", 1.0)),
		night = heating.call("built_night", hour) if heating.has_method("built_night") else {},
	}
	var m := float(scfg.get("moisture", {}).get("m_norm", 0.47))
	var t_max := float(cond.get("t_max", NAN))
	if is_nan(t_max):
		t_max = WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), wcfg)
	var zv := float(ctx.valley_msl_m)
	var wtr := {
		t_water_c = SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), zv, ctx, scfg.water),
		t_air_c = SurfaceHeat.air_temp_c(hour, t_max, zv, ctx, scfg.water),
		u_ms = float(cond.u10),
		z_m = zv,
	}
	var best := -INF
	var name := ""
	var water := NAN
	var built := NAN
	for k in SurfaceLayer.CLASS_COUNT:
		var fr := PackedFloat32Array()
		fr.resize(SurfaceLayer.CLASS_COUNT)
		fr[k] = 1.0
		var h := SurfaceHeat.mix_flux(fr, 0, Vector3.UP, sun, m, sky, wtr, scfg)
		if k == SurfaceLayer.WATER:
			water = h
			continue
		if k == SurfaceLayer.BUILT:
			built = h
			continue
		if h > best:
			best = h
			name = SurfaceLayer.CLASS_NAMES[k]
	return {"h": best, "name": name, "water": water, "built": built}
