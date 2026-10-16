extends TestCase
## Контракт TI-К3 (docs/contracts/training-island.md): запечённое поле ветра — заголовок, круговой проход
## save → load на синтетическом наборе из трёх уровней (float16, ошибка ≤ 0,01 м/с при |u| ≤ 12 м/с),
## отказ при несовпадении key, model_hash — только предупреждение, разбор набора погоды TI-К2.

const DIR := "user://ti4_test"
const TOL_MS := 0.01
const LEVELS := [[100.0, 12, 10], [50.0, 10, 9], [400.0, 8, 8]]
const NZ := 6


## Синтетический уровень: ветер до ±12 м/с (гладкий + «шум» младших разрядов), w_conv, θ′, поток тепла.
static func _level(dx: float, nx: int, ny: int, seed_v: int) -> WindField:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var n := nx * ny * NZ
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	for a: PackedFloat32Array in [u, v, wm, wc, th]:
		a.resize(n)
	for k in NZ:
		for j in ny:
			for i in nx:
				var c := (k * ny + j) * nx + i
				u[c] = 8.5 * sin(0.3 * i + 0.2 * k) + 3.4 * cos(0.5 * j) + rng.randf_range(-0.01, 0.01)
				v[c] = -6.0 * cos(0.25 * j - 0.1 * k) + rng.randf_range(-0.01, 0.01)
				wm[c] = 2.5 * sin(0.4 * i + 0.3 * j) + rng.randf_range(-0.01, 0.01)
				wc[c] = 3.0 * maxf(0.0, sin(0.7 * i - 0.2 * j)) * float(k) / NZ
				th[c] = 0.8 * cos(0.2 * i + 0.1 * k) + rng.randf_range(-0.001, 0.001)
	u[0] = 12.0
	v[1] = -12.0
	var hc := PackedFloat32Array()
	hc.resize(nx * ny)
	var heat := PackedFloat32Array()
	heat.resize(nx * ny)
	for q in nx * ny:
		hc[q] = 1000.0 + 3.0 * (q % nx)
		heat[q] = 150.0 + 2.0 * (q / nx)
	var gam := PackedFloat32Array()
	gam.resize(NZ)
	gam.fill(0.004)
	var m := {
		dx = dx, dz = 50.0, x0 = -0.5 * nx * dx, y0 = -0.5 * ny * dx, z_bot = 900.0,
		nx = nx, ny = ny, nz = NZ, z0 = 0.1, z_i = 1800.0, u10 = 3.0, inflow_k = 0.85,
		heat = heat, gam = gam, label = "synthetic", source = "gpu", cond = {wind = 3.0, wdir = 150.0},
	}
	return WindField.from_arrays(m, u, v, wm, wc, th, hc)


static func synthetic_set() -> AirFieldSet:
	var lv: Array[WindField] = []
	for q in LEVELS.size():
		lv.append(_level(LEVELS[q][0], LEVELS[q][1], LEVELS[q][2], 11 + q))
	var fs := AirFieldSet.new()
	fs.set_field(lv, 0.0)
	return fs


static func weather() -> Dictionary:
	return {
		"wind_from_deg": 270, "wind_speed_ms": 6.0, "start_hour": 13.0, "month": 7, "day": 15,
		"sky": "partly", "temperature_c": 24.0,
	}


static func key() -> Dictionary:
	return AirBakedField.make_key(
		"training_island", 43.2, 34.0, "north_ridge", weather(), Vector3(120.004, 90.0, -310.5),
		"0123456789abcdef", [100.0, 50.0]
	)


static func _header() -> Dictionary:
	return {
		"location": "training_island", "site": "north_ridge", "key": key(),
		"model_hash": AirBakedField.model_hash(),
	}


