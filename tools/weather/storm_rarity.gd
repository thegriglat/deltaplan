extends Node
## Как часто грозы (Cb) у старта: для сидов seed0..seed0+N−1 строит атмосферу локации (рельеф и
## источники термиков из карты, ход дня, погода из прогноза — как в игре, без планера и графики)
## и прыгает в t = 0, 900, …, 3600 с (Atmosphere.start_at — то же, что прогон от 0; облако Cb
## живёт дольше 20 мин — не пропустим). Печатает по каждой погоде: долю сидов с Cb ближе 15 км
## за первый час, Cb/час в 15 и 20 км, долю сидов с грозовым ветром у старта в t = 0 и за час,
## средний и наибольший ветер бури у старта. --seeds=0 — только таблица доли термиков в Cb по часам.
## Запуск:
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/weather/storm_rarity.tscn \
##     -- [--seeds=100] [--temps=26,30,34] [--skies=clear,partly] [--hours=13,17] [--loc=ongudai]
##        [--seed0=1]

const NEAR_M := 15000.0
const FAR_M := 20000.0
## Грозовой ветер у старта: горизонтальный поток бури больше этого, м/с.
const WIND_MS := 2.0


func _ready() -> void:
	var n := 100
	var temps: Array[float] = [26.0, 30.0, 34.0]
	var skies: Array[String] = ["clear", "partly"]
	var hours: Array[float] = [13.0, 17.0]
	var loc_id := "ongudai"
	var seed0 := 1
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() < 2:
			continue
		match kv[0]:
			"seeds":
				n = int(kv[1])
			"temps":
				temps.clear()
				for s in kv[1].split(","):
					temps.append(float(s))
			"skies":
				skies.clear()
				for s in kv[1].split(","):
					skies.append(s)
			"hours":
				hours.clear()
				for s in kv[1].split(","):
					hours.append(float(s))
			"loc":
				loc_id = kv[1]
			"seed0":
				seed0 = int(kv[1])
	var terrain := Terrain.new()
	terrain.location_id = ""
	if not terrain.load_location(loc_id):
		push_error("не загрузилась %s" % loc_id)
		get_tree().quit(1)
		return
	terrain.wait_relief()
	var sites := terrain.get_start_sites()
	var launch := Vector3(0, terrain.height_at(0, 0), 0)
	if not sites.is_empty():
		launch = sites[0].position
	print("старт %s: %s" % [loc_id, launch])
	if n <= 0:
		_grid(terrain)
		terrain.free()
		get_tree().quit(0)
		return
	for hour in hours:
		for t in temps:
			for sky in skies:
				_measure(terrain, launch, t, sky, hour, seed0, n)
	terrain.free()
	get_tree().quit(0)


## --seeds=0: только шанс Cb и запас (верх сухих − конденсация) по температуре и часу.
func _grid(terrain: Terrain) -> void:
	var ctx := _ctx(terrain, FlightSettings.new())
	for sky in ["clear", "partly"]:
		print(
			"%s: °C \\ ч   11     13     15     17     19   (доля термиков в Cb / запас, м)" % sky
		)
		for t in [20.0, 24.0, 26.0, 28.0, 30.0, 32.0, 34.0, 38.0]:
			var row := "  %+3.0f " % t
			for h in [11.0, 13.0, 15.0, 17.0, 19.0]:
				var f := {
					"temperature_c": t, "wind_speed_kmh": 10.8, "wind_from_deg": 270.0, "sky": sky
				}
				var w := WeatherModel.derive(f, ctx, {}, h)
				row += " %.4f/%4.0f" % [float(w.cb_thermal_chance), float(w._derived.margin_m)]
			print(row)


func _ctx(terrain: Terrain, fs: FlightSettings) -> Dictionary:
	var g: Dictionary = Config.get_config("atmosphere").ground
	var ctx := WeatherModel.ground_context(
		terrain.height_at,
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(WeatherModel.config().valley_percentile)
	)
	var utc := float(terrain.location.get("utc_offset_h", roundf(terrain.center_lon / 15.0)))
	ctx.merge(
		{
			"month": fs.month,
			"day": fs.day,
			"lat": terrain.center_lat,
			"lon": terrain.center_lon,
			"utc_offset_h": utc
		}
	)
	return ctx


