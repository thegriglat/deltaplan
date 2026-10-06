class_name AirPhase
extends RefCounted
## Фазы поля масштаба 1 в игре (P10, docs/contracts/air-phase.md; docs/guide/air-model.md → «Фазы»):
## общие определения (порядок фаз, раскладки буферов, слоты параметров ядра), чтение конфига
## (configs/atmosphere.json → air_phase) и подготовка случая по столбцам на CPU — одна и та же для
## GPU-пути (AirPhaseJob + air_phase.glsl) и CPU-пути (AirPhaseCpu).
##
## Подготовка (prepare, O(n²) и O(n³) на 2D-сетке, рабочий поток): числа случая (Fr, N, U_sat,
## H_c, слои D, ω), огибающая срыва h_eff и эффективный рельеф A, амплитуды DCT рельефа и
## коэффициенты мод линейной теории, вечерний сток G (Прандтль + D8 — последовательный проход по
## высоте, поэтому на CPU). Дальше по клеткам и высотам (классификатор, синтез A, слои Лапласа,
## баланс θ′, сборка тёплого старта) — ядра air_phase.glsl или тот же код AirPhaseCpu.
## Спецификация формул — tools/research/air_phase/analysis/AP-18/section.md, hybrid/drainage.py,
## assembly/mechanisms.py (AP-17). Все константы — в конфиге.

const PHASES := ["A", "B", "C", "D", "F", "G", "H"]
enum { PH_A, PH_B, PH_C, PH_D, PH_F, PH_G, PH_H }
const K := 7

## Плоскости 2D-входа (col): n² чисел на плоскость, индекс j·nx + i.
enum {
	CI_HC,
	CI_HEFF,
	CI_T,
	CI_S,
	CI_GX,
	CI_GY,
	CI_HEAT,
	CI_HK,
	CI_HBL,
	CI_WST,
	CI_GL,
	CI_GDTH,
	CI_GUS,
	CI_GON,
	CI_GLAY,
	CI_GD,
	CI_GUC,
	CI_GDX,
	CI_GDY,
	CI_GW,
	NCI
}
## Плоскости мод линейной теории (modes): амплитуда, ℓ, затем по 4 знакам (sk, sl) — Re σ, Re m, Im m.
const MO_AMP := 0
const MO_ELL := 1
const MO_S0 := 2
const NMO := 14
## Знаки (sk, sl) четырёх продолжений DCT (AP-17 _synth): (+,+), (−,+), (+,−), (−,−).
const SIGNS := [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]
## Компоненты синтеза A: δu, δv, δw, η.
const NCOMP := 4
## Плоскости 2D-выхода (o2d): U слоя перемешивания, θ′ (два буфера прогонки), заморозка m/h, флаг NaN.
enum { O_UML, O_TH0, O_TH1, O_FRZ_M, O_FRZ_H, O_FLAG, NO2D }
## Варианты: решение без нагрева (m, для w_mech) и с нагревом (h).
enum { V_M, V_H }
## Стадии весов: сырые, после прохода по x, «до G» (сглажены, Σ = 1), итог (с G).
enum { WS_RAW, WS_TMP, WS_PRE, WS_FIN, NWS }

## Слоты параметров ядра (prm, float32) — тот же список в air_phase.glsl.
enum {
	P_DX,
	P_DZ,
	P_ZBOT,
	P_EX,
	P_EY,
	P_USAT,
	P_ZSAT,
	P_ALPHA,
	P_Z0,
	P_FR,
	P_NEFF,
	P_HCD,
	P_NL,
	P_USTAR,
	P_HEATED,
	P_ZI,
	P_GAMW,
	P_GACT,
	P_GDTHC,
	P_TAU,
	P_FR_H,
	P_W_H,
	P_FR_D,
	P_W_D,
	P_FR_C_LO,
	P_FR_C_HI,
	P_W_C,
	P_LEE_DEPTH,
	P_LEE_HLO,
	P_LEE_HHI,
	P_LEE_STEEP,
	P_LEE_HSK,
	P_ZIL_C,
	P_W_EF,
	P_FR_INF,
	P_FR_FREEZE,
	P_FRZ_WDEC,
	P_FRZ_W,
	P_WS_OVER_U,
	P_CAP,
	P_BUB_R,
	P_SLOPE_LEN,
	P_ANA_DMIN,
	P_ANA_DFRAC,
	P_UML_N,
	P_UML_MIN,
	P_SOR_OMEGA,
	P_G_TOPL,
	P_G_MEMB,
	P_GRAV,
	P_THETA0,
	P_KAPPA,
	P_UREF_MIN,
	P_GK_R,
	P_GK0
}
const GK_MAX := 17
const P_LEV0 := P_GK0 + GK_MAX
const LEV_MAX := 16
const P_NLEV := P_LEV0 + LEV_MAX
const P_ZL0 := P_NLEV + 1
const ZL_MAX := 16
const NPRM := 128

## Входы, которые не зависят от погоды: g, θ0, κ, ρc_p — как решатель (AirCase).
const GRAV := AirCase.G
const THETA0 := AirCase.THETA0
const KAPPA := AirCase.KAPPA
const RHO_CP := AirCase.RHO_CP


