class_name AirPhaseCpu
extends RefCounted
## Фазы поля на CPU (P10, запасной путь без GPU): тот же код, что ядра air_phase.glsl, построчно,
## в float64. Подготовка по столбцам — AirPhase.prepare (общая с GPU). Можно звать из рабочего
## потока (cfg — передать снаружи: AirPhase.config() читает автозагрузку Config).
##
##   var r := AirPhaseCpu.run(case, AirPhase.config())   # словарь P10 (см. AirPhase.result)
##
## Шаги (AP-18 section.md «Порядок шагов»): классификатор → сглаживание весов → G и маска →
## синтез A (DCT) → слои Лапласа D → U слоя перемешивания → баланс θ′ (F) → сборка по клеткам
## (тёплый старт, раскладка AirPicardJob.warm с ореолом) → грани MAC.

const P := preload("res://scripts/atmosphere/air_model/air_phase.gd")


static func run(case: AirCase, cfg: Dictionary = {}) -> Dictionary:
	if cfg.is_empty():
		cfg = AirPhase.config()
	var parts := {}
	var t := Time.get_ticks_usec()
	var p := AirPhase.prepare(case, cfg)
	if p.has("error"):
		return {error = p.error}
	parts.prepare = (Time.get_ticks_usec() - t) / 1000
	return run_prepared(p, parts)


static func run_prepared(p: Dictionary, parts := {}) -> Dictionary:
	var t := Time.get_ticks_usec()
	var fin := []
	var frz := []
	for v in 2:
		fin.append(smooth(p, classify(p, v)))
		frz.append(finalize(p, v, fin[v]))
	parts.classify = _lap(t)
	t = Time.get_ticks_usec()
	var aslab := synth(p)
	parts.synth_a = _lap(t)
	t = Time.get_ticks_usec()
	var lap := laplace(p)
	parts.laplace_d = _lap(t)
	t = Time.get_ticks_usec()
	var th := PackedFloat64Array()
	th.resize(p.n2)
	if p.heated:
		th = theta(p, uml(p, fin[P.V_H], aslab, lap))
	parts.theta_f = _lap(t)
	t = Time.get_ticks_usec()
	var outv := []
	var bad := [false]
	for v in 2:
		outv.append(faces(p, fill(p, v, fin[v], aslab, lap, th, bad), bad))
	parts.fill = _lap(t)
	var wf := []
	for v in 2:
		wf.append(AirCase.to_f32(fin[v]))
	return AirPhase.result(p, wf, frz, outv, parts, bad[0])


static func _lap(t: int) -> float:
	return (Time.get_ticks_usec() - t) / 1000


# ---------------------------------------------------------------- классификатор


## Сырые веса (K·n²) варианта v — P15 (classifier_ref.classify): H, D (ниже H_c по клеткам), C (волны
## по U_sat·|e·∇h_s|), A — остальное; B — огибающая срыва; F — по −z_i/L; G — сток (air_phase.glsl:classify).
static func classify(p: Dictionary, v: int) -> PackedFloat64Array:
	var a: PackedFloat32Array = p.prm
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var w := PackedFloat64Array()
	w.resize(P.K * n2)
	var heated := v == P.V_H and a[P.P_HEATED] > 0.0
	var gact := v == P.V_H and a[P.P_GACT] > 0.0
	var ust: float = a[P.P_USTAR]
	for c in n2:
		var hc := col[P.CI_HC * n2 + c]
		var wh: float = a[P.P_WH]
		var wd: float = a[P.P_WD]
		if a[P.P_D_LOCAL] > 0.0:
			wd *= P.smooth01(0.0, a[P.P_D_RAMP], a[P.P_HCD] - hc)
		var wc := 0.0
		if a[P.P_C_WMS] > 0.0:
			var x := maxf(a[P.P_USAT] * col[P.CI_SAL * n2 + c], 1e-6)
			wc = (1.0 - wh) * (1.0 - wd) * P.sig_log(x, a[P.P_C_WMS], a[P.P_C_WDEC])
		var wa := maxf(1.0 - wh - wd - wc, 0.0)
		var sl := P.smooth01(0.0, a[P.P_LEE_DEPTH], col[P.CI_HEFF * n2 + c] - hc)
		var heat := col[P.CI_HEAT * n2 + c]
		if heated:
			var steep := 1.0 if col[P.CI_S * n2 + c] < a[P.P_LEE_STEEP] else float(a[P.P_LEE_HSK])
			sl *= 1.0 - P.smooth01(a[P.P_LEE_HLO], a[P.P_LEE_HHI], heat) * steep
		var wb := sl
		wa *= 1.0 - sl
		wc *= 1.0 - sl
		wd *= 1.0 - sl
		wh *= 1.0 - sl
		var wfc := 0.0
		if heated:
			var hk := col[P.CI_HK * n2 + c]
			if ust > 0.0:
				var zil: float = (
					col[P.CI_HBL * n2 + c] * a[P.P_KAPPA] * a[P.P_GRAV] * maxf(hk, 0.0)
					/ (a[P.P_THETA0] * ust * ust * ust)
				)
				wfc = P.sig_log(maxf(zil, 1e-6), a[P.P_ZIL_C], a[P.P_W_EF]) if hk > 0.0 else 0.0
			else:
				wfc = 1.0 if heat > 0.0 else 0.0
		var wg := col[P.CI_GW * n2 + c] if gact else 0.0
		var r := (1.0 - wfc) * (1.0 - wg)
		w[P.PH_A * n2 + c] = wa * r
		w[P.PH_B * n2 + c] = wb * r
		w[P.PH_C * n2 + c] = wc * r
		w[P.PH_D * n2 + c] = wd * r
		w[P.PH_F * n2 + c] = wfc * (1.0 - wg)
		w[P.PH_G * n2 + c] = wg
		w[P.PH_H * n2 + c] = wh * r
	return w


