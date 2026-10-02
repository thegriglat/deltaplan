extends TestCase
## Среднее поле воздуха на CPU (AM-05, docs/guide/air-model.md → «Поле на CPU»): WindField и
## AirFieldSet на аналитических массивах, без GPU. Выборка: постоянное поле → оно же, линейное →
## точно (трилинейно), у земли — лог-профиль к нулю на z0, край — плавный, NaN нет, contains,
## подмена полей — плавная и монотонная по времени, уровни вкладываются.

## Сетка: 12 × 10 столбцов по 100 м, 16 уровней по 50 м от z_bot = 900 м; запад x0 = −600,
## юг y0 = −500 (y — север, мир Z = −y).
const META := {
	"dx": 100.0,
	"dz": 50.0,
	"x0": -600.0,
	"y0": -500.0,
	"z_bot": 900.0,
	"nx": 12,
	"ny": 10,
	"nz": 16,
	"z0": 0.1
}


## Поле из функции fn(x, y, z) -> Vector4(u, v, w_mech, θ′) в центрах (w_conv = 0,5·w_mech);
## рельеф — hc_fn(x, y).
static func _field(fn: Callable, hc_fn: Callable, m: Dictionary = META) -> WindField:
	var nx := int(m.nx)
	var ny := int(m.ny)
	var nz := int(m.nz)
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	var hc := PackedFloat32Array()
	for k in nz:
		for j in ny:
			for i in nx:
				var x: float = m.x0 + (i + 0.5) * m.dx
				var y: float = m.y0 + (j + 0.5) * m.dx
				var z: float = m.z_bot + (k + 0.5) * m.dz
				var r: Vector4 = fn.call(x, y, z)
				u.append(r.x)
				v.append(r.y)
				wm.append(r.z)
				wc.append(0.5 * r.z)
				th.append(r.w)
	for j in ny:
		for i in nx:
			hc.append(hc_fn.call(m.x0 + (i + 0.5) * m.dx, m.y0 + (j + 0.5) * m.dx))
	return WindField.from_arrays(m, u, v, wm, wc, th, hc)


static func _flat(h: float) -> Callable:
	return func(_x: float, _y: float) -> float: return h


static func _const(c: Vector4) -> Callable:
	return func(_x: float, _y: float, _z: float) -> Vector4: return c


static func _linear(x: float, y: float, z: float) -> Vector4:
	return Vector4(
		1.0 + 0.002 * x - 0.001 * y + 0.003 * (z - 900.0),
		-0.5 + 0.0015 * x + 0.0005 * y - 0.001 * (z - 900.0),
		0.2 + 0.0004 * x + 0.0003 * y - 0.0002 * (z - 900.0),
		1.0 + 0.001 * x - 0.002 * (z - 900.0)
	)


## Мир (x — восток, z — юг) из координат решателя (x, y — север).
static func _p(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, z, -y)


func test_constant_field() -> void:
	var c := Vector4(3.0, -2.0, 0.7, 1.5)
	var f := _field(_const(c), _flat(900.0))
	check(f != null, "поле построено")
	var err := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for n in 500:
		# выше центра первой клетки (925 м) и ниже верха (1700 м)
		var p := _p(
			rng.randf_range(-700.0, 700.0),
			rng.randf_range(-600.0, 600.0),
			rng.randf_range(930.0, 1700.0)
		)
		var s := f.sample(p, 900.0)
		# мир: (u, w_mech, −v)
		err = maxf(err, (s - Vector3(c.x, c.z, -c.y)).length())
		err = maxf(err, absf(f.sample_theta(p, 900.0) - c.w))
		err = maxf(err, absf(f.sample_w_conv(p, 900.0) - 0.5 * c.z))
	check(err < 1.0e-6, "постоянное поле → оно же (ошибка %.8f)" % err)
	print("    wind_field: макс. ошибка %s" % err)