## Блок air_phase конфига (главный поток: Config — автозагрузка).
static func config() -> Dictionary:
	var cfg: Dictionary = Config.get_config("atmosphere").get("air_phase", {})
	if cfg.is_empty():
		push_error("AirPhase: нет configs/atmosphere.json → air_phase")
	return cfg


## Значение группы конфига (ошибка — нет ключа: констант в коде нет).
static func cv(cfg: Dictionary, group: String, key: String) -> Variant:
	var d: Dictionary = cfg.get(group, {}) if group != "" else cfg
	if not d.has(key):
		push_error("AirPhase: нет ключа air_phase.%s.%s" % [group, key])
		return 0.0
	return d[key]


static func cf(cfg: Dictionary, group: String, key: String) -> float:
	return float(cv(cfg, group, key))


# ---------------------------------------------------------------- помощники формул


## σ((lg x − lg x_c)/w) — граница фазы (P6 fit_sigmoid; AP-17 sigmoid_log).
static func sig_log(x: float, xc: float, w: float) -> float:
	var lx := log(maxf(x, 1e-12)) / log(10)
	return 1.0 / (1.0 + exp(-(lx - log(xc) / log(10)) / w))


## Принадлежность полосе [lo, hi] по lg x (AP-18 band).
static func band(x: float, lo: float, hi: float, w: float) -> float:
	return sig_log(x, lo, w) * (1.0 - sig_log(x, hi, w))


static func smooth01(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3 - 2 * t)


## Профиль притока решателя: U(z) = U_sat·min((z/z_sat)^α, 1) (AirCase._prof, air.py wind_profile).
static func u_prof(p: Dictionary, z: float) -> float:
	if p.usat <= 0.0:
		return 0.0
	return p.usat * minf(pow(maxf(z, p.z0) / p.zsat, p.alpha), 1.0)


## cos(π·p·(i + ½)/n) без больших аргументов float32: p(2i + 1) по модулю 4n.
static func cosb(n: int, i: int, p: int) -> float:
	return cos(PI * float((p * (2 * i + 1)) % (4 * n)) / float(2 * n))


static func sinb(n: int, i: int, p: int) -> float:
	return sin(PI * float((p * (2 * i + 1)) % (4 * n)) / float(2 * n))


## Ядро гаусса σ (клетки), радиус int(truncate·σ + ½) — как scipy gaussian_filter; σ ≤ min_sigma — [1].
static func gauss_kernel(sigma: float, truncate: float, min_sigma: float) -> PackedFloat64Array:
	var w := PackedFloat64Array([1.0])
	if sigma <= min_sigma:
		return w
	var r := int(truncate * sigma + 0.5)
	w.resize(2 * r + 1)
	var s := 0.0
	for q in range(-r, r + 1):
		var e := exp(-0.5 * pow(q / sigma, 2.0))
		w[q + r] = e
		s += e
	for q in w.size():
		w[q] /= s
	return w


## Отражение «через полуклетку» (scipy mode="reflect": d c b a | a b c d).
static func refl(i: int, n: int) -> int:
	var period := 2 * n
	var m := posmod(i, period)
	return m if m < n else period - 1 - m


## Гаусс 2D (раздельно, отражение через полуклетку), a — ny·nx.
static func gauss2(a: PackedFloat64Array, nx: int, ny: int, ker: PackedFloat64Array) -> PackedFloat64Array:
	var r := ker.size() / 2
	if r == 0:
		return a.duplicate()
	var t := PackedFloat64Array()
	t.resize(a.size())
	for j in ny:
		for i in nx:
			var s := 0.0
			for q in range(-r, r + 1):
				s += ker[q + r] * a[j * nx + refl(i + q, nx)]
			t[j * nx + i] = s
	var o := PackedFloat64Array()
	o.resize(a.size())
	for j in ny:
		for i in nx:
			var s := 0.0
			for q in range(-r, r + 1):
				s += ker[q + r] * t[refl(j + q, ny) * nx + i]
			o[j * nx + i] = s
	return o


## Градиент как numpy.gradient(a, dx): центральные разности, на краях — односторонние.
static func grad(a: PackedFloat64Array, nx: int, ny: int, dx: float) -> Array:
	var gx := PackedFloat64Array()
	var gy := PackedFloat64Array()
	gx.resize(a.size())
	gy.resize(a.size())
	for j in ny:
		for i in nx:
			var q := j * nx + i
			if i == 0:
				gx[q] = (a[q + 1] - a[q]) / dx
			elif i == nx - 1:
				gx[q] = (a[q] - a[q - 1]) / dx
			else:
				gx[q] = (a[q + 1] - a[q - 1]) / (2 * dx)
			if j == 0:
				gy[q] = (a[q + nx] - a[q]) / dx
			elif j == ny - 1:
				gy[q] = (a[q] - a[q - nx]) / dx
			else:
				gy[q] = (a[q + nx] - a[q - nx]) / (2 * dx)
	return [gx, gy]


## Процентиль (numpy, линейная интерполяция).
static func percentile(a: PackedFloat64Array, pct: float) -> float:
	var s := a.duplicate()
	s.sort()
	var pos := pct / 100 * (s.size() - 1)
	var i0 := floori(pos)
	var i1 := mini(i0 + 1, s.size() - 1)
	return s[i0] + (pos - i0) * (s[i1] - s[i0])