## Сглаживание гауссом σ = smooth_cells (раздельно, отражение) и нормировка Σ = 1 (air_phase.glsl:smooth).
static func smooth(p: Dictionary, raw: PackedFloat64Array) -> PackedFloat64Array:
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var gk: PackedFloat64Array = p.gk
	var r := gk.size() / 2
	var tmp := PackedFloat64Array()
	tmp.resize(raw.size())
	for k in P.K:
		for j in ny:
			for i in nx:
				var s := 0.0
				for q in range(-r, r + 1):
					s += gk[q + r] * raw[k * n2 + j * nx + P.refl(i + q, nx)]
				tmp[k * n2 + j * nx + i] = s
	var out := PackedFloat64Array()
	out.resize(raw.size())
	for j in ny:
		for i in nx:
			var c := j * nx + i
			var tot := 0.0
			for k in P.K:
				var s := 0.0
				for q in range(-r, r + 1):
					s += gk[q + r] * tmp[k * n2 + P.refl(j + q, ny) * nx + i]
				s = maxf(s, 0.0)
				out[k * n2 + c] = s
				tot += s
			for k in P.K:
				out[k * n2 + c] /= maxf(tot, 1e-12)
	return out


## Маска заморозки по итоговым весам (air_phase.glsl:final): вся область — H + сильное D ≥ freeze_w;
## вариант h — ещё F ≥ freeze_w при w* ≥ k·U_sat и G ≥ freeze_w.
static func finalize(p: Dictionary, v: int, fin: PackedFloat64Array) -> PackedByteArray:
	var a: PackedFloat32Array = p.prm
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var frz := PackedByteArray()
	frz.resize(n2)
	var fw: float = a[P.P_FRZ_W]
	var full := a[P.P_FULL] > 0.0
	for c in n2:
		var f := full
		if v == P.V_H:
			var ff: bool = fin[P.PH_F * n2 + c] >= fw and col[P.CI_WST * n2 + c] >= a[P.P_WS_OVER_U] * a[P.P_USAT]
			f = f or ff or fin[P.PH_G * n2 + c] >= fw
		frz[c] = 1 if f else 0
	return frz


# ---------------------------------------------------------------- A: синтез линейной теории


