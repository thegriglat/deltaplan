extends TestCase
## CLF-К6 (docs/contracts/cloud-field.md): z_i по столбцам частично следует рельефу — один на модель
## воздуха (AirZiTerrain, AirCase.z_i_col, WindField.z_i_col/z_i_at, AirThermals, CloudField).
## α = 0 — столбцы ≡ z_i и числа AirThermals как до правки; α > 0 — z_i_col ≥ h + ZI_MIN, над гребнем
## выше, чем над долиной, не больше α·перепада; окно = регион в точке; под облаком потолок источника
## ≥ основания, без облака — au = 0.

const T_THERMALS := preload("res://tests/atmosphere/test_air_thermals.gd")
const N := 96
const DX := 400.0
const H_VALLEY := 800.0
const H_RIDGE := 1200.0  # перепад гребень − долина, м
const Z_I_REF := 2600.0
const ALPHA := 0.33
const SMOOTH_M := 5000.0


## Рельеф: долина 800 м, гребень вдоль y высотой +1200 м шириной σ = 6 км по x.
static func _ridge(nx: int, ny: int, dx: float) -> PackedFloat64Array:
	var hc := PackedFloat64Array()
	hc.resize(nx * ny)
	for j in ny:
		for i in nx:
			var x := (i + 0.5 - 0.5 * nx) * dx
			hc[j * nx + i] = H_VALLEY + H_RIDGE * exp(-pow(x / 6000.0, 2.0))
	return hc


static func _case(hc: PackedFloat64Array, z_i: float) -> AirCase:
	var c := AirCase.new()
	var dz := 105.0
	c.set_grid(DX, N, N, dz, 600.0, 40, -0.5 * N * DX, -0.5 * N * DX)
	c.hc = hc
	c.z_i = z_i
	c.gam.resize(c.nz + 2)
	for k in c.nz + 2:
		c.gam[k] = 0.0 if c.zc(k) < z_i else 0.005
	c.heat.resize(N * N)
	c.heat.fill(250.0)
	c.u10 = 3.0
	c.wdir = 270.0
	return c


func test_alpha_zero_identity() -> void:
	var hc := _ridge(N, N, DX)
	var zc := AirZiTerrain.columns(hc, N, N, DX, Z_I_REF, H_VALLEY, 0.0, SMOOTH_M)
	check(zc.size() == N * N, "α = 0: столбцы заполнены")
	var same := true
	for v in zc:
		same = same and v == Z_I_REF
	check(same, "α = 0: z_i_col ≡ z_i_ref побитно")
	check(AirZiTerrain.columns(hc, N, N, DX, NAN, H_VALLEY, ALPHA, SMOOTH_M).is_empty(), "z_i = NAN → пусто")
	# случай: с z_i_col при α = 0 — те же col/h_bl/w*, что без столбцов (как до правки)
	var a := _case(hc, Z_I_REF)
	check(a.prepare(), "случай без столбцов готов")
	var b := _case(hc, Z_I_REF)
	b.set_zi_terrain(H_VALLEY, {alpha = 0.0, smooth_m = SMOOTH_M})
	check(b.prepare(), "случай со столбцами готов")
	check(a.col == b.col and a.h_bl == b.h_bl and a._wst == b._wst, "α = 0: col, h_bl, w* побитно те же")
	var m := b.meta()
	check(m.has("z_i_col") and (m.z_i_col as PackedFloat32Array).size() == N * N, "meta.z_i_col")
	check(is_equal_approx(float(m.z_i), Z_I_REF), "meta.z_i — скаляр z_i_ref")


