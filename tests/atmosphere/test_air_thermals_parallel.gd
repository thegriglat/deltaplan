extends TestCase
## Источники термиков поля полосами (FL-15): AirThermals.build параллельно в WorkerThreadPool даёт
## бит-в-бит то же, что последовательный путь (bands = 1) — порядок источников, точки, силы, водосборы;
## в том числе вложенной группой из рабочего потока (как ThermalField.AirJob).

const T := preload("res://tests/atmosphere/test_air_thermals.gd")


## Точка источника — детерминированно по столбцу; каждый седьмой — «вода» (нет источника).
static func _pick(i: int, j: int) -> Vector2:
	if (i * 31 + j * 17) % 7 == 0:
		return AirThermals.NO_SOURCE
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(5, i, j))
	return Vector2(
		-T.N * T.DX * 0.5 + (i + rng.randf_range(0.1, 0.9)) * T.DX,
		-(-T.N * T.DX * 0.5 + (j + rng.randf_range(0.1, 0.9)) * T.DX)
	)


static func _height(x: float, z: float) -> float:
	return T.GROUND + 3.0 * sin(x * 0.01) * cos(z * 0.013)


static func _heat_var(x: float, z: float) -> float:
	return 120.0 + 200.0 * (0.5 + 0.5 * sin(x * 0.0021 + 0.7) * cos(z * 0.0017))


func _fields() -> Array:
	var out := []
	var fx := WindField.load_file(T.FIXTURE)
	check(fx != null, "фикстура читается")
	if fx != null:
		out.append([fx, T._cfg(float(fx.meta.z_lcl)), "Каянча"])
	var fs := T._flat(_heat_var, T._conv_line, 2200.0, 0.0058, Vector2(3.0, 1.0))
	var cfg := T._cfg(2900.0)
	cfg["pick_fn"] = _pick
	cfg["height_fn"] = _height
	out.append([fs, cfg, "синтетика с pick_fn"])
	return out


static func _build(f: WindField, cfg: Dictionary, bands: int) -> AirThermals:
	var s := AirThermals.new()
	s.bands = bands
	s.build(f, cfg)
	return s


## Все выходы build, кроме служебных кешей, — как значения (сравнение == бит-в-бит для float32).
static func _dump(s: AirThermals) -> Array:
	return [
		s.col, s.pos, s.w0, s.radius, s.wstar, s.top, s.drift, s.flux, s.carried, s.net, s.ring,
		s.area, s.depth, s.owner, s.phi, s.col_heat, s.col_w, s.col_f, s.phi_ref, s.lost_flux,
		s.total_flux, s.carried_flux, s.index, s.mask_bytes()
	]


func _same(a: AirThermals, b: AirThermals, what: String) -> void:
	var da := _dump(a)
	var db := _dump(b)
	var bad := []
	for k in da.size():
		if da[k] != db[k]:
			bad.append(k)
	check(bad.is_empty(), "%s: выходы совпадают бит-в-бит (расходятся № %s)" % [what, str(bad)])


func test_bands_bit_identical() -> void:
	for e: Array in _fields():
		var f: WindField = e[0]
		var cfg: Dictionary = e[1]
		var ref := _build(f, cfg, 1)
		check(ref.count() > 0, "%s: источники есть (%d)" % [e[2], ref.count()])
		for nb in [2, 7, 0, 1000]:
			_same(ref, _build(f, cfg, nb), "%s, полос %d" % [e[2], nb])
		print("    %s: источников %d" % [e[2], ref.count()])


func test_nested_from_worker() -> void:
	for e: Array in _fields():
		var f: WindField = e[0]
		var cfg: Dictionary = e[1]
		var ref := _build(f, cfg, 1)
		var s := AirThermals.new()
		var tid := WorkerThreadPool.add_task(func() -> void: s.build(f, cfg), false, "test FL-15")
		WorkerThreadPool.wait_for_task_completion(tid)
		_same(ref, s, "%s из рабочего потока" % e[2])