## Возмущения A (δu, δv, δw, η) на высотах agl_levels_m над T: nlev·4·n² (air_phase.glsl:synth0..2).
static func synth(p: Dictionary) -> PackedFloat64Array:
	var a: PackedFloat32Array = p.prm
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var lev: PackedFloat64Array = p.lev
	var nlev := lev.size()
	var md: PackedFloat64Array = p.modes
	var tab := _tables(nx, ny)
	var cx: PackedFloat64Array = tab[0]
	var sx: PackedFloat64Array = tab[1]
	var cy: PackedFloat64Array = tab[2]
	var sy: PackedFloat64Array = tab[3]
	var out := PackedFloat64Array()
	out.resize(nlev * P.NCOMP * n2)
	var x := PackedFloat64Array()
	x.resize(P.NCOMP * 4 * n2)
	for l in nlev:
		var z := lev[l]
		x.fill(0.0)
		for c in n2:
			var t := mode_terms(p, a, md, c, z)
			for q in t.size():
				x[q * n2 + c] = t[q]
		for comp in P.NCOMP:
			var x1 := comp * 4 * n2
			var pp := PackedFloat64Array()
			var qq := PackedFloat64Array()
			pp.resize(n2)
			qq.resize(n2)
			for q in ny:
				for i in nx:
					var sp := 0.0
					var sq := 0.0
					for k in nx:
						var cc := cx[i * nx + k]
						var ss := sx[i * nx + k]
						var o := q * nx + k
						sp += x[x1 + o] * cc - x[x1 + n2 + o] * ss
						sq += x[x1 + 2 * n2 + o] * cc + x[x1 + 3 * n2 + o] * ss
					pp[q * nx + i] = sp
					qq[q * nx + i] = sq
			var base := (l * P.NCOMP + comp) * n2
			for j in ny:
				for i in nx:
					var s := 0.0
					for q in ny:
						s += cy[j * ny + q] * pp[q * nx + i] - sy[j * ny + q] * qq[q * nx + i]
					out[base + j * nx + i] = s
	return out


## Таблицы cos/sin(π·p·(i + ½)/n) по x и y.
static func _tables(nx: int, ny: int) -> Array:
	var out := []
	for n in [nx, ny]:
		var c := PackedFloat64Array()
		var s := PackedFloat64Array()
		c.resize(n * n)
		s.resize(n * n)
		for i in n:
			for k in n:
				c[i * n + k] = P.cosb(n, i, k)
				s[i * n + k] = P.sinb(n, i, k)
		out.append(c)
		out.append(s)
	return out


## Для моды c на высоте z: X = (Re Tee, Im Toe, Im Teo, Re Too)·amp по компонентам δu, δv, δw, η
## (16 чисел: [компонента·4 + часть]). Передаточные функции [JH75, Sm80] — AP-17 linear_a:
## ŵ = iσ·e^{imz_eff}, (û, v̂) = −(k, l)·m·ŵ/|K|²·inner, w — e^{imz} на самой высоте, η = e^{imz}.
static func mode_terms(p: Dictionary, a: PackedFloat32Array, md: PackedFloat64Array, c: int, z: float) -> PackedFloat64Array:
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var t := PackedFloat64Array()
	t.resize(16)
	if c == 0:
		return t
	var amp := md[P.MO_AMP * n2 + c]
	var ell := md[P.MO_ELL * n2 + c]
	var pp := c % nx
	var q := c / nx
	var kx0 := PI * pp / (nx * a[P.P_DX])
	var ky0 := PI * q / (ny * a[P.P_DX])
	var k2 := kx0 * kx0 + ky0 * ky0
	var zeff := maxf(z, ell)
	var inner := 1.0
	if z < ell:
		inner = minf(AirPhase.u_prof(p, z) / maxf(AirPhase.u_prof(p, ell), 1e-6), 1.0)
	for s in 4:
		var sg: Vector2i = P.SIGNS[s]
		var sr := md[(P.MO_S0 + 3 * s) * n2 + c]
		var mr := md[(P.MO_S0 + 3 * s + 1) * n2 + c]
		var mi := md[(P.MO_S0 + 3 * s + 2) * n2 + c]
		var kx := sg.x * kx0
		var ly := sg.y * ky0
		var ea := exp(-mi * zeff)
		var ezr := ea * cos(mr * zeff)
		var ezi := ea * sin(mr * zeff)
		# ŵ = iσ·e^{imz_eff}
		var wr := -sr * ezi
		var wi := sr * ezr
		# m·ŵ
		var mwr := mr * wr - mi * wi
		var mwi := mr * wi + mi * wr
		var f := inner / k2
		var ur := -kx * mwr * f
		var ui := -kx * mwi * f
		var vr := -ly * mwr * f
		var vi := -ly * mwi * f
		var eb := exp(-mi * z)
		var e2r := eb * cos(mr * z)
		var e2i := eb * sin(mr * z)
		var vals := [ur, ui, vr, vi, -sr * e2i, sr * e2r, e2r, e2i]
		var s_oe := float(sg.x)
		var s_eo := float(sg.y)
		var s_oo := float(sg.x * sg.y)
		for comp in 4:
			var re: float = vals[2 * comp]
			var im: float = vals[2 * comp + 1]
			# четверть суммы по знакам — чётная/нечётная части (AP-17 _synth)
			t[comp * 4] += re * amp / 4
			t[comp * 4 + 1] += s_oe * im * amp / 4
			t[comp * 4 + 2] += s_eo * im * amp / 4
			t[comp * 4 + 3] += s_oo * re * amp / 4
	return t


