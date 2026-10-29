extends Node
## RW-11b: эталон волны Онгудая на РАСТРЕ места (W5), а не на `terrain.height_at`.
## Эталоны W8 `ongudai_wave` сняты с рельефом за пределами растра (40 км), волна же смотрит на 3λ
## против ветра: у крейта за краем растра — высота края. Этот скрипт кладёт в GD ту же землю, что
## у крейта: билинейно по растру `places/ongudai`, вне растра — край (`ground_height`, W5), и
## снимает `WaveField.sample`/`crests` на точках случая `ongudai_wave` и над гребнями.
## Запуск (опорная ревизия c591b1026, headless, под замком cpu): положить файл и сцену с этим узлом
##   в копию, godot --headless --path <копия> res://gen.tscn -- --root=<репозиторий> --out=<файл.json>

var _w := 0
var _h := 0
var _ox := 0.0
var _oz := 0.0
var _sp := 25.0
var _hs := PackedFloat32Array()


func _ground(x: float, z: float) -> float:
	var fx := clampf((x - _ox) / _sp, 0.0, _w - 1.0)
	var fz := clampf((z - _oz) / _sp, 0.0, _h - 1.0)
	var i := mini(int(fx), _w - 2)
	var j := mini(int(fz), _h - 2)
	var tx := float(fx - i)
	var tz := float(fz - j)
	var k := j * _w + i
	var a := _hs[k] + (_hs[k + 1] - _hs[k]) * tx
	var b := _hs[k + _w] + (_hs[k + _w + 1] - _hs[k + _w]) * tx
	return a + (b - a) * tz


func _sun(_x: float, _z: float) -> float:
	return 1.0


func _ready() -> void:
	var rdir := ""
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--root="):
			rdir = a.substr(7)
		elif a.begins_with("--out="):
			out = a.substr(6)
	var ph: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(rdir + "/tests/fixtures/wind/places/ongudai.json")
	)
	_w = int(ph.grid.width)
	_h = int(ph.grid.height)
	_ox = float(ph.grid.origin_x)
	_oz = float(ph.grid.origin_z)
	_sp = float(ph.grid.spacing)
	var bin := FileAccess.get_file_as_bytes(rdir + "/tests/fixtures/wind/places/ongudai.bin")
	var n := _w * _h
	_hs.resize(n)
	for i in n:
		_hs[i] = float(ph.h_offset) + float(bin.decode_s16(2 * i)) * float(ph.h_scale)
	var case: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(rdir + "/tests/fixtures/wind/cases/ongudai_wave.json")
	)
	var w: Dictionary = Config.get_config("weather/wave").duplicate(true)
	w.erase("static_thermals")
	w.static_thermals = []
	w.wind_speed_kmh = 36.0
	w.wind_from_deg = 151.0
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = int(case.seed)
	a.configure(cfg, w)
	a.set_ground(_ground, _sun)
	a.set_wind(36.0, 151.0, float(case.extra.wind_ref_msl))
	a.step(0.01)
	var u: float = a.wind.speed_at(float(cfg.wave.wind_reference_agl_m))
	var pts: Array = []
	for p: Array in case.points:
		pts.append(p)
	var f: Array = case.focuses[0]
	var wc: Dictionary = cfg.wave
	var crests := a.wave.crests(
		Vector3(f[0], 0.0, f[2]), float(wc.lens_radius_m), float(wc.lens_min_eta_m),
		float(wc.lens_length_m[1]) * 0.9
	)
	var crest_out: Array = []
	for cr: Dictionary in crests:
		var p2: Vector2 = cr.pos
		crest_out.append([p2.x, p2.y, cr.eta, cr.crest])
		for dy in [500.0, 1100.0, 1800.0]:
			pts.append([p2.x, maxf(float(cr.crest), _ground(p2.x, p2.y)) + dy, p2.y])
	var samples: Array = []
	for p: Array in pts:
		var gh := _ground(p[0], p[2])
		var s: Vector2 = a.wave.sample(Vector3(p[0], p[1], p[2]), p[1] - gh, u)
		samples.append([p[0], p[1], p[2], s.x, s.y])
	var doc := {
		revision = _rev(),
		generator = "rust/dp-air/tests/data/RW-11b/gen_ongudai_wave.gd",
		note = "WaveField на растре places/ongudai (билинейно, вне растра — край), preset wave, 36 км/ч с 151°",
		u_ref = u,
		wave_enabled = a.wave.enabled,
		lambda = a.wave.wavelength(),
		dir = [a.wind.dir.x, a.wind.dir.z],
		focus = [f[0], f[2]],
		crests = crest_out,
		samples = samples,
	}
	var fa := FileAccess.open(out, FileAccess.WRITE)
	fa.store_string(JSON.stringify(doc))
	fa.close()
	a.free()
	get_tree().quit(0)


func _rev() -> String:
	var o: Array = []
	OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], o)
	return String(o[0]).strip_edges() if not o.is_empty() else "?"