func test_alpha_follows_terrain() -> void:
	var hc := _ridge(N, N, DX)
	var zc := AirZiTerrain.columns(hc, N, N, DX, Z_I_REF, H_VALLEY, ALPHA, SMOOTH_M)
	var ok_floor := true
	var lo := INF
	var hi := -INF
	for c in N * N:
		ok_floor = ok_floor and zc[c] >= hc[c] + AirZiTerrain.ZI_MIN - 1.0e-3
		lo = minf(lo, zc[c])
		hi = maxf(hi, zc[c])
	check(ok_floor, "z_i_col ≥ h + ZI_MIN")
	var j := N / 2
	var z_valley := zc[j * N]
	var z_ridge := zc[j * N + N / 2]
	check(z_ridge > z_valley, "над гребнем выше, чем над долиной: %.0f > %.0f" % [z_ridge, z_valley])
	check(z_ridge - z_valley <= ALPHA * H_RIDGE + 1.0, "подъём не больше α·перепада (%.0f ≤ %.0f)" % [z_ridge - z_valley, ALPHA * H_RIDGE])
	check(z_ridge - z_valley > 0.25 * ALPHA * H_RIDGE, "сглаживание 5 км не стирает гребень σ 6 км (%.0f м)" % (z_ridge - z_valley))
	approx(z_valley, Z_I_REF + ALPHA * (_mean_hs_edge(hc) - H_VALLEY), 2.0, "у края долины — z_i_ref + α·(h̃ − h_ref)")
	# нижняя граница: низкий z_i дня — над гребнем не ниже рельефа + 300 м
	var low := AirZiTerrain.columns(hc, N, N, DX, H_VALLEY + 400.0, H_VALLEY, ALPHA, SMOOTH_M)
	var ok := true
	for c in N * N:
		ok = ok and low[c] >= hc[c] + AirZiTerrain.ZI_MIN - 1.0e-3
	check(ok, "низкий z_i: граница h + ZI_MIN держится над гребнем")
	# те же столбцы в случае, w* выше над гребнем (слой толще)
	var cs := _case(hc, Z_I_REF)
	cs.set_zi_terrain(H_VALLEY, {alpha = ALPHA, smooth_m = SMOOTH_M})
	check(cs.z_i_col == zc, "AirCase.set_zi_terrain — те же столбцы")
	check(cs.prepare(), "случай готов")
	var hb_r: float = cs.h_bl[j * N + N / 2]
	var hb_v: float = cs.h_bl[j * N]
	check(hb_r > 0.0 and hb_v > 0.0, "h_bl есть")


## h̃ на краю по x (столбец 0) для гребня: гаусс по x с отражением — считаем тем же gauss2d.
static func _mean_hs_edge(hc: PackedFloat64Array) -> float:
	var hs := AirCase.gauss2d(hc, N, N, SMOOTH_M / DX)
	return hs[(N / 2) * N]


## Поле региона из meta с z_i_col → окно внутри: в центрах клеток региона значения совпадают.
func test_window_equals_region() -> void:
	var hc := _ridge(N, N, DX)
	var zc := AirZiTerrain.columns(hc, N, N, DX, Z_I_REF, H_VALLEY, ALPHA, SMOOTH_M)
	var f := _field(hc, zc, ALPHA)
	check(f != null, "поле региона")
	check(f.z_i_col().size() == N * N and f.zi_alpha() == ALPHA, "WindField.z_i_col, zi_alpha")
	# точка в центре столбца (i, j) региона
	var i := N / 2 + 3
	var j := N / 2 - 2
	var x := f.x0 + (i + 0.5) * DX
	var y := f.y0 + (j + 0.5) * DX
	approx(f.z_i_at(Vector3(x, 0.0, -y)), zc[j * N + i], 1.0e-3, "z_i_at в центре столбца = z_i_col")
	var mid := f.z_i_at(Vector3(x + 0.5 * DX, 0.0, -y))
	check(
		mid >= minf(zc[j * N + i], zc[j * N + i + 1]) - 1.0e-3 and mid <= maxf(zc[j * N + i], zc[j * N + i + 1]) + 1.0e-3,
		"между столбцами — между значениями"
	)
	# окно 16 × 16 по 100 м с углом в центре столбца региона: столбцы окна внутри клетки региона
	var wn := 16
	var wdx := 100.0
	var wx0 := x - 0.5 * wdx * wn
	var wy0 := y - 0.5 * wdx * wn
	var whc := PackedFloat64Array()
	whc.resize(wn * wn)
	whc.fill(H_VALLEY)  # низкий рельеф окна — нижняя граница не срабатывает
	var wz := AirZiTerrain.from_parent(f, whc, wn, wn, wdx, wx0, wy0)
	check(wz.size() == wn * wn, "окно: столбцы заполнены")
	var err := 0.0
	for jj in wn:
		for ii in wn:
			var px := wx0 + (ii + 0.5) * wdx
			var py := wy0 + (jj + 0.5) * wdx
			err = maxf(err, absf(wz[jj * wn + ii] - f.z_i_at(Vector3(px, 0.0, -py))))
	check(err < 1.0e-3, "окно = регион в точке (max|Δ| %.4f м)" % err)
	# окно с высоким рельефом — нижняя граница по своему рельефу
	whc.fill(Z_I_REF + 1000.0)
	var wz2 := AirZiTerrain.from_parent(f, whc, wn, wn, wdx, wx0, wy0)
	var ok := true
	for v in wz2:
		ok = ok and v >= Z_I_REF + 1000.0 + AirZiTerrain.ZI_MIN - 1.0e-3
	check(ok, "окно: z_i ≥ свой рельеф + ZI_MIN")
	# поле без столбцов — скаляр; без z_i — NAN
	var f0 := _field(hc, PackedFloat32Array(), 0.0)
	check(f0.z_i_col().is_empty() and f0.z_i_at(Vector3(x, 0.0, -y)) == Z_I_REF, "нет столбцов — z_i_at = z_i")
	f0.meta.erase("z_i")
	check(is_nan(f0.z_i_at(Vector3(x, 0.0, -y))), "нет z_i — NAN")