# ---------------------------------------------------------------- D: слои Лапласа


## Потенциальное обтекание стенок в слоях z_L (AP-17 layer_potential): красно-чёрная верхняя
## релаксация sor_iters раз, затем скорости в долях набегающей (gx, gy). → nL·3·n² (φ, gx, gy).
static func laplace(p: Dictionary) -> PackedFloat64Array:
	var a: PackedFloat32Array = p.prm
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var nl: int = p.zl.size()
	var col: PackedFloat64Array = p.col
	var out := PackedFloat64Array()
	out.resize(maxi(nl, 1) * 3 * n2)
	if nl == 0:
		return out
	var ex: float = a[P.P_EX]
	var ey: float = a[P.P_EY]
	var om: float = a[P.P_SOR_OMEGA]
	var iters := int(P.cv(p.cfg, "d", "sor_iters"))
	for l in nl:
		var zl: float = a[P.P_ZL0 + l]
		var fl := PackedByteArray()
		fl.resize(n2)
		var o := l * 3 * n2
		for c in n2:
			fl[c] = 1 if col[P.CI_HC * n2 + c] <= zl else 0
			out[o + c] = ex * (c % nx + 0.5) + ey * (c / nx + 0.5)
		for _it in iters:
			for par in 2:
				for j in range(1, ny - 1):
					for i in range(1, nx - 1):
						if (i + j) % 2 != par:
							continue
						var c := j * nx + i
						if fl[c] == 0:
							continue
						var s := 0.0
						var cnt := 0
						for nb in [c - 1, c + 1, c - nx, c + nx]:
							if fl[nb] == 1:
								s += out[o + nb]
								cnt += 1
						if cnt > 0:
							out[o + c] = (1.0 - om) * out[o + c] + om * s / cnt
		for j in ny:
			for i in nx:
				var c := j * nx + i
				var g := _face_grad(out, o, fl, nx, ny, i, j, ex, ey)
				out[o + n2 + c] = g.x
				out[o + 2 * n2 + c] = g.y
	return out


## Скорость клетки по граням (среднее двух граней; грани к стенке 0; край области — e).
static func _face_grad(
	phi: PackedFloat64Array, o: int, fl: PackedByteArray, nx: int, ny: int, i: int, j: int, ex: float, ey: float
) -> Vector2:
	var c := j * nx + i
	if fl[c] == 0:
		return Vector2.ZERO
	var fxl := ex if i == 0 else (phi[o + c] - phi[o + c - 1] if fl[c - 1] == 1 else 0.0)
	var fxr := ex if i == nx - 1 else (phi[o + c + 1] - phi[o + c] if fl[c + 1] == 1 else 0.0)
	var fyl := ey if j == 0 else (phi[o + c] - phi[o + c - nx] if fl[c - nx] == 1 else 0.0)
	var fyr := ey if j == ny - 1 else (phi[o + c + nx] - phi[o + c] if fl[c + nx] == 1 else 0.0)
	return Vector2(0.5 * (fxl + fxr), 0.5 * (fyl + fyr))


# ---------------------------------------------------------------- поле механизмов в точке


