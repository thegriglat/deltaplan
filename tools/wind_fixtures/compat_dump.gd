extends Node
## Дамп совместимости (RW-8c): FastNoiseLite, RandomNumberGenerator, hash() Godot -> бинарные файлы
## для теста rust/dp-air/tests/godot_compat.rs. Запуск: compat_dump.sh [--out=<каталог>] [--verify].
## Формат: f32/u32/i32 little-endian без заголовка; описание — manifest.json.

const NOISE_SEEDS := [0, 1, 20260927, 20260927 + 7919]
const RNG_SEEDS := [0, 1, 42, 7919, 20260927, 2147483647, 4294967295, 3405691582, -1]
const N_STREAM := 10000
const N_MIX := 3000
const N_HASH := 1000

var _out := "res://rust/dp-air/tests/data/godot_compat"
var _manifest := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	_manifest = {"format": "little-endian, f32 / u32 / i32, no header", "godot": Engine.get_version_info().string}
	_noise()
	_rng()
	_hash()
	var f := FileAccess.open(_out.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_manifest, "\t", true) + "\n")
	f.close()
	get_tree().quit()


func _write(name: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(_out.path_join(name), FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


func _noise() -> void:
	# Точки: сетка 16^3 шагом 0,37 со сдвигом, 8000 случайных в +-50, 4000 в +-600 (большие и отрицательные).
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var pts := PackedFloat32Array()
	for i in 16:
		for j in 16:
			for k in 16:
				pts.append(-2.9 + i * 0.37)
				pts.append(-3.1 + j * 0.37)
				pts.append(-2.7 + k * 0.37)
	for i in 8000:
		pts.append(rng.randf_range(-50, 50))
		pts.append(rng.randf_range(-50, 50))
		pts.append(rng.randf_range(-50, 50))
	for i in 4000:
		pts.append(rng.randf_range(-600, 600))
		pts.append(rng.randf_range(-600, 600))
		pts.append(rng.randf_range(-600, 600))
	_write("noise_pts.f32", pts.to_byte_array())
	var n := pts.size() / 3
	var kinds := {
		"none": {"fractal": FastNoiseLite.FRACTAL_NONE, "octaves": 5, "gain": 0.5, "lacunarity": 2.0, "weighted": 0.0, "frequency": 1.0},
		"fbm2": {"fractal": FastNoiseLite.FRACTAL_FBM, "octaves": 2, "gain": 0.5, "lacunarity": 2.0, "weighted": 0.0, "frequency": 1.0},
		"fbm4w": {"fractal": FastNoiseLite.FRACTAL_FBM, "octaves": 4, "gain": 0.6, "lacunarity": 1.9, "weighted": 0.5, "frequency": 0.7},
	}
	_manifest["noise"] = {"points": n, "points_file": "noise_pts.f32", "type": "TYPE_SIMPLEX_SMOOTH", "seeds": NOISE_SEEDS, "kinds": kinds, "files": "noise_<seed>_<kind>.f32"}
	for s in NOISE_SEEDS:
		for kn in kinds:
			var k: Dictionary = kinds[kn]
			var fn := FastNoiseLite.new()
			fn.seed = s
			fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			fn.fractal_type = k.fractal
			fn.fractal_octaves = k.octaves
			fn.fractal_gain = k.gain
			fn.fractal_lacunarity = k.lacunarity
			fn.fractal_weighted_strength = k.weighted
			fn.frequency = k.frequency
			var o := PackedFloat32Array()
			o.resize(n)
			for i in n:
				o[i] = fn.get_noise_3d(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2])
			_write("noise_%d_%s.f32" % [s, kn], o.to_byte_array())


func _rng() -> void:
	_manifest["rng"] = {
		"seeds": RNG_SEEDS, "n_stream": N_STREAM, "n_mix": N_MIX,
		"files": "rng_<seed>_randf.f32 (randf), _range.f32 (randf_range(-5000, 5000)), _randi.u32, _mix.f32 (по кругу: randf, randf_range(100, 200), randf_range(-1, 1)), _mixi.u32 (randi после каждой тройки)",
	}
	for s in RNG_SEEDS:
		var rng := RandomNumberGenerator.new()
		var tag := "rng_%d_" % s
		rng.seed = s
		var a := PackedFloat32Array()
		for i in N_STREAM:
			a.append(rng.randf())
		_write(tag + "randf.f32", a.to_byte_array())
		rng.seed = s
		a = PackedFloat32Array()
		for i in N_STREAM:
			a.append(rng.randf_range(-5000, 5000))
		_write(tag + "range.f32", a.to_byte_array())
		rng.seed = s
		var u := PackedByteArray()
		u.resize(N_STREAM * 4)
		for i in N_STREAM:
			u.encode_u32(i * 4, rng.randi())
		_write(tag + "randi.u32", u)
		rng.seed = s
		a = PackedFloat32Array()
		u = PackedByteArray()
		u.resize(N_MIX * 4)
		for i in N_MIX:
			a.append(rng.randf())
			a.append(rng.randf_range(100, 200))
			a.append(rng.randf_range(-1, 1))
			u.encode_u32(i * 4, rng.randi())
		_write(tag + "mix.f32", a.to_byte_array())
		_write(tag + "mixi.u32", u)


func _hash() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var p2 := PackedByteArray()
	var h2 := PackedByteArray()
	p2.resize(N_HASH * 8)
	h2.resize(N_HASH * 4)
	var p3 := PackedByteArray()
	var h3 := PackedByteArray()
	p3.resize(N_HASH * 12)
	h3.resize(N_HASH * 4)
	for i in N_HASH:
		var x := rng.randi_range(-100000, 100000) if i % 3 != 0 else (rng.randi() - 2147483648)
		var y := rng.randi_range(-1000, 1000) if i % 2 == 0 else (rng.randi() - 2147483648)
		var z := rng.randi_range(-50, 50) if i % 5 != 0 else (rng.randi() - 2147483648)
		if i == 0:
			x = 0
			y = 0
			z = 0
		p2.encode_s32(i * 8, x)
		p2.encode_s32(i * 8 + 4, y)
		h2.encode_u32(i * 4, hash(Vector2i(x, y)))
		p3.encode_s32(i * 12, x)
		p3.encode_s32(i * 12 + 4, y)
		p3.encode_s32(i * 12 + 8, z)
		h3.encode_u32(i * 4, hash(Vector3i(x, y, z)))
	_write("hash2_in.i32", p2)
	_write("hash2_out.u32", h2)
	_write("hash3_in.i32", p3)
	_write("hash3_out.u32", h3)
	_manifest["hash"] = {"n": N_HASH, "files": "hash2_in.i32 (x, y), hash2_out.u32, hash3_in.i32 (x, y, z), hash3_out.u32; hash(Vector2i/Vector3i)"}