## Поле nz = 4 с рельефом hc, meta.z_i/z_i_col (ветер и прочее — нули).
static func _field(hc: PackedFloat64Array, zc: PackedFloat32Array, alpha: float) -> WindField:
	var nz := 4
	var m := {
		dx = DX, dz = 500.0, x0 = -0.5 * N * DX, y0 = -0.5 * N * DX, z_bot = 500.0,
		nx = N, ny = N, nz = nz, z0 = 0.1, z_i = Z_I_REF,
	}
	if not zc.is_empty():
		m.z_i_col = zc
		m.zi_alpha = alpha
	var n := N * N * nz
	var z := PackedFloat32Array()
	z.resize(n)
	return WindField.from_arrays(m, z, z.duplicate(), z.duplicate(), z.duplicate(), z.duplicate(), AirCase.to_f32(hc))


## AirThermals: поле с meta.z_i_col ≡ z_i даёт те же числа, что поле без столбцов.
func test_thermals_alpha_zero_same() -> void:
	var fa: WindField = T_THERMALS._flat(T_THERMALS._sun_half, T_THERMALS._conv_line)
	var fb: WindField = T_THERMALS._flat(T_THERMALS._sun_half, T_THERMALS._conv_line)
	var zc := PackedFloat32Array()
	zc.resize(fb.nx * fb.ny)
	zc.fill(fb.z_i())
	fb.meta.z_i_col = zc
	fb.meta.zi_alpha = 0.0
	var cfg: Dictionary = T_THERMALS._cfg()
	var a := AirThermals.new()
	var b := AirThermals.new()
	check(a.build(fa, cfg) and b.build(fb, cfg), "источники строятся")
	check(a.count() > 0 and a.count() == b.count(), "то же число источников: %d" % a.count())
	check(a.phi == b.phi and a.c_top == b.c_top and a.col_wstar == b.col_wstar, "phi, c_top, col_wstar побитно")
	check(a.pos == b.pos and a.top == b.top and a.w0 == b.w0 and a.wstar == b.wstar, "pos, top, w0, w* побитно")