## Значение слоя A (компонента comp) на высоте zt над T: линейно между высотами; ниже первой —
## закон стенки (горизонталь) или линейно к 0 (w, η); выше последней — верхнее. Горизонталь —
## с ограничением |δu_h| ≤ cap·U(z) по уровню (AP-17 linear_a cap_frac).
static func slab_at(p: Dictionary, a: PackedFloat32Array, sl: PackedFloat64Array, c: int, zt: float) -> PackedFloat64Array:
	var n2: int = p.n2
	var nlev: int = int(a[P.P_NLEV])
	var l0: float = a[P.P_LEV0]
	var zc := clampf(zt, l0, a[P.P_LEV0 + nlev - 1])
	var k := 0
	while k < nlev - 2 and a[P.P_LEV0 + k + 1] <= zc:
		k += 1
	var t: float = (zc - a[P.P_LEV0 + k]) / (a[P.P_LEV0 + k + 1] - a[P.P_LEV0 + k])
	var r := PackedFloat64Array()
	r.resize(P.NCOMP)
	for side in 2:
		var l := k + side
		var wt := t if side == 1 else 1.0 - t
		var du := sl[(l * P.NCOMP) * n2 + c]
		var dv := sl[(l * P.NCOMP + 1) * n2 + c]
		var mag := sqrt(du * du + dv * dv)
		var lim: float = a[P.P_CAP] * AirPhase.u_prof(p, a[P.P_LEV0 + l])
		var fac := lim / maxf(mag, 1e-9) if mag > lim else 1.0
		r[0] += wt * du * fac
		r[1] += wt * dv * fac
		r[2] += wt * sl[(l * P.NCOMP + 2) * n2 + c]
		r[3] += wt * sl[(l * P.NCOMP + 3) * n2 + c]
	if zt < l0:
		var z0: float = a[P.P_Z0]
		var fh := log(maxf(zt, 2 * z0) / z0) / log(l0 / z0)
		var fw := clampf(zt / l0, 0.0, 1.0)
		r[0] *= fh
		r[1] *= fh
		r[2] *= fw
		r[3] *= fw
	return r


## Поля механизмов в точке (столбец c, высота zmsl над морем): A (u, v, w), η, B (u, v, w),
## D (u, v, w) — 10 чисел (air_phase.glsl: mech).
static func mech(
	p: Dictionary, a: PackedFloat32Array, sl: PackedFloat64Array, lap: PackedFloat64Array, c: int, zmsl: float
) -> PackedFloat64Array:
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var hc := col[P.CI_HC * n2 + c]
	var zagl := zmsl - hc
	var zt := zmsl - col[P.CI_T * n2 + c]
	var ex: float = a[P.P_EX]
	var ey: float = a[P.P_EY]
	var s := slab_at(p, a, sl, c, zt)
	var ub := AirPhase.u_prof(p, zt)
	var r := PackedFloat64Array()
	r.resize(10)
	r[0] = ub * ex + s[0]
	r[1] = ub * ey + s[1]
	r[2] = s[2]
	r[3] = s[3]
	r[4] = r[0]
	r[5] = r[1]
	r[6] = r[2]
	var depth := col[P.CI_HEFF * n2 + c] - hc
	if depth > 0.0 and zagl < depth:
		var s0 := slab_at(p, a, sl, c, a[P.P_LEV0])
		var u0 := AirPhase.u_prof(p, a[P.P_LEV0])
		var utop := Vector2(u0 * ex + s0[0], u0 * ey + s0[1]).length()
		var tt := clampf(zagl / depth, 0.0, 1.0)
		var rv: float = a[P.P_BUB_R]
		var ubub := utop * (-rv + (1.0 + rv) * tt * tt)
		r[4] = ubub * ex
		r[5] = ubub * ey
		r[6] = 0.0
	r[7] = r[0]
	r[8] = r[1]
	r[9] = r[2]
	var nl := int(a[P.P_NL])
	if nl > 0 and zmsl < a[P.P_HCD]:
		var q := -1
		for l in nl:
			if a[P.P_ZL0 + l] < zmsl:
				q = l
		q = clampi(q, 0, nl - 1)
		var q2 := mini(q + 1, nl - 1)
		var den := maxf(a[P.P_ZL0 + q2] - a[P.P_ZL0 + q], 1e-6)
		var tq := clampf((zmsl - a[P.P_ZL0 + q]) / den, 0.0, 1.0)
		var gx := (1.0 - tq) * lap[(q * 3 + 1) * n2 + c] + tq * lap[(q2 * 3 + 1) * n2 + c]
		var gy := (1.0 - tq) * lap[(q * 3 + 2) * n2 + c] + tq * lap[(q2 * 3 + 2) * n2 + c]
		var ua := AirPhase.u_prof(p, zagl)
		r[7] = gx * ua
		r[8] = gy * ua
		r[9] = 0.0
	return r