static func median(a: PackedFloat64Array) -> float:
	return percentile(a, 50)


# ---------------------------------------------------------------- подготовка случая


## Всё по столбцам и модам на CPU (рабочий поток можно: Config не трогает). case — AirCase
## (prepare() вызывается здесь, если ещё не был). → словарь: размеры, числа случая, col (NCI·n²),
## modes (NMO·n²), gk (ядро сглаживания весов), omega, prm (PackedFloat32Array NPRM), diag.
static func prepare(case: AirCase, cfg: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	if case.prm.is_empty() and not case.prepare():
		return {error = "AirPhase: AirCase не готов (размеры)"}
	var nx := case.nx
	var ny := case.ny
	var n2 := nx * ny
	var p := {
		nx = nx,
		ny = ny,
		nz = case.nz,
		n2 = n2,
		dx = case.dx,
		dz = case.dz,
		z_bot = case.z_bot,
		NX = nx + 2,
		NY = ny + 2,
		NZ = case.nz + 2,
		cfg = cfg,
		windy = case.u10 > 0.0,
		ex = case.ex,
		ey = case.ey,
		usat = case.u_a,
		zsat = float(case.prm[12]),
		alpha = float(case.p.alpha),
		z0 = float(case.p.z0),
		ustar = case.ustar,
		tau = float(case.p.tau_cool),
		u10 = case.u10,
	}
	p.N = p.NX * p.NY * p.NZ
	var lev := PackedFloat64Array()
	for z in cv(cfg, "", "agl_levels_m"):
		lev.append(float(z))
	p.lev = lev
	var hc := case.hc
	var lo := INF
	var hi := -INF
	for v in hc:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	p.hmin = lo
	p.relief = hi - lo
	# ---- N над слоем перемешивания (derive S2: среднее √(g/θ0·max(γ, 0)) в z_i … z_i + n_layer_m)
	var zref := case.z_i if is_finite(case.z_i) else lo
	var nlay := cf(cfg, "classifier", "n_layer_m")
	var ns := 0.0
	var cnt := 0
	for k in range(1, case.nz + 1):
		var z := case.zc(k)
		if z >= zref and z <= zref + nlay:
			ns += sqrt(GRAV / THETA0 * maxf(case.gam[k], 0.0))
			cnt += 1
	var nbv := ns / cnt if cnt > 0 else 0.0
	p.n_bv = nbv
	var fr_inf := cf(cfg, "classifier", "fr_inf")
	p.fr = p.usat / (nbv * maxf(p.relief, 1.0)) if nbv > 0.0 else fr_inf
	# N для линейной теории (AP-17 n_effective): слой перемешивания выше рельефа — доля рельефа
	var zi_agl := case.z_i - lo if is_finite(case.z_i) else -1.0
	p.n_eff = nbv
	if zi_agl > p.relief and zi_agl > 0.0:
		p.n_eff = nbv * minf(1.0, p.relief / zi_agl)
	# волновая часть θ′ = −γ·η выше z_i (γ = θ0N²/g); нет z_i — весь столб устойчив
	p.zi = case.z_i if is_finite(case.z_i) else case.z_bot - case.dz
	p.gamw = THETA0 * nbv * nbv / GRAV
	p.zi_agl = zi_agl
	# ---- D: разделяющая линия тока и слои Лапласа
	var base := percentile(hc, cf(cfg, "d", "base_pct"))
	p.base = base
	p.hcd = base
	if p.fr < 1.0:
		p.hcd = base + (hi - base) * (1.0 - p.fr)
	var zl := PackedFloat64Array()
	if p.hcd > base + 1.0:
		var nl := mini(
			mini(int(cv(cfg, "d", "max_layers")), ZL_MAX),
			maxi(1, ceili((p.hcd - base) / cf(cfg, "d", "dz_layer_m")))
		)
		for q in nl:
			zl.append(base + (q + 0.5) * (p.hcd - base) / nl)
	p.zl = zl
	# ---- ω по карте фаз (AP-18: Fr, U10 — величины случая, карта однородна)
	var om: Dictionary = cfg.get("omega", {})
	var bw := float(om.band_w_dec)
	p.b_fr = band(p.fr, float(om.fr_band[0]), float(om.fr_band[1]), bw)
	p.b_u = band(p.u10, float(om.u10_band[0]), float(om.u10_band[1]), bw)
	var omega := 1.0 - (1.0 - float(om.omega_band)) * maxf(p.b_fr, p.b_u)
	if omega > 1.0 - float(om.omega_snap):
		omega = 1.0
	p.omega = omega
	# ---- нагрев
	var heat := case.heat
	p.heated = false
	if not heat.is_empty():
		for v in heat:
			p.heated = p.heated or v != 0.0
	# ---- 2D-вход
	var col := PackedFloat64Array()
	col.resize(NCI * n2)
	var g := grad(hc, nx, ny, case.dx)
	for q in n2:
		col[CI_HC * n2 + q] = hc[q]
		col[CI_GX * n2 + q] = g[0][q]
		col[CI_GY * n2 + q] = g[1][q]
		col[CI_S * n2 + q] = sqrt(g[0][q] * g[0][q] + g[1][q] * g[1][q])
		col[CI_HEAT * n2 + q] = heat[q] if p.heated else 0.0
		col[CI_HK * n2 + q] = case.heat_used[q] / RHO_CP if p.heated else 0.0
		col[CI_HBL * n2 + q] = case.h_bl[q]
		col[CI_WST * n2 + q] = case._wst[q]
	var heff := envelope(p, hc)
	for q in n2:
		col[CI_HEFF * n2 + q] = heff[q]
		col[CI_T * n2 + q] = maxf(heff[q], p.hcd) if not zl.is_empty() else heff[q]
	p.shadow_frac = 0.0
	for q in n2:
		p.shadow_frac += (1.0 if heff[q] > hc[q] + 1.0 else 0.0) / n2
	p.col = col
	p.modes = modes(p, col.slice(CI_T * n2, (CI_T + 1) * n2))
	var sc := cf(cfg, "classifier", "smooth_cells")
	p.gk = gauss_kernel(sc, cf(cfg, "classifier", "smooth_truncate"), cf(cfg, "classifier", "smooth_min_cells"))
	if p.gk.size() > GK_MAX:
		push_error("AirPhase: ядро сглаживания весов длиннее %d (smooth_cells)" % GK_MAX)
		p.gk = p.gk.slice(p.gk.size() / 2 - GK_MAX / 2, p.gk.size() / 2 + GK_MAX / 2 + 1)
	p.g = drainage(p, case)
	p.prm = params(p)
	p.ms_prepare = (Time.get_ticks_usec() - t0) / 1000
	return p


## Огибающая срыва h_eff = max(h, линия тени): h_eff(p) = max(h(p), h_eff(p − e·dx) − dx·tg угла),
## билинейно (AP-10, AP-17 envelope); проходы Гаусса–Зейделя по ветру до неподвижной точки (та же
## наименьшая неподвижная точка, что у прохода Якоби эталона).
static func envelope(p: Dictionary, hc: PackedFloat64Array) -> PackedFloat64Array:
	var he := hc.duplicate()
	var cfg: Dictionary = p.cfg
	var ang := cf(cfg, "classifier", "lee_angle_deg")
	if not p.windy or ang <= 0.0:
		return he
	var nx: int = p.nx
	var ny: int = p.ny
	var ex: float = p.ex
	var ey: float = p.ey
	var drop: float = p.dx * tan(deg_to_rad(ang))
	var order := []
	for q in p.n2:
		order.append(q)
	var key := PackedFloat64Array()
	key.resize(p.n2)
	for q in p.n2:
		key[q] = (q % nx) * ex + (q / nx) * ey
	order.sort_custom(func(a: int, b: int) -> bool: return key[a] < key[b] or (key[a] == key[b] and a < b))
	for _s in int(cv(cfg, "classifier", "env_max_sweeps")):
		var changed := false
		for q: int in order:
			var i := q % nx
			var j := q / nx
			var fi := i - ex
			var fj := j - ey
			if fi < 0.0 or fi > nx - 1 or fj < 0.0 or fj > ny - 1:
				continue
			var i0 := clampi(floori(fi), 0, nx - 2)
			var j0 := clampi(floori(fj), 0, ny - 2)
			var a := fi - i0
			var b := fj - j0
			var v := (
				(1 - b) * ((1 - a) * he[j0 * nx + i0] + a * he[j0 * nx + i0 + 1])
				+ b * ((1 - a) * he[(j0 + 1) * nx + i0] + a * he[(j0 + 1) * nx + i0 + 1])
			)
			var nv := maxf(hc[q], v - drop)
			if nv != he[q]:
				he[q] = nv
				changed = true
		if not changed:
			break
	return he


## Моды линейной теории (AP-17 linear_a): амплитуды DCT-II рельефа t − ⟨t⟩, масштабы Джексона–Ханта
## ℓ, h_m, U_ref = U(h_m), по 4 знакам — Re σ и m (ветвь: волна вверх, затухание с высотой).
static func modes(p: Dictionary, t: PackedFloat64Array) -> PackedFloat64Array:
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var cfg: Dictionary = p.cfg
	var mean := 0.0
	for v in t:
		mean += v / n2
	# R[j, p] = Σ_i (t − ⟨t⟩)[j, i]·C[i, p]; amp[q, p] = s_q² s_p² Σ_j C[j, q]·R[j, p]
	var cx := PackedFloat64Array()
	cx.resize(nx * nx)
	for i in nx:
		for pp in nx:
			cx[i * nx + pp] = cosb(nx, i, pp)
	var cy := PackedFloat64Array()
	cy.resize(ny * ny)
	for j in ny:
		for q in ny:
			cy[j * ny + q] = cosb(ny, j, q)
	var r := PackedFloat64Array()
	r.resize(n2)
	for j in ny:
		for pp in nx:
			var s := 0.0
			for i in nx:
				s += (t[j * nx + i] - mean) * cx[i * nx + pp]
			r[j * nx + pp] = s
	var out := PackedFloat64Array()
	out.resize(NMO * n2)
	for q in ny:
		var sy := (1.0 if q == 0 else 2.0) / ny
		for pp in nx:
			var s := 0.0
			for j in ny:
				s += cy[j * ny + q] * r[j * nx + pp]
			var sx := (1.0 if pp == 0 else 2.0) / nx
			out[MO_AMP * n2 + q * nx + pp] = s * sy * sx
	out[MO_AMP * n2] = 0.0
	var z0: float = p.z0
	var it := int(cv(cfg, "a", "jh_iters"))
	var damp := cf(cfg, "a", "damp_m")
	var umin := cf(cfg, "a", "uref_min")
	var nn: float = p.n_eff
	for q in ny:
		for pp in nx:
			var c := q * nx + pp
			var kx: float = PI * pp / (nx * p.dx)
			var ky: float = PI * q / (ny * p.dx)
			var km := sqrt(kx * kx + ky * ky)
			if c == 0:
				km = 1.0
			var big_l := 1.0 / maxf(km, 1e-12)
			var ell := float(cv(cfg, "a", "jh_ell0_m"))
			var hm := float(cv(cfg, "a", "jh_hm0_m"))
			for _i in it:
				ell = 2 * KAPPA * KAPPA * big_l / log(maxf(ell, 2 * z0) / z0)
				hm = big_l / sqrt(log(maxf(hm, 2 * z0) / z0))
			ell = maxf(ell, 2 * z0)
			hm = maxf(hm, 2 * z0)
			out[MO_ELL * n2 + c] = ell
			var uref := maxf(u_prof(p, hm), umin)
			var eps := uref / damp
			for s in 4:
				var sg: Vector2i = SIGNS[s]
				var a: float = uref * (p.ex * sg.x * kx + p.ey * sg.y * ky)
				# σ = a − iε; σ² = (a² − ε²) − 2iaε; N²/σ² = N²·conj(σ²)/|σ²|²
				var s2r := a * a - eps * eps
				var s2i := -2 * a * eps
				var s2m := s2r * s2r + s2i * s2i
				var rr := nn * nn * s2r / s2m - 1.0
				var ri := -nn * nn * s2i / s2m
				var m2r := rr * km * km
				var m2i := ri * km * km
				var mod := sqrt(m2r * m2r + m2i * m2i)
				var mre := sqrt(maxf(0.5 * (mod + m2r), 0.0))
				var mim := sqrt(maxf(0.5 * (mod - m2r), 0.0))
				var sgn := 1.0 if a + 1e-30 >= 0.0 else -1.0
				out[(MO_S0 + 3 * s) * n2 + c] = a
				out[(MO_S0 + 3 * s + 1) * n2 + c] = absf(mre) * sgn
				out[(MO_S0 + 3 * s + 2) * n2 + c] = absf(mim)
	return out


## Вечерний сток G (AP-18 drainage.py) по столбцам: модель Прандтля на склонах, накопление расхода
## D8 вниз по сглаженному рельефу и гидравлический слой в долинах; вес G — сток против фона.
## Выхолаживание — поток тепла игры (AirCase.heat < 0). Пишет плоскости CI_G* в p.col; → diag.
static func drainage(p: Dictionary, case: AirCase) -> Dictionary:
	var cfg: Dictionary = p.cfg
	var gc: Dictionary = cfg.get("g", {})
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var heat := case.heat
	var diag := {active = false}
	if heat.is_empty():
		return diag
	var mh := 0.0
	var any_cool := false
	for v in heat:
		mh += v / n2
		any_cool = any_cool or v <= 0.0
	var nbv: float = p.n_bv
	if not (mh <= float(gc.mean_heat_max_wm2) and nbv > float(gc.n_min) and any_cool):
		return diag
	var hs := gauss2(case.hc, nx, ny, gauss_kernel(
			float(gc.smooth_cells), cf(cfg, "classifier", "smooth_truncate"), cf(cfg, "classifier", "smooth_min_cells")
		))
	var gr := grad(hs, nx, ny, p.dx)
	var sin_min := float(gc.sin_min)
	var dth_max := float(gc.dth_max_k)
	var umax := float(gc.u_max_ms)
	var peak := exp(-PI / 4) * sin(PI / 4)
	var l := PackedFloat64Array()
	var dth := PackedFloat64Array()
	var us := PackedFloat64Array()
	var on := PackedByteArray()
	var sina := PackedFloat64Array()
	var qc := PackedFloat64Array()
	for a in [l, dth, us, sina, qc]:
		a.resize(n2)
	on.resize(n2)
	var dths_on := PackedFloat64Array()
	for c in n2:
		var gx: float = gr[0][c]
		var gy: float = gr[1][c]
		var gm := sqrt(gx * gx + gy * gy)
		var sa := gm / sqrt(1.0 + gm * gm)
		sina[c] = sa
		var pr := prandtl(sa, nbv, minf(heat[c], 0.0), gc)
		var lc: float = pr.l
		var dt: float = pr.dth
		var u: float = pr.us
		var o := sa >= sin_min
		l[c] = lc
		dth[c] = dt
		us[c] = u if o else 0.0
		on[c] = 1 if o else 0
		qc[c] = 0.5 * us[c] * lc if heat[c] <= 0.0 else 0.0
		if o:
			dths_on.append(dt)
	# D8: каждая клетка отдаёт накопленный расход соседу с наибольшим уклоном вниз (по убыванию высоты)
	var order := []
	for c in n2:
		order.append(c)
	order.sort_custom(func(a: int, b: int) -> bool: return hs[a] > hs[b] or (hs[a] == hs[b] and a < b))
	var big_q := PackedFloat64Array()
	var ex8 := PackedFloat64Array()
	var ey8 := PackedFloat64Array()
	big_q.resize(n2)
	ex8.resize(n2)
	ey8.resize(n2)
	for c in n2:
		big_q[c] = qc[c] * p.dx
	for c: int in order:
		var j := c / nx
		var i := c % nx
		var best := 0.0
		var bj := -1
		var bi := -1
		for dj in [-1, 0, 1]:
			for di in [-1, 0, 1]:
				if dj == 0 and di == 0:
					continue
				var jj: int = j + dj
				var ii: int = i + di
				if jj < 0 or jj >= ny or ii < 0 or ii >= nx:
					continue
				var sl: float = (hs[c] - hs[jj * nx + ii]) / (p.dx * sqrt(float(dj * dj + di * di)))
				if sl > best:
					best = sl
					bj = jj
					bi = ii
		if bj >= 0:
			big_q[bj * nx + bi] += big_q[c]
			var rr := sqrt(float((bj - j) * (bj - j) + (bi - i) * (bi - i)))
			ex8[c] = (bi - i) / rr
			ey8[c] = (bj - j) / rr
	var dth_c := median(dths_on) if not dths_on.is_empty() else dth_max
	var gp := GRAV * dth_c / (2 * THETA0)
	var cd := float(gc.c_d)
	var relief := local_relief(case.hc, nx, ny, maxi(1, roundi(float(gc.relief_r_m) / p.dx)))
	var d_max := float(gc.d_max_m)
	var topl := float(gc.top_l)
	var w_dec := float(gc.w_dec)
	var zg_min := float(gc.zg_min_m)
	var stats := {umax = PackedFloat64Array(), l = PackedFloat64Array(), d = PackedFloat64Array(), uc = PackedFloat64Array()}
	var nlayer := 0
	var wsum := 0.0
	var wge := 0
	for c in n2:
		var sf := maxf(sina[c], float(gc.sin_floor))
		var d := pow(big_q[c] / p.dx, 2.0 / 3) * pow(cd / (gp * sf), 1.0 / 3)
		var dcap := minf(0.5 * relief[c], d_max)
		d = minf(d, maxf(dcap, 1.0))
		var uc := minf(sqrt(gp * d * sf / cd), big_q[c] / maxf(d * p.dx, 1e-9))
		uc = minf(uc, umax)
		var layer := d > topl * l[c]
		var gm := sqrt(gr[0][c] * gr[0][c] + gr[1][c] * gr[1][c])
		var dx_: float = -gr[0][c] / maxf(gm, 1e-12) if gm > 0.0 else 0.0
		var dy_: float = -gr[1][c] / maxf(gm, 1e-12) if gm > 0.0 else 0.0
		var ug := uc if layer else peak * us[c]
		var zg := 0.5 * d if layer else PI / 4 * l[c]
		var ubg := u_prof(p, maxf(zg, zg_min))
		var w := 1.0 / (1.0 + exp(-(log(maxf(ug, 1e-6)) - log(maxf(ubg, 1e-6))) / log(10) / w_dec))
		if not (heat[c] <= 0.0 and (on[c] == 1 or layer)):
			w = 0.0
		col[CI_GL * n2 + c] = l[c]
		col[CI_GDTH * n2 + c] = dth[c]
		col[CI_GUS * n2 + c] = us[c]
		col[CI_GON * n2 + c] = on[c]
		col[CI_GLAY * n2 + c] = 1.0 if layer else 0.0
		col[CI_GD * n2 + c] = d
		col[CI_GUC * n2 + c] = uc
		col[CI_GDX * n2 + c] = ex8[c] if layer else dx_
		col[CI_GDY * n2 + c] = ey8[c] if layer else dy_
		col[CI_GW * n2 + c] = w
		if on[c] == 1:
			stats.umax.append(peak * us[c])
			stats.l.append(l[c])
		if layer:
			nlayer += 1
			stats.d.append(d)
			stats.uc.append(uc)
		wsum += w / n2
		wge += 1 if w >= cf(cfg, "freeze", "freeze_w") else 0
	p.col = col
	diag = {
		active = true,
		dth_c = dth_c,
		heat_mean = mh,
		umax_med = median(stats.umax) if not stats.umax.is_empty() else 0.0,
		l_med = median(stats.l) if not stats.l.is_empty() else 0.0,
		layer_frac = float(nlayer) / n2,
		d_layer_med = median(stats.d) if not stats.d.is_empty() else 0.0,
		uc_layer_med = median(stats.uc) if not stats.uc.is_empty() else 0.0,
		w_mean = wsum,
		w_ge_frac = float(wge) / n2,
	}
	return diag


## Модель Прандтля склона с замыканием по потоку (Prandtl 1942; Zardi & Whiteman 2013 §2.4; AP-18
## drainage.prandtl): l = √(2K/(N·sin α)), Δθ = |H|·l/(ρc_p·K) ≤ dth_max, u_s = Δθ·g/(θ0·N) (u_max = e^(−π/4)
## sin(π/4)·u_s ≤ u_max_ms); профиль θ′ = −Δθ·e^(−n/l)·cos(n/l), u = u_s·e^(−n/l)·sin(n/l) вниз по склону.
static func prandtl(sin_a: float, nbv: float, h_cool: float, gc: Dictionary) -> Dictionary:
	var kk := float(gc.k_m2s)
	var s := maxf(sin_a, float(gc.sin_min))
	var l := sqrt(2 * kk / (nbv * s))
	var dt := minf(absf(h_cool) * l / (RHO_CP * kk), float(gc.dth_max_k))
	var peak := exp(-PI / 4) * sin(PI / 4)
	var u := minf(dt * GRAV / (THETA0 * nbv), float(gc.u_max_ms) / peak)
	dt = u * THETA0 * nbv / GRAV
	return {l = l, dth = dt, us = u, umax = peak * u, nj = PI / 4 * l, q = 0.5 * u * l}


## Местный перепад max − min в квадрате (2r + 1)² (край — ближайшая клетка, как scipy «nearest»).
static func local_relief(a: PackedFloat64Array, nx: int, ny: int, r: int) -> PackedFloat64Array:
	var mx := PackedFloat64Array()
	var mn := PackedFloat64Array()
	mx.resize(a.size())
	mn.resize(a.size())
	for j in ny:
		for i in nx:
			var hi := -INF
			var lo := INF
			for q in range(-r, r + 1):
				var v := a[j * nx + clampi(i + q, 0, nx - 1)]
				hi = maxf(hi, v)
				lo = minf(lo, v)
			mx[j * nx + i] = hi
			mn[j * nx + i] = lo
	var out := PackedFloat64Array()
	out.resize(a.size())
	for j in ny:
		for i in nx:
			var hi := -INF
			var lo := INF
			for q in range(-r, r + 1):
				var jj := clampi(j + q, 0, ny - 1)
				hi = maxf(hi, mx[jj * nx + i])
				lo = minf(lo, mn[jj * nx + i])
			out[j * nx + i] = hi - lo
	return out


## Слоты параметров ядра (тот же список — air_phase.glsl).
static func params(p: Dictionary) -> PackedFloat32Array:
	var cfg: Dictionary = p.cfg
	var a := PackedFloat32Array()
	a.resize(NPRM)
	var cl: Dictionary = cfg.get("classifier", {})
	var fz: Dictionary = cfg.get("freeze", {})
	var f: Dictionary = cfg.get("f", {})
	var gc: Dictionary = cfg.get("g", {})
	var vals := {
		P_DX: p.dx,
		P_DZ: p.dz,
		P_ZBOT: p.z_bot,
		P_EX: p.ex,
		P_EY: p.ey,
		P_USAT: p.usat,
		P_ZSAT: p.zsat,
		P_ALPHA: p.alpha,
		P_Z0: p.z0,
		P_FR: p.fr,
		P_NEFF: p.n_eff,
		P_HCD: p.hcd,
		P_NL: p.zl.size(),
		P_USTAR: p.ustar,
		P_HEATED: 1.0 if p.heated else 0.0,
		P_ZI: p.zi,
		P_GAMW: p.gamw,
		P_GACT: 1.0 if p.g.active else 0.0,
		P_GDTHC: p.g.get("dth_c", 0.0),
		P_TAU: p.tau,
		P_FR_H: cl.fr_h,
		P_W_H: cl.w_h,
		P_FR_D: cl.fr_d,
		P_W_D: cl.w_d,
		P_FR_C_LO: cl.fr_c_lo,
		P_FR_C_HI: cl.fr_c_hi,
		P_W_C: cl.w_c,
		P_LEE_DEPTH: cl.lee_depth_m,
		P_LEE_HLO: cl.lee_heat_lo_wm2,
		P_LEE_HHI: cl.lee_heat_hi_wm2,
		P_LEE_STEEP: cl.lee_steep,
		P_LEE_HSK: cl.lee_heat_steep_k,
		P_ZIL_C: cl.zil_c,
		P_W_EF: cl.w_ef,
		P_FR_INF: cl.fr_inf,
		P_FR_FREEZE: fz.fr_freeze,
		P_FRZ_WDEC: fz.freeze_w_dec,
		P_FRZ_W: fz.freeze_w,
		P_WS_OVER_U: fz.wstar_over_usat,
		P_CAP: cf(cfg, "a", "cap_frac"),
		P_BUB_R: cf(cfg, "b", "bubble_reverse"),
		P_SLOPE_LEN: f.slope_len_m,
		P_ANA_DMIN: f.ana_delta_min_m,
		P_ANA_DFRAC: f.ana_delta_frac,
		P_UML_N: mini(int(f.uml_levels), p.lev.size()),
		P_UML_MIN: f.uml_min_ms,
		P_SOR_OMEGA: cf(cfg, "d", "sor_omega"),
		P_G_TOPL: gc.top_l,
		P_G_MEMB: gc.member_frac,
		P_GRAV: GRAV,
		P_THETA0: THETA0,
		P_KAPPA: KAPPA,
		P_UREF_MIN: cf(cfg, "a", "uref_min"),
		P_GK_R: p.gk.size() / 2,
		P_NLEV: p.lev.size(),
	}
	for key: int in vals:
		a[key] = float(vals[key])
	for q in p.gk.size():
		a[P_GK0 + q] = p.gk[q]
	if p.lev.size() > LEV_MAX:
		push_error("AirPhase: высот agl_levels_m больше %d" % LEV_MAX)
	for q in mini(p.lev.size(), LEV_MAX):
		a[P_LEV0 + q] = p.lev[q]
	for q in p.zl.size():
		a[P_ZL0 + q] = p.zl[q]
	return a


# ---------------------------------------------------------------- итог (общий для GPU и CPU)


## Словарь P10 из скачанных/посчитанных массивов: weights (оба варианта), заморозка, выход
## (u, v, w, th — плоскости N подряд, раскладка с ореолом) → warm/mech_field и статистика.
static func result(
	p: Dictionary,
	wf: Array,
	frz: Array,
	outv: Array,
	ms_parts: Dictionary,
	nan_found: bool
) -> Dictionary:
	if nan_found:
		push_error("AirPhase: NaN/∞ в сборке — заменены нулями")
	var n: int = p.N
	var states := []
	for v in 2:
		var o: PackedFloat32Array = outv[v]
		var pz := PackedFloat32Array()
		pz.resize(n)
		states.append({u = o.slice(0, n), v = o.slice(n, 2 * n), w = o.slice(2 * n, 3 * n), th = o.slice(3 * n, 4 * n), p = pz})
	var omega := PackedFloat32Array()
	omega.resize(p.n2)
	omega.fill(p.omega)
	var r := {
		weights = wf[V_H],
		omega = omega,
		freeze = frz[V_H],
		warm = states[V_H],
		mech_field = states[V_H],
		weights_mech = wf[V_M],
		freeze_mech = frz[V_M],
		warm_mech = states[V_M],
		mech_field_mech = states[V_M],
	}
	r.stats = stats(p, wf[V_H], frz)
	var total := 0.0
	for k in ms_parts:
		total += float(ms_parts[k])
	r.ms = total
	r.ms_parts = ms_parts
	return r


## Статистика: доли фаз по площади, числа случая, H — разброс, F — w*, z_i, σ_w(z), доля восходящих
## (модель потока массы по моментам LWP80), G — числа стока.
static func stats(p: Dictionary, w: PackedFloat32Array, frz: Array) -> Dictionary:
	var n2: int = p.n2
	var cfg: Dictionary = p.cfg
	var frac := {}
	for k in K:
		var s := 0.0
		for c in n2:
			s += w[k * n2 + c]
		frac[PHASES[k]] = s / n2
	var fz := [0.0, 0.0]
	for v in 2:
		var b: PackedByteArray = frz[v]
		for c in n2:
			fz[v] += float(b[c]) / n2
	var col: PackedFloat64Array = p.col
	var wmax := 0.0
	var wf_sum := 0.0
	var wf_w := 0.0
	for c in n2:
		var ws := col[CI_WST * n2 + c]
		wmax = maxf(wmax, ws)
		wf_sum += ws * w[PH_F * n2 + c]
		wf_w += w[PH_F * n2 + c]
	var spread_frac := cf(cfg, "h", "spread_frac")
	return {
		phase_frac = frac,
		fr = p.fr,
		n_bv = p.n_bv,
		u_sat = p.usat,
		u10 = p.u10,
		omega = p.omega,
		b_fr = p.b_fr,
		b_u = p.b_u,
		frozen_frac = fz[V_H],
		frozen_frac_mech = fz[V_M],
		hc_dividing = p.hcd,
		d_layers = p.zl.size(),
		shadow_frac = p.shadow_frac,
		h_spread = spread_frac * p.usat * frac.H,
		wstar_max = wmax,
		wstar_f = wf_sum / wf_w if wf_w > 0.0 else 0.0,
		zi_agl = p.zi_agl,
		convection = convection_profile(cfg),
		g = p.g,
		ms_prepare = p.ms_prepare,
	}


## Подобие слоя перемешивания по z/z_i (LWP80, LS80): σ_w/w*, ⟨w′³⟩/w*³, асимметрия S, доля
## площади восходящих a_up = ½(1 − S/√(S² + 4)) и их скорость w_up/w* = σ_w/w*·√((1 − a)/a)
## (модель потока массы с двумя «шляпами», Randall et al. 1992). Только для z/z_i ∈ (0, 1).
static func updraft(cfg: Dictionary, zr: float) -> Dictionary:
	var a := cf(cfg, "f", "sigw_a")
	var b := cf(cfg, "f", "sigw_b")
	var c3 := cf(cfg, "f", "w3_a")
	var sw := sqrt(a * pow(zr, 2.0 / 3) * pow(maxf(1.0 - b * zr, 0.0), 2.0))
	var w3 := c3 * zr * pow(1.0 - zr, 2.0)
	var s := w3 / maxf(sw * sw * sw, 1e-12)
	var au := 0.5 * (1.0 - s / sqrt(s * s + 4))
	return {sigma_w = sw, w3 = w3, skew = s, a_up = au, w_up = sw * sqrt((1.0 - au) / au)}


## Профиль подобия на десяти долях z/z_i (0,05 … 0,95) — статистика F для игры и проверок.
static func convection_profile(cfg: Dictionary) -> Array:
	var out := []
	for q in 10:
		var zr := (q + 0.5) / 10
		var u := updraft(cfg, zr)
		u.zr = zr
		out.append(u)
	return out