func _measure(
	terrain: Terrain, launch: Vector3, temp: float, sky: String, hour: float, seed0: int, n: int
) -> void:
	var fs := FlightSettings.new()
	fs.temperature_c = temp
	fs.sky = sky
	fs.start_hour = hour
	var forecast := fs.forecast()
	var ctx := _ctx(terrain, fs)
	var utc := float(ctx.utc_offset_h)
	var spacing := float(WeatherModel.derive(forecast, ctx).thermal_spacing_m)
	var derive := func(h: float) -> Dictionary:
		var w := WeatherModel.derive(forecast, ctx, {}, h)
		w.thermal_spacing_m = spacing
		return w
	var w0: Dictionary = derive.call(hour)
	var w1: Dictionary = derive.call(hour + 1.0)
	var sun := AtmoDay.sun_direction.bind(
		terrain.center_lat, terrain.center_lon, fs.month, fs.day, utc
	)
	var t0 := Time.get_ticks_msec()
	var any_near := 0
	var cb_near := 0
	var cb_far := 0
	var wind0 := 0
	var wind_h := 0
	var wind_sum := 0.0
	var wind_max := 0.0
	for s in range(seed0, seed0 + n):
		var a := Atmosphere.new()
		a.visuals_enabled = false
		a.seed_value = s
		a.configure(Config.get_config("atmosphere"), w0)
		a.set_ground(terrain.height_at, terrain.thermal_source_strength_at)
		a.set_wind(fs.wind_speed_kmh, float(forecast.wind_from_deg), launch.y)
		var d := AtmoDay.new()
		d.start_hour = hour
		d.quantum_h = float(WeatherModel.config().diurnal.get("update_s", 60.0)) / 3600.0
		d.weather_fn = derive
		d.sun_fn = sun
		d.source_fn = func(x: float, z: float, _h: float) -> float:
			return terrain.thermal_source_strength_at(x, z)
		a.set_day(d)
		a.set_focus(launch)
		var near := {}
		var far := {}
		var stormy := false
		for k in 5:
			var t := k * 900.0
			# t = 0 — прыжок (тёплый старт), дальше — обновление (набор термиков — функция t).
			if k == 0:
				a.start_at(t)
			else:
				a.time_s = t
				a.refresh_now()
			for id in a.field.thermals:
				var th: AtmoThermal = a.field.thermals[id]
				if not th.is_cb or t < th.t_birth:
					continue
				var c := th.cloud_center(t)
				var r := Vector2(c.x - launch.x, c.y - launch.z).length()
				if r < NEAR_M:
					near[id] = true
				if r < FAR_M:
					far[id] = true
			var sw := a.storm.sample(launch + Vector3(0, 2, 0), 2.0, t)
			var h := Vector2(sw.x, sw.z).length()
			wind_max = maxf(wind_max, h)
			if h > WIND_MS:
				stormy = true
				if k == 0:
					wind0 += 1
					wind_sum += h
		a.free()
		any_near += 1 if not near.is_empty() else 0
		cb_near += near.size()
		cb_far += far.size()
		wind_h += 1 if stormy else 0
	print(
		(
			(
				"%+.0f°C %-6s %02.0f ч (Cb %.4f→%.4f, запас %4.0f м): Cb≤15км за час %3d/%d,"
				+ " Cb/ч ≤15км %.2f ≤20км %.2f; ветер у старта t=0 %3d/%d (ср. %.1f), за час %3d/%d,"
				+ " макс %.1f м/с  [%.0f с]"
			)
			% [
				temp,
				sky,
				hour,
				ThermalField.cb_thermal_chance(w0),
				ThermalField.cb_thermal_chance(w1),
				float(w0._derived.get("margin_m", NAN)),
				any_near,
				n,
				float(cb_near) / n,
				float(cb_far) / n,
				wind0,
				n,
				wind_sum / maxf(wind0, 1.0),
				wind_h,
				n,
				wind_max,
				(Time.get_ticks_msec() - t0) / 1000.0
			]
		)
	)
