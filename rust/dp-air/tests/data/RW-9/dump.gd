extends Node
## Дамп RW-9 (опорная ревизия GD-ветра c591b1026, W8): WindModel.gust_unit (шум пятен рывков и
## пульсаций аналитики) и GroundField на сетке Онгудая (terrain.height_at) для 4 направлений ветра.
## Запуск: rust/dp-air/tests/data/RW-9/dump.sh [--out=<каталог>]. Формат: f32 little-endian без
## заголовка; описание — manifest.json. Читает rust/dp-air/tests/terms_analytic.rs.

const GUST_SEEDS := [4242, 909]
const GUST_N := 1500
const WIND_FROM := [151.0, 250.0, 330.0, 60.0]
const GRID_N := 25
const GRID_STEP := 400.0

var _out := "res://rust/dp-air/tests/data/RW-9"
var _manifest := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	_manifest = {"format": "little-endian f32, no header", "godot": Engine.get_version_info().string}
	var cfg: Dictionary = Config.get_config("atmosphere")
	_gust(cfg)
	_ground(cfg)
	var f := FileAccess.open(_out.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_manifest, "\t", true) + "\n")
	f.close()
	get_tree().quit()


func _write(name: String, data: PackedFloat32Array) -> void:
	var f := FileAccess.open(_out.path_join(name), FileAccess.WRITE)
	f.store_buffer(data.to_byte_array())
	f.close()


## gust_unit: на сид — GUST_N проб (x, y, z, t, advect, large_k) -> (nx, ny, nz); ветер с 230° 3,89 м/с.
func _gust(cfg: Dictionary) -> void:
	_manifest["gust"] = {
		"seeds": GUST_SEEDS, "n": GUST_N, "wind_from_deg": 230.0, "speed_ms": 3.8888888888888888,
		"in": "gust_in.f32: n x [x, y, z, t, advect, large_k]", "out": "gust_<seed>.f32: n x [nx, ny, nz]",
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var ins := PackedFloat32Array()
	for i in GUST_N:
		ins.append(rng.randf_range(-5000, 5000))
		ins.append(rng.randf_range(0, 3000))
		ins.append(rng.randf_range(-5000, 5000))
		ins.append(rng.randf_range(0, 3600) if i % 3 != 0 else 0.0)
		ins.append(rng.randf_range(0, 12))
		ins.append([0.0, 0.5, 1.0, rng.randf()][i % 4])
	_write("gust_in.f32", ins)
	for s in GUST_SEEDS:
		var w := WindModel.new()
		w.setup(cfg.wind, cfg.turbulence, s)
		w.set_wind(3.8888888888888888, 230.0)
		var o := PackedFloat32Array()
		for i in GUST_N:
			var b := i * 6
			var n := w.gust_unit(
				Vector3(ins[b], ins[b + 1], ins[b + 2]), ins[b + 3], ins[b + 4], ins[b + 5]
			)
			o.append(n.x)
			o.append(n.y)
			o.append(n.z)
		_write("gust_%d.f32" % s, o)


## GroundField на сетке GRID_N x GRID_N шагом GRID_STEP вокруг старта Онгудая (сдвиг 13,7/-9,3 м):
## на направление — n x [h, dh/dx, dh/dz, тень, превышение гребня, terrain.height_at].
func _ground(cfg: Dictionary) -> void:
	Locations.fixtures_root = "res://tests/fixtures/locations"
	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location("ongudai"):
		push_error("RW-9 dump: Онгудай не загрузился")
		get_tree().quit(1)
		return
	terrain.wait_relief()
	var lc: Dictionary = Config.get_config("locations/ongudai")
	var site: Dictionary = lc.start_sites[0]
	var s2 := terrain.latlon_to_local(float(site.lat), float(site.lon))
	var pts := PackedFloat32Array()
	for j in GRID_N:
		for i in GRID_N:
			pts.append(s2.x + (i - GRID_N / 2) * GRID_STEP + 13.7)
			pts.append(s2.y + (j - GRID_N / 2) * GRID_STEP - 9.3)
	_write("ground_pts.f32", pts)
	_manifest["ground"] = {
		"wind_from_deg": WIND_FROM, "grid": GRID_N, "step_m": GRID_STEP, "start": [s2.x, s2.y],
		"in": "ground_pts.f32: n x [x, z]",
		"out": "ground_<from_deg>.f32: n x [h, dhdx, dhdz, shadow, relief, height_at]",
		"height_fn": "Terrain.height_at (слои terrain: детальные 10/25 м)",
	}
	for from_deg: float in WIND_FROM:
		var g := GroundField.new()
		g.setup(cfg.ground, cfg.lee)
		g.set_functions(terrain.height_at, terrain.thermal_source_strength_at)
		var d := deg_to_rad(from_deg)
		g.set_wind_dir(Vector2(-sin(d), cos(d)))
		var o := PackedFloat32Array()
		for k in pts.size() / 2:
			var x := pts[k * 2]
			var z := pts[k * 2 + 1]
			var s := g.sample(x, z)
			o.append(s.x)
			o.append(s.y)
			o.append(s.z)
			o.append(s.w)
			o.append(g.relief_at(x, z))
			o.append(terrain.height_at(x, z))
		_write("ground_%d.f32" % int(from_deg), o)