func test_linear_field_exact() -> void:
	var f := _field(_linear, _flat(900.0))
	var err := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for n in 1000:
		# внутри центров клеток: x −550..550, y −450..450, z 925..1675
		var x := rng.randf_range(-550.0, 550.0)
		var y := rng.randf_range(-450.0, 450.0)
		var z := rng.randf_range(925.0, 1675.0)
		var e := _linear(x, y, z)
		var s := f.sample(_p(x, y, z), 900.0)
		err = maxf(err, (s - Vector3(e.x, e.z, -e.y)).length())
		err = maxf(err, absf(f.sample_theta(_p(x, y, z), 900.0) - e.w))
	check(err < 1.0e-4, "линейное поле → точно трилинейно (ошибка %.8f)" % err)
	print("    wind_field: макс. ошибка %s" % err)


func test_log_profile_near_ground() -> void:
	# ровная земля 900 м: первая воздушная клетка — центр 925 м (25 м над землёй)
	var f := _field(_const(Vector4(5.0, 0.0, 0.4, 2.0)), _flat(900.0))
	var z0 := 0.1
	for agl in [0.05, 1.0, 5.0, 10.0, 20.0]:
		var s := f.sample(_p(0.0, 0.0, 900.0 + agl), 900.0)
		var e := 5.0 * maxf(log(agl / z0), 0.0) / log(25.0 / z0)
		approx(s.x, e, 1.0e-4, "лог-профиль u на %.2f м" % agl)
		approx(s.y, e * 0.4 / 5.0, 1.0e-5, "лог-профиль w_mech на %.2f м" % agl)
	# θ′ у земли — значение первой клетки
	approx(f.sample_theta(_p(0.0, 0.0, 905.0), 900.0), 2.0, 1.0e-6, "θ′ у земли")
	# непрерывно на центре первой клетки и монотонно вверх
	var prev := -1.0
	var mono := true
	for i in 300:
		var s := f.sample(_p(0.0, 0.0, 900.0 + i * 0.1), 900.0).x
		mono = mono and s >= prev - 1.0e-6
		prev = s
	check(mono, "профиль у земли монотонен")
	approx(
		f.sample(_p(0.0, 0.0, 924.999), 900.0).x, 5.0, 1.0e-3, "непрерывно у центра первой клетки"
	)
	# земля под точкой ниже рельефа сетки на 30 м: у настоящей земли — ноль, на 25 м над ней — полный
	approx(f.sample(_p(0.0, 0.0, 870.0), 870.0).x, 0.0, 1.0e-6, "на настоящей земле — 0")
	# 25 м над настоящей землёй: столбец читается на 895 + 30·exp(−25/100) (подсеточный сдвиг
	# гаснет на масштабе клетки)
	var a_g := 895.0 + 30.0 * exp(-0.25) - 900.0
	approx(
		f.sample(_p(0.0, 0.0, 895.0), 870.0).x,
		5.0 * log(a_g / z0) / log(25.0 / z0),
		1.0e-4,
		"25 м над настоящей землёй"
	)


func test_masked_columns_and_slope() -> void:
	# склон: рельеф растёт на восток 0,5 м/м; поле всюду 4 м/с — у земли не бывает «под землёй»
	var slope := func(x: float, _y: float) -> float: return 1000.0 + 0.5 * x
	var f := _field(_const(Vector4(4.0, 0.0, 0.0, 0.0)), slope)
	var bad := 0
	var nan := 0
	for i in 200:
		var x := -500.0 + i * 5.0
		var g := f.ground_height(x, 0.0)
		for agl in [0.0, 2.0, 10.0, 40.0, 120.0]:
			var s := f.sample(_p(x, 0.0, g + agl), g)
			if not s.is_finite():
				nan += 1
			if s.x < -1.0e-6 or s.x > 4.0 + 1.0e-5:
				bad += 1
	check(nan == 0, "без NaN на склоне (%d)" % nan)
	check(bad == 0, "на склоне 0 ≤ u ≤ поле (%d)" % bad)
	# на 120 м над землёй склона — полное значение
	approx(f.sample(_p(0.0, 0.0, 1120.0), 1000.0).x, 4.0, 1.0e-5, "над склоном — поле")


## Западная половина — NaN/∞, восточная — слишком большие значения.
static func _bad(x: float, _y: float, _z: float) -> Vector4:
	if x < 0.0:
		return Vector4(NAN, INF, -INF, NAN)
	return Vector4(100.0, 0.0, 30.0, 1.0)