## z_i столбцов выше → w* столбца выше (слой толще), потолок источников — c_top столбца.
func test_thermals_column_zi() -> void:
	var f: WindField = T_THERMALS._flat(T_THERMALS._heat300, T_THERMALS._zero3)
	var n := f.nx * f.ny
	var zc := PackedFloat32Array()
	zc.resize(n)
	for j in f.ny:
		for i in f.nx:
			zc[j * f.nx + i] = f.z_i() + (600.0 if i >= f.nx / 2 else 0.0)
	f.meta.z_i_col = zc
	f.meta.zi_alpha = ALPHA
	var s := AirThermals.new()
	check(s.build(f, T_THERMALS._cfg()), "источники строятся")
	var j := f.ny / 2
	var w_lo: float = s.col_wstar[j * f.nx + 2]
	var w_hi: float = s.col_wstar[j * f.nx + f.nx - 3]
	check(w_hi > w_lo, "w* выше там, где z_i столбца выше (%.3f > %.3f)" % [w_hi, w_lo])
	approx(w_hi / w_lo, pow((f.z_i() + 600.0 - 1000.0) / (f.z_i() - 1000.0), 1.0 / 3.0), 1.0e-4, "w* ∝ h^(1/3)")
	var ok := true
	for k in s.count():
		var p := s.pos[k]
		var i := int(floor((p.x - f.x0) / f.dx))
		var jj := int(floor((-p.z - f.y0) / f.dx))
		ok = ok and s.top[k] == s.c_top[jj * f.nx + i]
	check(ok, "потолок источника = c_top его столбца")


## CloudField: столбцы с потолком частицы выше основания дают подъём к облаку (au > 0), ниже — нет;
## потолок источника под облаком ≥ основания.
func test_base_invariant() -> void:
	var f: WindField = T_THERMALS._flat(T_THERMALS._heat300, T_THERMALS._zero3)
	var n := f.nx * f.ny
	var zc := PackedFloat32Array()
	zc.resize(n)
	for j in f.ny:
		for i in f.nx:
			zc[j * f.nx + i] = f.z_i() + (600.0 if i >= f.nx / 2 else 0.0)
	f.meta.z_i_col = zc
	f.meta.zi_alpha = ALPHA
	var air := AirThermals.new()
	check(air.build(f, T_THERMALS._cfg()), "источники строятся")
	var top_lo := -INF
	var top_hi := INF
	for c in n:
		if c % f.nx < f.nx / 2:
			top_lo = maxf(top_lo, air.c_top[c])
		else:
			top_hi = minf(top_hi, air.c_top[c])
	check(top_hi > top_lo, "потолок частицы выше там, где z_i выше (%.0f > %.0f)" % [top_hi, top_lo])
	var base := 0.5 * (top_lo + top_hi)
	var cf := CloudField.new(Config.get_config("atmosphere").cloud_field)
	cf.set_inputs({air = air, wind_field = f, cloudbase_msl = base, seed = 1})
	var prep := CloudFieldSources.prepare(cf, {air = air, wind_field = f, cloudbase_msl = base}, cf.cfg)
	var au: PackedFloat32Array = prep.au
	var ok_hi := true
	var ok_lo := true
	for c in n:
		if is_nan(air.c_top[c]) or air.phi[c] <= 0.0:
			continue
		if f.edge_weight(Vector3(f.x0 + (c % f.nx + 0.5) * f.dx, 1010.0, -(f.y0 + (c / f.nx + 0.5) * f.dx))) < 0.5:
			continue
		if air.c_top[c] > base:
			# столбцы водосбора источника отдают поток его ядру (между = 0) — проверяем свободные
			ok_hi = ok_hi and (au[c] > 0.0 or air.owner[c] >= 0)
		else:
			ok_lo = ok_lo and au[c] == 0.0
	check(ok_hi, "потолок выше основания → подъём к облаку (au > 0)")
	check(ok_lo, "потолок ниже основания → облака нет (au = 0)")
	var ok_src := true
	for s in air.count():
		var p := air.pos[s]
		var i := int(floor((p.x - cf.x0) / cf.dx))
		var j := int(floor((-p.z - cf.y0) / cf.dx))
		if i < 0 or i >= cf.nx or j < 0 or j >= cf.ny:
			continue
		if au[j * cf.nx + i] > 0.0 and air.top[s] < base:
			# подъём в столбце есть, а источник ниже основания — только если подъём от соседей («между»)
			ok_src = ok_src and air.phi[j * cf.nx + i] > 0.0
	check(ok_src, "источник под облаком — потолок ≥ основания")
	cf.reset(0.0)
	cf.step_to(600.0)
	check(cf.bg_cover > 0.0, "облака над столбцами с высоким z_i есть")