## Нормированная смесь механического поля по весам (A, C → A; D, H → D; B → B; F, G — отдельно).
static func mix(w: PackedFloat64Array, n2: int, c: int, m: PackedFloat64Array) -> Vector3:
	var wa := w[P.PH_A * n2 + c] + w[P.PH_C * n2 + c]
	var wd := w[P.PH_D * n2 + c] + w[P.PH_H * n2 + c]
	var wb := w[P.PH_B * n2 + c]
	var sm := maxf(wa + wb + wd, 1e-12)
	return Vector3(
		(wa * m[0] + wb * m[4] + wd * m[7]) / sm,
		(wa * m[1] + wb * m[5] + wd * m[8]) / sm,
		(wa * m[2] + wb * m[6] + wd * m[9]) / sm
	)


# ---------------------------------------------------------------- F: баланс θ′


## Скорость слоя перемешивания: средняя |u_h| смеси на первых uml_levels высотах (air_phase.glsl:uml).
static func uml(p: Dictionary, w: PackedFloat64Array, sl: PackedFloat64Array, lap: PackedFloat64Array) -> PackedFloat64Array:
	var a: PackedFloat32Array = p.prm
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var nu := int(a[P.P_UML_N])
	var out := PackedFloat64Array()
	out.resize(n2)
	for c in n2:
		var s := 0.0
		for l in nu:
			var m := mech(p, a, sl, lap, c, col[P.CI_HC * n2 + c] + a[P.P_LEV0 + l])
			var u := mix(w, n2, c, m)
			s += sqrt(u.x * u.x + u.y * u.y)
		out[c] = maxf(s / maxi(nu, 1), a[P.P_UML_MIN])
	return out


## θ′ слоя перемешивания — стационарный баланс вдоль ветра (AP-17 theta_march), проходы Якоби
## nx + ny раз (цепочка вверх по ветру выходит из области — точное решение) (air_phase.glsl:theta).
static func theta(p: Dictionary, um: PackedFloat64Array) -> PackedFloat64Array:
	var a: PackedFloat32Array = p.prm
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var ex: float = a[P.P_EX]
	var ey: float = a[P.P_EY]
	var tau: float = a[P.P_TAU]
	var fa := PackedFloat64Array()
	var src := PackedFloat64Array()
	fa.resize(n2)
	src.resize(n2)
	for c in n2:
		var dt: float = a[P.P_DX] / um[c]
		fa[c] = exp(-dt / tau)
		src[c] = col[P.CI_HK * n2 + c] / maxf(col[P.CI_HBL * n2 + c], 1.0) * tau * (1.0 - fa[c])
	var th := src.duplicate()
	for _pass in nx + ny:
		var nw := PackedFloat64Array()
		nw.resize(n2)
		for j in ny:
			for i in nx:
				var c := j * nx + i
				var fi := i - ex
				var fj := j - ey
				var v := 0.0
				if fi >= 0.0 and fi <= nx - 1 and fj >= 0.0 and fj <= ny - 1:
					var i0 := clampi(floori(fi), 0, nx - 2)
					var j0 := clampi(floori(fj), 0, ny - 2)
					var aa := fi - i0
					var bb := fj - j0
					v = (
						(1 - bb) * ((1 - aa) * th[j0 * nx + i0] + aa * th[j0 * nx + i0 + 1])
						+ bb * ((1 - aa) * th[(j0 + 1) * nx + i0] + aa * th[(j0 + 1) * nx + i0 + 1])
					)
				nw[c] = v * fa[c] + src[c]
		th = nw
	return th


# ---------------------------------------------------------------- сборка по клеткам