func test_nan_and_limits() -> void:
	var f := _field(_bad, _flat(900.0))
	f.clamp_values(40.0, 10.0)
	var worst := 0.0
	var finite := true
	for i in 200:
		for zz in [890.0, 905.0, 1000.0, 1800.0, 2000.0]:
			var p := _p(-800.0 + i * 8.0, 37.0, zz)
			var s := f.sample(p)
			finite = finite and s.is_finite() and is_finite(f.sample_theta(p))
			finite = finite and is_finite(f.sample_w_conv(p))
			worst = maxf(worst, Vector2(s.x, s.z).length())
			worst = maxf(worst, absf(s.y) * 4.0)
	check(finite, "NaN/∞ во входе → конечные значения")
	check(worst <= 40.0 + 1.0e-4, "ограничители: |горизонталь| ≤ 40, |w| ≤ 10 (%.2f)" % worst)


func test_contains_and_edge() -> void:
	var f := _field(_const(Vector4(1.0, 0.0, 0.0, 0.0)), _flat(900.0))
	f.edge_cells = 3.0
	# область: x −600..600, y −500..500, z 900..1700
	check(f.contains(_p(0.0, 0.0, 1200.0)), "центр внутри")
	check(not f.contains(_p(650.0, 0.0, 1200.0)), "восточнее — снаружи")
	check(not f.contains(_p(0.0, -520.0, 1200.0)), "южнее — снаружи")
	check(not f.contains(_p(0.0, 0.0, 1750.0)), "выше верха — снаружи")
	check(f.contains(_p(599.0, 499.0, 1699.0)), "у угла — внутри")
	approx(f.edge_weight(_p(0.0, 0.0, 1200.0)), 1.0, 0.0, "вес внутри")
	approx(f.edge_weight(_p(700.0, 0.0, 1200.0)), 0.0, 0.0, "вес снаружи")
	# через край на восток: вес монотонно падает и без скачков (шаг 1 м)
	var prev := 1.0
	var jump := 0.0
	var mono := true
	for i in 500:
		var w := f.edge_weight(_p(200.0 + i, 0.0, 1200.0))
		mono = mono and w <= prev + 1.0e-9
		jump = maxf(jump, absf(w - prev))
		prev = w
	check(mono, "вес края монотонен")
	check(jump < 0.01, "край без скачков (макс. шаг веса %.4f на 1 м)" % jump)
	# под верхом — та же полоса в клетках dz (3 × 50 м)
	approx(f.edge_weight(_p(0.0, 0.0, 1550.0)), 1.0, 0.0, "вес ниже полосы верха")
	approx(f.edge_weight(_p(0.0, 0.0, 1625.0)), 0.5, 1.0e-6, "вес в середине полосы верха")


func test_set_combines_levels_and_analytic() -> void:
	var coarse_m := META.duplicate()
	coarse_m.dx = 400.0
	coarse_m.x0 = -2400.0
	coarse_m.y0 = -2000.0
	var coarse := _field(_const(Vector4(2.0, 0.0, 0.0, 0.0)), _flat(900.0), coarse_m)
	var fine := _field(_const(Vector4(6.0, 0.0, 0.0, 0.0)), _flat(900.0))
	var s := AirFieldSet.new()
	s.edge_cells = 2.0
	s.set_field([fine, coarse], 0.0)
	var pin := s.sample(_p(0.0, 0.0, 1200.0), 900.0)
	approx(pin.x, 6.0, 1.0e-5, "внутри мелкого — мелкий")
	approx(pin.w, 1.0, 0.0, "доля поля 1")
	var pmid := s.sample(_p(1200.0, 0.0, 1200.0), 900.0)
	approx(pmid.x, 2.0, 1.0e-5, "за мелким — грубый")
	var pout := s.sample(_p(5000.0, 0.0, 1200.0), 900.0)
	approx(pout.w, 0.0, 0.0, "за грубым — аналитика (доля 0)")
	# вдоль луча от центра: значение между 6 и 2, без скачков
	var jump := 0.0
	var prev := 6.0
	for i in 1500:
		var v := s.sample(_p(i * 1.0, 0.0, 1200.0), 900.0)
		jump = maxf(jump, absf(v.x - prev))
		prev = v.x
	check(jump < 0.05, "стык уровней без скачков (макс. %.4f м/с на 1 м)" % jump)
	check(
		s.contains(_p(1200.0, 0.0, 1200.0)) and not s.contains(_p(5000.0, 0.0, 1200.0)), "contains"
	)


