extends Node
## Выход процесса во время фоновой сборки поля крейта (RW-28): мир отпечатка запущен, поле ещё не
## готово — через случайные 0..1,5 с после start_at вызывается get_tree().quit() без free() и без
## ожидания. Не должно быть SIGSEGV (код 139). Не игровой код.
##   godot --headless --path . res://tools/bench/quit_during_build.tscn -- [--delay-ms=<мс>]

const FingerprintWorld := preload("res://tests/atmosphere/fingerprint_world.gd")


func _ready() -> void:
	var delay_ms := randi_range(0, 1500)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--delay-ms="):
			delay_ms = int(a.substr(11))
	var key := AtmoFingerprint.DEFAULT_KEY
	FingerprintWorld.set_context(key)
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
	a.load_place(FingerprintWorld.make_place(loc))
	a.set_focuses(PackedVector3Array([AtmoFingerprint.CENTER]), PackedFloat32Array([1.0]))
	add_child(a)
	a.start_at(0.0)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < delay_ms:
		a.pump(8000)
		OS.delay_usec(1000)
	print("quit_during_build: quit через %d мс, состояние %s" % [delay_ms, a.status().state])
	get_tree().quit(0)