## Центры клеток (u, v, w, θ′; 4·N, раскладка с ореолом) варианта v (air_phase.glsl:fill).
static func fill(
	p: Dictionary,
	v: int,
	w: PackedFloat64Array,
	sl: PackedFloat64Array,
	lap: PackedFloat64Array,
	th: PackedFloat64Array,
	bad: Array
) -> PackedFloat64Array:
	var a: PackedFloat32Array = p.prm
	var nx: int = p.nx
	var ny: int = p.ny
	var n2: int = p.n2
	var big_nx: int = p.NX
	var big_ny: int = p.NY
	var big_nz: int = p.NZ
	var n: int = p.N
	var col: PackedFloat64Array = p.col
	var out := PackedFloat64Array()
	out.resize(4 * n)
	var heated := v == P.V_H and a[P.P_HEATED] > 0.0
	var gact := v == P.V_H and a[P.P_GACT] > 0.0
	for jh in big_ny:
		var j := clampi(jh - 1, 0, ny - 1)
		for ih in big_nx:
			var i := clampi(ih - 1, 0, nx - 1)
			var c := j * nx + i
			var hc := col[P.CI_HC * n2 + c]
			for k in range(1, big_nz):
				var zmsl: float = a[P.P_ZBOT] + (k - 0.5) * a[P.P_DZ]
				if zmsl < hc:
					continue
				var r := cell(p, a, v, w, sl, lap, th, c, zmsl, heated, gact)
				var idx := (k * big_ny + jh) * big_nx + ih
				for q in 4:
					var x := r[q]
					if not is_finite(x):
						x = 0.0
						bad[0] = true
					out[q * n + idx] = x
	return out


## Одна клетка: смесь механизмов + анабатика (F) + θ′ (F, волны) + сток G (AP-17 assemble,
## AP-18 blend_g). → (u, v, w, θ′).
static func cell(
	p: Dictionary,
	a: PackedFloat32Array,
	_v: int,
	w: PackedFloat64Array,
	sl: PackedFloat64Array,
	lap: PackedFloat64Array,
	th: PackedFloat64Array,
	c: int,
	zmsl: float,
	heated: bool,
	gact: bool
) -> PackedFloat64Array:
	var n2: int = p.n2
	var col: PackedFloat64Array = p.col
	var hc := col[P.CI_HC * n2 + c]
	var zagl := zmsl - hc
	var m := mech(p, a, sl, lap, c, zmsl)
	var mn := mix(w, n2, c, m)
	var u := mn.x
	var vv := mn.y
	var t := 0.0
	if heated:
		# доля F среди «не G» (итоговые веса включают G)
		var wf := w[P.PH_F * n2 + c] / maxf(1.0 - w[P.PH_G * n2 + c], 1e-12)
		# анабатика (AP-17 anabatic): u_a = (B_s·L·sin α)^(1/3) вверх по склону, слой δ у земли
		var s := col[P.CI_S * n2 + c]
		var sina := s / sqrt(1.0 + s * s)
		var bs: float = a[P.P_GRAV] / a[P.P_THETA0] * maxf(col[P.CI_HK * n2 + c], 0.0)
		var ua := pow(bs * a[P.P_SLOPE_LEN] * sina, 1.0 / 3)
		var dl := maxf(a[P.P_ANA_DMIN], a[P.P_ANA_DFRAC] * col[P.CI_HBL * n2 + c])
		var pr := exp(-zagl / dl)
		var ds := maxf(s, 1e-9)
		u += wf * ua * col[P.CI_GX * n2 + c] / ds * pr
		vv += wf * ua * col[P.CI_GY * n2 + c] / ds * pr
		if zagl < col[P.CI_HBL * n2 + c]:
			t = th[c]
		if zmsl >= a[P.P_HCD]:
			var gw: float = a[P.P_GAMW] if zmsl > a[P.P_ZI] else 0.0
			t -= gw * m[3]
	if gact:
		var wg := w[P.PH_G * n2 + c]
		var layer := col[P.CI_GLAY * n2 + c] > 0.5
		var l := col[P.CI_GL * n2 + c]
		var d := col[P.CI_GD * n2 + c]
		var top: float = d if layer else a[P.P_G_TOPL] * l
		var tm := clampf((zagl - top) / (a[P.P_G_MEMB] * maxf(top, 1.0)), 0.0, 1.0)
		var member := 1.0 - tm * tm * (3 - 2 * tm)
		var sp := 0.0
		var thg := 0.0
		if layer:
			sp = col[P.CI_GUC * n2 + c]
			thg = -a[P.P_GDTHC] * clampf(1.0 - zagl / maxf(d, 1.0), 0.0, 1.0)
		else:
			var xn := zagl / l
			sp = col[P.CI_GUS * n2 + c] * exp(-xn) * sin(xn)
			thg = -col[P.CI_GDTH * n2 + c] * exp(-xn) * cos(xn) * col[P.CI_GON * n2 + c]
		var al := wg * member
		u = (1.0 - al) * u + al * sp * col[P.CI_GDX * n2 + c] * member
		vv = (1.0 - al) * vv + al * sp * col[P.CI_GDY * n2 + c] * member
		t += wg * thg * member
	return PackedFloat64Array([u, vv, mn.z, t])