func test_blend_monotonic() -> void:
	var a := _field(_const(Vector4(2.0, 0.0, 0.3, 0.0)), _flat(900.0))
	var b := _field(_const(Vector4(6.0, 0.0, -0.5, 0.0)), _flat(900.0))
	var s := AirFieldSet.new()
	var p := _p(0.0, 0.0, 1200.0)
	# из аналитики в поле: доля растёт монотонно 0 → 1 за 10 с
	s.set_field(a, 10.0)
	var prev := -1.0
	var mono := true
	for i in 101:
		var r := s.sample(p, 900.0)
		mono = mono and r.w >= prev
		prev = r.w
		s.advance(0.1)
	check(mono, "аналитика → поле: доля монотонна")
	approx(prev, 1.0, 1.0e-6, "аналитика → поле за blend_s")
	# поле a → поле b за 20 с: u монотонно 2 → 6, w_mech монотонно 0,3 → −0,5
	s.set_field(b, 20.0)
	approx(s.sample(p, 900.0).x, 2.0, 1.0e-6, "подмена начинается со старого")
	var pu := 2.0
	var pw := 0.3
	var mono_u := true
	var max_step := 0.0
	for i in 400:
		s.advance(0.05)
		var r := s.sample(p, 900.0)
		mono_u = mono_u and r.x >= pu - 1.0e-6 and r.y <= pw + 1.0e-6
		max_step = maxf(max_step, r.x - pu)
		pu = r.x
		pw = r.y
	check(mono_u, "подмена полей монотонна по времени")
	check(
		max_step < 4.0 * 0.05 / 20.0 * 1.6,
		"подмена плавная (макс. шаг %.4f м/с за 0,05 с)" % max_step
	)
	approx(pu, 6.0, 1.0e-6, "в конце — новое поле")
	check(s.blend_fraction() == 1.0, "подмена закончилась")
	# выключение — тоже плавно к аналитике
	s.set_field(null, 5.0)
	check(s.is_active(), "во время выключения поле ещё действует")
	s.advance(2.5)
	approx(s.sample(p, 900.0).w, 0.5, 1.0e-6, "на полпути выключения — доля 0,5")
	s.advance(2.6)
	check(not s.is_active(), "выключено")


func test_from_mac_centers() -> void:
	# MAC с ореолом: u на западных гранях = 2 + 0,01·i_грани, v = 1, w = 0,2, w без нагрева = 0,05
	var m := {
		"dx": 100.0, "dz": 50.0, "x0": 0.0, "y0": 0.0, "z_bot": 0.0, "nx": 4, "ny": 3, "nz": 5
	}
	var hx := 6
	var hy := 5
	var hz := 7
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var w := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var th := PackedFloat32Array()
	var cell := PackedFloat32Array()
	for k in hz:
		for j in hy:
			for i in hx:
				u.append(2.0 + 0.01 * i)
				v.append(1.0)
				w.append(0.2)
				wm.append(0.05)
				th.append(0.3)
				cell.append(0.0 if k == 0 else 1.0)
	var hc := PackedFloat32Array()
	hc.resize(12)
	hc.fill(0.0)
	var f := WindField.from_mac(m, u, v, w, wm, th, cell, hc)
	check(f != null, "from_mac построено")
	# центр клетки i = 1 (ореол i = 2): u = среднее граней 2 и 3 = 2,025
	var s := f.sample(_p(150.0, 150.0, 125.0), 0.0)
	approx(s.x, 2.025, 1.0e-6, "u в центре — среднее граней")
	approx(s.z, -1.0, 1.0e-6, "v → −Z")
	approx(s.y, 0.05, 1.0e-6, "w_mech — решение без нагрева")
	approx(f.sample_w_conv(_p(150.0, 150.0, 125.0), 0.0), 0.15, 1.0e-6, "w_conv = w − w_mech")