func _max_err(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for q in a.size():
		e = maxf(e, absf(a[q] - b[q]))
	return e


func test_k3_roundtrip() -> void:
	var src := synthetic_set()
	var path := DIR.path_join("rt.json")
	check(AirBakedField.save(src, _header(), path), "save")
	check(FileAccess.file_exists(DIR.path_join("rt.bin")), "рядом .bin")
	check(not FileAccess.file_exists(DIR.path_join("rt.bin.tmp")), "временных файлов не осталось")
	var h := AirBakedField.read_header(path)
	check(h.get("format") == "dp-air-baked" and int(h.get("version")) == 1, "format/version")
	check(h.get("compression") == "zstd" and int(h.get("raw_bytes", 0)) > 0, "compression/raw_bytes")
	check(h.get("location") == "training_island" and h.get("site") == "north_ridge", "location/site")
	check(h.get("model_hash") is String and (h.model_hash as String).length() == 16, "model_hash 16 символов")
	var lv: Array = h.get("levels", [])
	check(lv.size() == 3, "три уровня в заголовке")
	for q in lv.size():
		var e: Dictionary = lv[q]
		check(e.has("name") and e.has("grid") and e.has("meta") and e.has("arrays"), "поля уровня %d" % q)
		for nm in ["u", "v", "w_mech", "w_conv", "theta", "hc", "heat"]:
			check((e.arrays as Dictionary).has(nm), "массив %s уровня %d" % [nm, q])
		for nm in ["u", "v", "w_mech", "w_conv", "theta"]:
			check(e.arrays[nm][2] == "f16", "%s — float16" % nm)
		for nm in ["hc", "heat"]:
			check(e.arrays[nm][2] == "f32", "%s — float32" % nm)
	var got := AirBakedField.load_file(path, key())
	check(got != null and got.levels.size() == 3, "load с тем же key")
	if got == null or got.levels.size() != 3:
		return
	for q in 3:
		var a: WindField = src.levels[q]
		var b: WindField = got.levels[q]
		check(a.nx == b.nx and a.ny == b.ny and a.nz == b.nz and a.dx == b.dx, "сетка уровня %d" % q)
		check(a.x0 == b.x0 and a.y0 == b.y0 and a.z_bot == b.z_bot, "начало сетки уровня %d" % q)
		var eu := _max_err(a._wconv, b._wconv)
		for pair: Array in [[a._theta, b._theta]]:
			eu = maxf(eu, _max_err(pair[0], pair[1]))
		var ev := _max_err(a._vel, b._vel)
		check(ev <= TOL_MS, "u, v, w_mech: ошибка %.5f ≤ %.2f м/с (уровень %d)" % [ev, TOL_MS, q])
		check(eu <= TOL_MS, "w_conv, θ′: ошибка %.5f ≤ %.2f (уровень %d)" % [eu, TOL_MS, q])
		check(a._hc == b._hc, "рельеф сетки побитно (уровень %d)" % q)
		check(a.heat_flux() == b.heat_flux(), "поток тепла побитно (уровень %d)" % q)
		check(a.gam() == b.gam() and a.z_i() == b.z_i(), "gam и z_i (уровень %d)" % q)
		check(float(b.meta.get("inflow_k", 0.0)) == 0.85, "inflow_k в meta (уровень %d)" % q)
		check(b.meta.get("cond", {}).get("wdir") == 150.0, "cond в meta (уровень %d)" % q)
	# выборка поля даёт то же, что исходное
	var p := Vector3(10.0, 1100.0, -20.0)
	var sa := src.sample(p, 1000.0)
	var sb := got.sample(p, 1000.0)
	check(absf(sa.x - sb.x) < 0.02 and absf(sa.z - sb.z) < 0.02, "выборка поля совпала")


func test_k3_key_mismatch_refused() -> void:
	var path := DIR.path_join("km.json")
	check(AirBakedField.save(synthetic_set(), _header(), path), "save")
	# другой ветер в погоде, другой старт, другой хеш данных места, другая версия формата
	var variants: Array[Dictionary] = []
	var k1 := key()
	k1.weather.wind_speed_ms = 7.0
	variants.append(k1)
	var k2 := key()
	k2.start = [121.0, -310.5]
	variants.append(k2)
	var k3 := key()
	k3.data_hash = "fedcba9876543210"
	variants.append(k3)
	var k4 := key()
	k4.format = 2
	variants.append(k4)
	var k5 := key()
	k5.site = "south_ridge"
	variants.append(k5)
	for k in variants.size():
		var vk: Dictionary = variants[k]
		check(AirBakedField.key_diff(key(), vk) != "", "key_diff видит различие %d" % k)
		check(AirBakedField.load_file(path, vk) == null, "несовпадение key %d — отказ" % k)
	# без проверки key файл читается; JSON не теряет разряды: то же key после записи — равно
	check(AirBakedField.load_file(path) != null, "без key — читается")
	check(AirBakedField.key_diff(AirBakedField.read_header(path).key, key()) == "", "key после JSON равен")


func test_k3_model_hash_mismatch_refuses() -> void:
	var path := DIR.path_join("mh.json")
	var h := _header()
	h.model_hash = "0000000000000000"
	check(AirBakedField.save(synthetic_set(), h, path), "save")
	var rd := AirBakedField.read_header(path)
	check(not AirBakedField.model_hash_ok(rd), "model_hash_ok: устарело (для --check)")
	check(AirBakedField.load_file(path, key()) == null, "хеш модели не совпал — поле не берётся")
	check(AirBakedField.load_file(path) != null, "без key (без проверок) — читается")
	var now := AirBakedField.model_hash()
	check(now.length() == 16, "model_hash: 16 символов (исходники читаются)")
	check(AirBakedField.code_hash() == AirBakedField.code_hash_of_sources(), "код: из исходников")
	h.model_hash = now
	check(AirBakedField.save(synthetic_set(), h, path), "save с текущим хешем")
	check(AirBakedField.load_file(path, key()) != null, "хеш совпал — берётся")
	check(now == AirBakedField.model_hash(), "model_hash детерминирован")


func test_k3_weather_conditions() -> void:
	var w := weather()
	var c := AirBakedField.conditions_of(w)
	check(c.hour == 13.0 and c.u10 == 6.0 and c.wdir == 270.0 and c.t_max == 24.0 and c.sky == "partly", "условия по набору TI-К2")
	check(AirBakedField.conditions_diff(w, c, 7, 15) == "", "те же условия — различий нет")
	var c2 := c.duplicate()
	c2.u10 = 6.5
	check(AirBakedField.conditions_diff(w, c2, 7, 15) != "", "другой ветер — различие")
	check(AirBakedField.conditions_diff(w, c, 8, 15) != "", "другая дата — различие")
	var c3 := c.duplicate()
	c3.sky = "clear"
	check(AirBakedField.conditions_diff(w, c3, 7, 15) != "", "другое небо — различие")
	check(c.wind_ref == "start", "набор без wind_ref — start")
	var wi := w.duplicate()
	wi.wind_ref = "inflow"
	var ci := AirBakedField.conditions_of(wi)
	check(ci.wind_ref == "inflow", "conditions_of передаёт wind_ref (TI-9b)")
	check(AirBakedField.conditions_diff(wi, ci, 7, 15) == "", "inflow: те же условия")
	check(AirBakedField.conditions_diff(wi, c, 7, 15) != "", "wind_ref другой — различие")


func test_k3_float16_error_bound() -> void:
	# весь диапазон ветра до 12 м/с: ошибка float16 ≤ 0,01 м/с
	var a := PackedFloat32Array()
	a.resize(24001)
	for q in a.size():
		a[q] = -12.0 + 24.0 * q / 24000.0
	var back := AirBakedField._from_half(AirBakedField._to_half(a))
	check(back.size() == a.size(), "размер после float16")
	var e := _max_err(a, back)
	check(e <= TOL_MS, "float16: максимальная ошибка %.5f м/с" % e)