## Грани MAC из центров (air_phase.glsl:faces): u — западная грань (среднее двух клеток воздуха,
## у земли 0, i = 0 — сама клетка), v — южная, w — нижняя (k = 0 и у земли — 0), θ′ — центр.
static func faces(p: Dictionary, ctr: PackedFloat64Array, _bad: Array) -> PackedFloat32Array:
	var big_nx: int = p.NX
	var big_ny: int = p.NY
	var big_nz: int = p.NZ
	var n: int = p.N
	var nyx := big_nx * big_ny
	var air := PackedByteArray()
	air.resize(n)
	var col: PackedFloat64Array = p.col
	var a: PackedFloat32Array = p.prm
	for jh in big_ny:
		var j := clampi(jh - 1, 0, int(p.ny) - 1)
		for ih in big_nx:
			var i := clampi(ih - 1, 0, int(p.nx) - 1)
			var hc := col[P.CI_HC * p.n2 + j * int(p.nx) + i]
			for k in range(1, big_nz):
				if a[P.P_ZBOT] + (k - 0.5) * a[P.P_DZ] >= hc:
					air[(k * big_ny + jh) * big_nx + ih] = 1
	var out := PackedFloat32Array()
	out.resize(4 * n)
	for idx in n:
		if air[idx] == 0:
			continue
		var ih := idx % big_nx
		var jh := (idx / big_nx) % big_ny
		var k := idx / nyx
		var fu := ctr[idx]
		if ih > 0:
			fu = 0.5 * (ctr[idx - 1] + ctr[idx]) if air[idx - 1] == 1 else 0.0
		var fv := ctr[n + idx]
		if jh > 0:
			fv = 0.5 * (ctr[n + idx - big_nx] + ctr[n + idx]) if air[idx - big_nx] == 1 else 0.0
		var fw := 0.0
		if k > 0 and air[idx - nyx] == 1:
			fw = 0.5 * (ctr[2 * n + idx - nyx] + ctr[2 * n + idx])
		out[idx] = fu
		out[n + idx] = fv
		out[2 * n + idx] = fw
		out[3 * n + idx] = ctr[3 * n + idx]
	return out


# ---------------------------------------------------------------- поле для игры без Пикара (P12 v3)


## Полное поле сборки по фазам без Пикара (путь без GPU, P12 v3): все клетки — механизмы
## (A — линейная теория, B, C → A, D, H, F, G); u, v, θ′ — решение с нагревом, w_mech — без нагрева
## (C3). r — результат run() того же случая (пусто — посчитать). null — размеры не сошлись.
static func field(case: AirCase, r := {}, max_speed := 40.0, max_w := 10.0, cfg := {}) -> WindField:
	if r.is_empty():
		r = run(case, cfg)
	if r.has("error"):
		return null
	return field_from(case, r, max_speed, max_w)


## WindField (C3) из словаря P10 (CPU или GPU — раскладка одна).
static func field_from(case: AirCase, r: Dictionary, max_speed := 40.0, max_w := 10.0) -> WindField:
	var d := case.dims()
	var cell := PackedFloat32Array()
	cell.resize(d.x * d.y * d.z)
	for k in range(1, d.z):
		var z := case.zc(k)
		for jh in d.y:
			var j := clampi(jh - 1, 0, case.ny - 1)
			for ih in d.x:
				var i := clampi(ih - 1, 0, case.nx - 1)
				if z >= case.hc[j * case.nx + i]:
					cell[(k * d.y + jh) * d.x + ih] = 1.0
	var wh: Dictionary = r.warm
	var wm: Dictionary = r.warm_mech
	var f := WindField.from_mac(case.meta(), wh.u, wh.v, wh.w, wm.w, wh.th, cell, AirCase.to_f32(case.hc))
	if f != null:
		f.clamp_values(max_speed, max_w)
	return f
