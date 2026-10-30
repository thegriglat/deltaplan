extends RefCounted
## Эталонный мир отпечатка (AtmoFingerprint) для тестов при поле «всегда» (W2 v5): те же правила,
## что AtmoFingerprint.make_world, но условия W5 целиком (speed, quantum_h), растр места шагом 25 м
## (крейт принимает поле только на 25 м) и кеш полей на файл профиля:
## поле считается один раз на сочетание (место, условия, сид), остальные миры берут его из кеша.
## scripts/atmosphere/atmo_fingerprint.gd (make_world там — шаг 50 м, условия без speed) не правится
## в RW-P7: границы задачи; исправление — за владельцем скриптов (отчёт RW-P7).

const PLACE_STEP_M := 25.0


## Место и дата мира по ключу — статические AtmoFingerprint._lat/_lon/_month/_day/_utc (нужны
## sun_at_hour и weather_ctx); мир не строится.
static func set_context(key: String) -> void:
	var fs: FlightSettings = WorldKey.parse(key).settings
	var ll := WorldKey.launch_latlon(fs)
	AtmoFingerprint._lat = ll.x
	AtmoFingerprint._lon = ll.y
	AtmoFingerprint._month = fs.month
	AtmoFingerprint._day = fs.day
	AtmoFingerprint._utc = roundf(ll.y / 15.0)
	AtmoFingerprint._sun_h = NAN


static func make_place(loc: Dictionary) -> AirPlaceData:
	var half := AtmoFingerprint.PLACE_HALF_M
	var n := int(2.0 * half / PLACE_STEP_M) + 1
	var sites := [{"id": "origin", "x": 0.0, "z": 0.0, "h_msl": AtmoFingerprint.height(0.0, 0.0)}]
	var c := AtmoFingerprint.CENTER
	return AirPlaceData.from_functions(
		AtmoFingerprint.height, AtmoFingerprint._surface_k, loc, c.x - half, c.z - half,
		PLACE_STEP_M, n, n, sites
	)


## Мир из ключа (WorldKey), готовый на t = 0 (READY); фокус — CENTER. Не в дереве — free().
static func make(key: String = AtmoFingerprint.DEFAULT_KEY) -> Atmosphere:
	set_context(key)
	var parsed := WorldKey.parse(key)
	var fs: FlightSettings = parsed.settings
	var forecast := fs.forecast()
	if fs.wind_into_launch:
		forecast.wind_from_deg = AtmoFingerprint.LAUNCH_HEADING
	var a := Atmosphere.new()
	a.visuals_enabled = false
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	cfg.thermal.generation_radius_m = AtmoFingerprint.GEN_RADIUS_M
	a.cfg_override = cfg
	a.air_cache_enabled = true
	var loc := {
		"id": "fingerprint", "center_lat": AtmoFingerprint._lat, "center_lon": AtmoFingerprint._lon,
		"utc_offset_h": AtmoFingerprint._utc, "month": AtmoFingerprint._month,
		"day": AtmoFingerprint._day,
	}
	a.configure(int(parsed.seed))
	a.set_conditions(
		{"forecast": forecast, "start_hour": fs.start_hour, "speed": 1.0, "quantum_h": 1.0}
	)
	a.load_place(make_place(loc))
	a.set_static_thermals(PackedFloat32Array([-4000.0, 3000.0, 2.5, 120.0]), 2)
	a.set_focuses(PackedVector3Array([AtmoFingerprint.CENTER]), PackedFloat32Array([1.0]))
	jump_to(a, 0.0)
	return a


## «Прыжок» в t (start_at) и ожидание READY по времени: AtmoFingerprint.wait_ready крутит pump без
## пауз (100000 оборотов за доли секунды) и не дожидается поля Пикара.
static func jump_to(a: Atmosphere, t: float, max_ms: int = 300000) -> void:
	a.start_at(t)
	var t0 := Time.get_ticks_msec()
	while not a.is_ready() and Time.get_ticks_msec() - t0 < max_ms:
		if int(a.status().state) == Atmosphere.STATE_FAILED:
			push_error("FingerprintWorld.jump_to: FAILED %s" % [a.status()])
			return
		a.pump(8000)
		OS.delay_usec(1000)
