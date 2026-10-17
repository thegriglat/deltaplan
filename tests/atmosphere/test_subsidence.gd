extends TestCase
## CLF-10 (Q3): компенсирующее опускание горно-равнинной циркуляции — там, где средний по слою
## w_conv поля W̄ < 0, верх слоя столбца ниже на |W̄|·τ_s (AirThermals.col_zi/col_sub), фон θ̄ опущен
## на столько же: потолок частицы, w* и источник облачности ниже; τ_s = 0 — побитно как поле без
## опускания; столб не ниже ZI_MIN над землёй.

const T := preload("res://tests/atmosphere/test_air_thermals.gd")
const W_SUB := 0.05  # м/с опускания в правой половине
const TAU := 10800.0


## Опускание W_SUB в правой половине (x ≥ 0) по всему слою; слева 0.
static func _sub_right(x: float, _z: float, _agl: float) -> float:
	return -W_SUB if x >= 0.0 else 0.0


static func _sub_strong(x: float, _z: float, _agl: float) -> float:
	return -1.0 if x >= 0.0 else 0.0


static func _cfg(tau: float) -> Dictionary:
	var c: Dictionary = T._cfg()
	c["subsidence_tau_s"] = tau
	return c


func test_subsidence_lowers_layer_and_ceiling() -> void:
	var f: WindField = T._flat(T._heat300, _sub_right)
	var s := AirThermals.new()
	check(s.build(f, _cfg(TAU)), "источники строятся")
	var n := f.nx * f.ny
	check(s.col_zi.size() == n and s.col_sub.size() == n, "col_zi, col_sub по столбцам")
	var j := f.ny / 2
	var cl := j * f.nx + 2
	var cr := j * f.nx + f.nx - 3
	approx(s.col_w[cr], -W_SUB, 1.0e-4, "W̄ столбца справа = опускание")
	approx(s.col_sub[cl], 0.0, 1.0e-6, "слева опускания нет")
	approx(s.col_sub[cr], W_SUB * TAU, 1.0e-3, "справа Δz_s = |W̄|·τ_s")
	approx(s.col_zi[cr], f.z_i() - W_SUB * TAU, 1.0e-3, "z_i столбца ниже на Δz_s")
	approx(s.col_zi[cl], f.z_i(), 1.0e-6, "слева z_i поля")
	var h_l := f.z_i() - T.GROUND
	var h_r := h_l - W_SUB * TAU
	approx(s.col_wstar[cr] / s.col_wstar[cl], pow(h_r / h_l, 1.0 / 3.0), 1.0e-4, "w* ∝ h^(1/3) по z_i столбца")
	print("    потолок частицы: слева %.0f м, справа %.0f м (z_i %.0f → %.0f)" % [s.c_top[cl], s.c_top[cr], s.col_zi[cl], s.col_zi[cr]])
	check(s.c_top[cr] < s.c_top[cl] - 0.5 * W_SUB * TAU, "потолок частицы справа ниже (фон θ̄ опущен)")
	check(s.c_top[cr] > s.col_zi[cr], "потолок — над опущенным верхом слоя (проскок частицы)")
	approx(s.phi[cr], s.col_f[cr], 1.0e-6, "Φ = F̄ (W̄⁻ в Φ не входит)")
	# источники: потолок = c_top столбца, w* источника — по z_i столбца
	var ok := true
	for k in s.count():
		var p := s.pos[k]
		var i := int(floor((p.x - f.x0) / f.dx))
		var jj := int(floor((-p.z - f.y0) / f.dx))
		ok = ok and s.top[k] == s.c_top[jj * f.nx + i]
	check(ok, "потолок источника = c_top его столбца")


func test_tau_zero_same_as_no_subsidence() -> void:
	var fa: WindField = T._flat(T._heat300, _sub_right)
	var fb: WindField = T._flat(T._heat300, T._zero3)
	var a := AirThermals.new()
	var b := AirThermals.new()
	check(a.build(fa, _cfg(0.0)) and b.build(fb, _cfg(0.0)), "источники строятся")
	check(a.phi == b.phi and a.c_top == b.c_top and a.col_wstar == b.col_wstar, "τ_s = 0: phi, c_top, w* побитно как без опускания")
	check(a.col_zi == b.col_zi and a.col == b.col and a.top == b.top, "τ_s = 0: z_i столбцов, источники и потолки те же")
	var zero := true
	for v in a.col_sub:
		zero = zero and v == 0.0
	check(zero, "τ_s = 0: col_sub = 0")


func test_floor_zi_min() -> void:
	var f: WindField = T._flat(T._heat300, _sub_strong)
	var s := AirThermals.new()
	check(s.build(f, _cfg(TAU)), "источники строятся")
	var c := (f.ny / 2) * f.nx + f.nx - 3
	approx(s.col_zi[c], T.GROUND + AirThermals.ZI_MIN, 1.0e-3, "сильное опускание: z_i столбца не ниже земли + ZI_MIN")
	check(s.col_wstar[c] > 0.0 and not is_nan(s.c_top[c]), "столбец считается")


## CloudField: основание между потолками половин — над опускающейся половиной подъёма к облаку нет.
func test_cloud_source_suppressed() -> void:
	var f: WindField = T._flat(T._heat300, _sub_right)
	var air := AirThermals.new()
	check(air.build(f, _cfg(TAU)), "источники строятся")
	var n := f.nx * f.ny
	var top_l := -INF
	var top_r := INF
	for c in n:
		if c % f.nx < f.nx / 2:
			top_l = maxf(top_l, air.c_top[c])
		else:
			top_r = minf(top_r, air.c_top[c])
	check(top_l > top_r, "потолок слева выше, чем справа (%.0f > %.0f)" % [top_l, top_r])
	var base := 0.5 * (top_l + top_r)
	var cf := CloudField.new(Config.get_config("atmosphere").cloud_field)
	cf.set_inputs({air = air, wind_field = f, cloudbase_msl = base, seed = 1})
	var prep := CloudFieldSources.prepare(cf, {air = air, wind_field = f, cloudbase_msl = base}, cf.cfg)
	var au: PackedFloat32Array = prep.au
	var sum_l := 0.0
	var sum_r := 0.0
	for c in n:
		if c % f.nx < f.nx / 2:
			sum_l += au[c]
		else:
			sum_r += au[c]
	print("    подъём к основанию: слева Σa_u %.2f, справа %.2f" % [sum_l, sum_r])
	check(sum_l > 0.0, "слева подъём к облаку есть")
	approx(sum_r, 0.0, 1.0e-6, "над опусканием (потолок ниже основания) — нет")
	cf.reset(0.0)
	cf.step_to(1200.0)
	var cov_l := 0.0
	var cov_r := 0.0
	for c in n:
		if c % f.nx < f.nx / 2:
			cov_l += cf.cover[c]
		else:
			cov_r += cf.cover[c]
	check(cov_l > 0.0 and cov_r < 0.1 * cov_l, "покрытие над опусканием заметно меньше (%.2f против %.2f)" % [cov_r, cov_l])
