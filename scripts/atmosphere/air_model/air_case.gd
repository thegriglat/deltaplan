class_name AirCase
extends RefCounted
## Вход одного решения Пикара (масштаб 1, AM-03): сетка, рельеф, фон θ̄(z), поток тепла, ветер.
## Готовит то, что GPU-решателю (AirPicardJob) нужно по столбцам и уровням: всё поклеточное
## (типы клеток и граней, фон ветра, губки, K_b, нагрев, проводимости проекции) ядро
## air_picard.glsl:setup считает на GPU из этих массивов — O(nx_h·ny_h + nz_h) на CPU.
## Формулы — tools/research/air3d/air.py (Air.__init__, _closure, _setup_boundary) и
## reference.md → «Дискретизация»; здесь только перенос (в float64 GDScript).
##
## Раскладка решателя: (nz_h, ny_h, nx_h) = (nz + 2, ny + 2, nx + 2) с ореолом, индекс
## (k·ny_h + j)·nx_h + i; i — восток, j — север (y = −Z мира), k — вверх. Центр клетки:
## x0 + (i − ½)·dx, z_bot + (k − ½)·dz.
##
##   var c := AirCase.new()
##   c.set_grid(dx, nx, ny, dz, z_bot, nz, x0, y0)
##   c.hc = …      # ny·nx, м над морем (блочное среднее рельефа по клетке)
##   c.gam = …     # nz_h, dθ̄/dz в центрах клеток, К/м
##   c.z_i = …     # верх слоя перемешивания над морем, м (NAN — нет конвекции)
##   c.heat = …    # ny·nx, поток тепла, Вт/м² (пусто — 0)
##   c.u10 = 3.0; c.wdir = 150.0
##   c.prepare()   # до передачи в AirPicardJob

const G := 9.81
const THETA0 := 300.0
const RHO_CP := 1.2 * 1005.0
const KAPPA := 0.4
const NCOL := 14
## Плоскости col (air_picard.glsl: C_CD, C_UST): C_d стенки и u* замыкания по столбцу (SH-6, C2 v9).
const COL_CD := 12
const COL_UST := 13
const NLEV := 5

## λ/h — асимптотическая длина перемешивания как доля толщины слоя, λ = max(p.lam, LAM_FRAC·h):
## совместная калибровка Б1 (Askervein + Perdigão, docs/archive/plan/air-model-b1.md), перевод (б)
## решения К2: общий λ ≈ 27 м при h_нейтр 1713 м → 0,0158, пол lam 40 м; одинаково с air.py
## (Params.lam_frac).
## Один источник для решателя (p.lam_frac) и масштаба 3 (FieldTurbulence).
const LAM_FRAC := 0.0158
## Толщина нейтрального слоя h = NEUTRAL_BL_K·u*/f, как air.py (_closure). Литература: 0,2–0,25
## (Blackadar & Tennekes 1968; Tennekes 1973), 0,07–0,5 у разных авторов, ≈ 0,6 для «истинно
## нейтрального» слоя (Zilitinkevich et al. 2007); λ/h подогнан при 0,3 — данные Askervein задают
## произведение LAM_FRAC·NEUTRAL_BL_K (docs/research/air-model-tune.md → AM-09б). Один источник для
## решателя и масштаба 3.
const NEUTRAL_BL_K := 0.3
## Параметр Кориолиса 51° с. ш., 1/с (air.py Params.f_cor) — только для толщины слоя h.
const F_COR := 1.13e-4
## Шероховатость без снимка поверхности, м (air.py Params.z0; луг/кустарник) — решатель без карты z0
## и профиль WindModel. Со снимком поверхности z0 по столбцу — z0_map (SH-6, C2 v9).
const Z0 := 0.1
## Слоты prm (air_picard.glsl): 1 — окно клипмапа (AirWindowCase), 1/Pr_t шаблона тепла.
const P_NEST := 19
const P_IPRT := 20

## Параметры модели (air.py → Params; числа — физические или численные, см. там).
var p := {
	tau_cool = 7200.0,
	# турбулентное число Прандтля, K_θ = K/Pr_t (все три оси); 0,85 — Kays 1994, решение пользователя
	# 30.09.2026 (варианты 1,0/0,74/0,95 — docs/archive/plan/air-model-a1.md §1)
	pr_t = 0.85,
	z0 = Z0,
	# профиль притока (C2 v4): у случая — WindProfile.apply_to_case (α по устойчивости на час);
	# по умолчанию α_N (нейтраль), max_profile NAN — по правилу z_sat при prepare()
	alpha = 0.24,
	max_profile = NAN,
	f_cor = F_COR,
	k_fa = 1.0,
	k_smooth_m = 1500.0,
	zi_min = 300.0,
	heat_cbl = true,
	dtau_u = NAN,
	dtau_per_m = 0.3,
	dtau_th = 1200.0,
	couple = 1.0,
	mom_sweeps = 2,
	heat_sweeps = 4,
	vcycles = 1,
	sponge_top_m = 1000.0,
	sponge_side_m = 2000.0,
	sponge_rate = 1.0 / 300.0,
	heat_taper_m = 2000.0,
	local_k = true,
	lam = 40.0,
	lam_frac = LAM_FRAC,
	k_relax = 0.1,  # А2: 0,5 → 0,1 (docs/archive/plan/air-model-a2.md)
	cs_h = 0.25,
}

var dx := 400.0
var dz := 105.0
var nx := 0
var ny := 0
var nz := 0
var z_bot := 0.0
var x0 := 0.0
var y0 := 0.0
var hc := PackedFloat64Array()
var gam := PackedFloat64Array()
var z_i := NAN
var heat := PackedFloat64Array()
## Шероховатость по столбцам, м (ny·nx, j·nx + i; SH-6, C2 v9): эффективная по долям классов клетки
## (AirPlace.cell_z0, лог-среднее по площади). Пусто — p.z0 во всех столбцах. Задавать set_z0_map:
## p.z0 = лог-среднее карты (эффективный z0 области — приток, α/z_sat, фазы).
var z0_map := PackedFloat64Array()
## Ветер притока на 10 м, м/с (C2 v6: = inflow_k·u10_menu; амплитуда профиля притока, u* замыкания).
var u10 := 0.0
## Ветер меню на 10 м над стартом, м/с (по нему α, класс устойчивости и max_profile случая).
var u10_menu := 0.0
## Множитель притока (AirRuntime: U меню / U поля на 10 м над стартом; 1 — прежний случай).
var inflow_k := 1.0
var wdir := 270.0
## Гасить нагрев у края области (Air(taper=True) эталона; эталоны тестов — без).
var taper := true
## Подпись (для отчётов).
var label := ""

# ---- итог prepare()
var nx_h := 0
var ny_h := 0
var nz_h := 0
var n_fluid := 0
## Число неизвестных: грани u, v, w типа 1, клетки воздуха.
var n_unk := PackedInt32Array([0, 0, 0, 0])
var col := PackedFloat32Array()  # NCOL плоскостей ny_h·nx_h
var lev := PackedFloat32Array()  # NLEV плоскостей nz_h
var prm := PackedFloat32Array()  # air_picard.glsl P_*
var cd := 0.0
var fixed_scale := 1.0
var ustar := 0.0
var u_a := 0.0
var ex := 0.0
var ey := 0.0
var closure_info := {}
## Поток тепла, как его берёт решение (с гашением у края), ny·nx, Вт/м².
var heat_used := PackedFloat64Array()
## Высота слоя перемешивания по внутренним столбцам (ny·nx), м.
var h_bl := PackedFloat64Array()

var _wst := PackedFloat64Array()
var _invl := PackedFloat64Array()
var _unst: Array[bool] = []
## C_d стенки и u* замыкания по столбцам (ny·nx, SH-6).
var _cd_col := PackedFloat64Array()
var _ust_col := PackedFloat64Array()
## Сглаженный рельеф (гаусс k_smooth_m) — общий у случая с нагревом и без (without_heat).
var _hs := PackedFloat64Array()


func set_grid(
	p_dx: float, p_nx: int, p_ny: int, p_dz: float, p_zb: float, p_nz: int, p_x0 := 0.0, p_y0 := 0.0
) -> void:
	dx = p_dx
	nx = p_nx
	ny = p_ny
	dz = p_dz
	z_bot = p_zb
	nz = p_nz
	x0 = p_x0
	y0 = p_y0


## Псевдошаг импульса, с: p.dtau_u или (NAN) dtau_per_m·Δx по уровню (эталон с cf64b7b).
func dtau_u() -> float:
	var v := float(p.dtau_u)
	return v if not is_nan(v) else float(p.dtau_per_m) * dx


## Центр клетки k (с ореолом), м над морем.
func zc(k: int) -> float:
	return z_bot + (k - 0.5) * dz


func dims() -> Vector3i:
	return Vector3i(nx + 2, ny + 2, nz + 2)


## Метаданные поля для WindField (docs/guide/air-model.md → «Поле на CPU») + вход термиков из поля
## (AM-07, air_thermals.gd): heat — поток тепла по столбцам (ny·nx, Вт/м², как в решении, с
## гашением у края), z_i (м над морем; нет — без ключа), gam — dθ̄/dz в центрах nz уровней, u10.
func meta() -> Dictionary:
	var m := {
		dx = dx,
		dz = dz,
		x0 = x0,
		y0 = y0,
		z_bot = z_bot,
		nx = nx,
		ny = ny,
		nz = nz,
		# карта z0 (ny·nx, float32) со снимком поверхности, без неё — число p.z0 (C3 v2)
		z0 = to_f32(z0_map) if z0_map.size() == nx * ny and nx * ny > 0 else float(p.z0),
		z0_eff = float(p.z0),
		label = label,
		u10 = u10,
		u10_menu = u10_menu,
		inflow_k = inflow_k,
		wdir = wdir,
		heat = to_f32(heat_used),
		gam = to_f32(gam.slice(1, nz + 1)),
	}
	if not is_nan(z_i):
		m.z_i = z_i
	return m


## Тот же случай без нагрева (H = 0) — решение для механической вертикали w_mech.
func without_heat() -> AirCase:
	var c := AirCase.new()
	c.p = p.duplicate()
	c.set_grid(dx, nx, ny, dz, z_bot, nz, x0, y0)
	c.hc = hc
	c.z0_map = z0_map
	c.gam = gam
	c.z_i = z_i
	c.u10 = u10
	c.u10_menu = u10_menu
	c.inflow_k = inflow_k
	c.wdir = wdir
	c.taper = taper
	c._hs = _hs
	c.label = label + " без нагрева"
	return c


## Ветер случая (C2 v6): α, класс устойчивости и max_profile — по ветру меню u_menu
## (WindProfile.apply_to_case), приток u10 = k·u_menu (весь профиль притока умножен на k).
## k = 1 — побитно прежний случай.
func set_inflow(u_menu: float, k: float, ctx: Dictionary, hour: float, cover: float) -> void:
	u10_menu = u_menu
	inflow_k = k
	u10 = u_menu
	WindProfile.apply_to_case(self, ctx, hour, cover)
	u10 = k * u_menu


## Карта шероховатости (ny·nx, м; пусто — снять): p.z0 = exp(среднее ln z0) — эффективный z0
## области (П4 §5.4: z0 смеси — логарифмически). Вызывать до set_inflow (α, z_sat — по p.z0).
func set_z0_map(m: PackedFloat64Array) -> void:
	z0_map = m
	if not m.is_empty():
		p.z0 = log_mean(m)


## z0 по столбцам (ny·nx): z0_map или p.z0 везде.
func z0_columns() -> PackedFloat64Array:
	if z0_map.size() == nx * ny and nx * ny > 0:
		return z0_map
	var out := PackedFloat64Array()
	out.resize(nx * ny)
	out.fill(float(p.z0))
	return out


## exp(среднее ln a) — лог-среднее (эффективный z0 смеси); все равны — само значение (побитно).
static func log_mean(a: PackedFloat64Array) -> float:
	var s := 0.0
	var same := true
	for v in a:
		s += log(v)
		same = same and v == a[0]
	return a[0] if same else exp(s / a.size())


## Всё по столбцам и уровням. false — входы не сходятся по размерам.
func prepare() -> bool:
	nx_h = nx + 2
	ny_h = ny + 2
	nz_h = nz + 2
	if nx < 4 or ny < 4 or nz < 2 or hc.size() != nx * ny or gam.size() != nz_h:
		push_error("AirCase: размеры входов не сходятся")
		return false
	if not heat.is_empty() and heat.size() != nx * ny:
		push_error("AirCase: размер потока тепла ≠ nx·ny")
		return false
	if not z0_map.is_empty() and z0_map.size() != nx * ny:
		push_error("AirCase: размер карты z0 ≠ nx·ny")
		return false
	var nyx := nx_h * ny_h
	col = PackedFloat32Array()
	col.resize(NCOL * nyx)
	lev = PackedFloat32Array()
	lev.resize(NLEV * nz_h)
	var hp := PackedFloat64Array()
	hp.resize(nyx)
	for j in ny_h:
		var jj := clampi(j - 1, 0, ny - 1)
		for i in nx_h:
			hp[j * nx_h + i] = hc[jj * nx + clampi(i - 1, 0, nx - 1)]
	# первая клетка воздуха столбца: клетка земля, если z_k < h (и весь слой k = 0)
	var kf := PackedInt32Array()
	kf.resize(nyx)
	for q in nyx:
		var k := clampi(ceili((hp[q] - z_bot) / dz + 0.5), 1, nz_h)
		while k > 1 and zc(k - 1) >= hp[q]:
			k -= 1
		while k < nz_h and zc(k) < hp[q]:
			k += 1
		kf[q] = k
	_count_unknowns(kf)
	# ---- фон: ветер
	var windy := u10 > 0.0
	var mp := max_profile_used()
	u_a = u10 * mp
	var ang := deg_to_rad(wdir)
	ex = -sin(ang) if windy else 0.0
	ey = -cos(ang) if windy else 0.0
	var z_sat := 10.0 * pow(mp, 1.0 / float(p.alpha))
	# ---- губки
	var ztop := z_bot + nz * dz
	var rate := float(p.sponge_rate)
	var side := PackedFloat64Array()
	side.resize(nyx)
	var scs := PackedFloat64Array()
	scs.resize(nyx)
	if windy:
		var side_len := float(p.sponge_side_m)
		var lx := nx * dx
		var ly := ny * dx
		for j in ny_h:
			var yj := (j - 0.5) * dx
			var ry0 := _ramp(yj, side_len, rate)
			var ry1 := _ramp(ly - yj, side_len, rate)
			for i in nx_h:
				var xi := (i - 0.5) * dx
				var rx0 := _ramp(xi, side_len, rate)
				var rx1 := _ramp(lx - xi, side_len, rate)
				var q := j * nx_h + i
				side[q] = maxf(maxf(rx0, rx1), maxf(ry0, ry1))
				var s := 0.0
				if ex > 1e-9:
					s = maxf(s, rx0)
				if ex < -1e-9:
					s = maxf(s, rx1)
				if ey > 1e-9:
					s = maxf(s, ry0)
				if ey < -1e-9:
					s = maxf(s, ry1)
				scs[q] = s
	for k in nz_h:
		var z := zc(k)
		lev[k] = z
		lev[nz_h + k] = gam[k]
		lev[3 * nz_h + k] = _ramp(ztop - z, float(p.sponge_top_m), rate)
		lev[4 * nz_h + k] = _ramp(ztop - (z - 0.5 * dz), float(p.sponge_top_m), rate)
	var dth := float(p.dtau_th)
	# у полного θ′ нет 1/τ в диагонали (τ — только θ′_d, C1 v2): постоянная времени — Δτ_θ
	var s_th := dth
	for k in nz_h:
		var gw := 0.5 * (gam[k] + gam[k - 1]) if k > 0 else 0.0
		lev[2 * nz_h + k] = float(p.couple) * G / THETA0 * maxf(gw, 0.0) * s_th
	# ---- нагрев (Вт/м² → К·м/с), у края области гасится
	var hk := PackedFloat64Array()
	hk.resize(nx * ny)
	var any_heat := false
	var any_pos := false
	if not heat.is_empty():
		var lx2 := nx * dx
		var ly2 := ny * dx
		var tm := float(p.heat_taper_m)
		for j in ny:
			var ye := (j + 0.5) * dx
			var eyy := clampf(minf(ye, ly2 - ye) / tm, 0.0, 1.0)
			for i in nx:
				var v := heat[j * nx + i]
				if taper:
					var xe := (i + 0.5) * dx
					var exx := clampf(minf(xe, lx2 - xe) / tm, 0.0, 1.0)
					var f := sin(0.5 * PI * eyy) * sin(0.5 * PI * exx)
					v *= f * f
				hk[j * nx + i] = v / RHO_CP
				any_heat = any_heat or hk[j * nx + i] != 0.0
				any_pos = any_pos or hk[j * nx + i] > 0.0
	heat_used = PackedFloat64Array()
	heat_used.resize(nx * ny)
	for q in hk.size():
		heat_used[q] = hk[q] * RHO_CP
	_closure(hk, any_heat)
	# ---- столбцы (с ореолом: копия ближайшего внутреннего)
	var lam := float(p.lam)
	var lam_frac := float(p.lam_frac)
	var cbl := bool(p.heat_cbl) and any_pos
	for j in ny_h:
		var jj := clampi(j - 1, 0, ny - 1)
		for i in nx_h:
			var ii := clampi(i - 1, 0, nx - 1)
			var q := j * nx_h + i
			var c := jj * nx + ii
			col[q] = hp[q]
			col[nyx + q] = kf[q]
			col[2 * nyx + q] = h_bl[c]
			col[3 * nyx + q] = _wst[c]
			col[4 * nyx + q] = _invl[c]
			col[5 * nyx + q] = 1.0 if _unst[c] else 0.0
			col[6 * nyx + q] = side[q]
			col[7 * nyx + q] = scs[q]
			col[11 * nyx + q] = maxf(lam, lam_frac * h_bl[c])
			col[COL_CD * nyx + q] = _cd_col[c]
			col[COL_UST * nyx + q] = _ust_col[c]
			# нагрев: Q = значение на уровнях [k0, k1] столбца (ореол — нет)
			var qv := 0.0
			var k0 := 1.0
			var k1 := 0.0
			var interior := i > 0 and i < nx_h - 1 and j > 0 and j < ny_h - 1
			if interior:
				var kb := maxi(kf[q], 1)
				if kb > nz_h - 2:
					kb = 0  # столбец целиком в земле (argmax по пустому — 0)
				var h0 := hk[c]
				if cbl and h0 > 0.0:
					# нелокальный перенос: равномерно по слою перемешивания (0 ≤ z − h < h_bl)
					var n_in := 0
					var ks := -1
					for k in range(maxi(kf[q], 1), nz_h - 1):
						var za := zc(k) - hc[c]
						if za < h_bl[c] and za > -dz:
							if ks < 0:
								ks = k
							n_in += 1
					if n_in > 0:
						qv = h0 / (n_in * dz)
						k0 = ks
						k1 = ks + n_in - 1
				else:
					qv = h0 / dz
					k0 = kb
					k1 = kb
			col[8 * nyx + q] = qv
			col[9 * nyx + q] = k0
			col[10 * nyx + q] = k1
	# ---- «жёсткие» границы: множитель выхода (баланс потоков по граням типа 2)
	fixed_scale = 1.0
	if windy:
		var fin := 0.0
		var fout := 0.0
		for side_i in [1, nx_h - 1]:  # грани u на западе (s = −1) и востоке (s = +1)
			var s := -1.0 if side_i == 1 else 1.0
			for j in range(1, ny_h - 1):
				var q: int = j * nx_h + side_i
				var hu := 0.5 * (hp[q] + hp[q - 1])
				for k in range(maxi(kf[j * nx_h + (1 if side_i == 1 else nx_h - 2)], 1), nz_h - 1):
					var nn := s * u_a * ex * _prof(zc(k) - hu, z_sat)
					fin -= minf(nn, 0.0)
					fout += maxf(nn, 0.0)
		for side_j in [1, ny_h - 1]:
			var s := -1.0 if side_j == 1 else 1.0
			for i in range(1, nx_h - 1):
				var q: int = side_j * nx_h + i
				var hv := 0.5 * (hp[q] + hp[q - nx_h])
				for k in range(maxi(kf[(1 if side_j == 1 else ny_h - 2) * nx_h + i], 1), nz_h - 1):
					var nn := s * u_a * ey * _prof(zc(k) - hv, z_sat)
					fin -= minf(nn, 0.0)
					fout += maxf(nn, 0.0)
		fixed_scale = fin / fout if fout > 0.0 else 1.0
	cd = cd_of(float(p.z0))
	var dtu := dtau_u()
	prm = PackedFloat32Array(
		[
			dx,
			dz,
			1.0 / dtu,
			cd,
			z_bot,
			float(p.k_relax),
			pow(float(p.cs_h) * dx, 2.0),
			1.0 / dth,
			1.0 / float(p.tau_cool),
			u_a * ex,
			u_a * ey,
			float(p.z0),
			z_sat,
			float(p.alpha),
			ustar,
			float(p.k_fa),
			fixed_scale,
			1.0 if windy else 0.0,
			KAPPA,
		]
	)
	prm.resize(32)
	prm[P_IPRT] = 1.0 / float(p.pr_t)
	return true


## Предел профиля притока: p.max_profile, а если не задан (NAN) — правило z_sat WindProfile при α
## случая (как air.py: Params.max_profile None).
func max_profile_used() -> float:
	var mp := float(p.max_profile)
	if is_nan(mp):
		mp = WindProfile.max_profile(float(p.alpha), u10, float(p.z0), float(p.f_cor))
	return mp


## K_b по столбцам (Троен–Март / Холтслаг–Бовилль, air.py → _closure): h, w*, 1/L (Обухов),
## неустойчиво.
func _closure(hk: PackedFloat64Array, any_heat: bool) -> void:
	var n := nx * ny
	ustar = KAPPA * u10 / log(10.0 / float(p.z0)) if u10 > 0.0 else 0.0
	# по столбцу (SH-6): C_d = (κ/ln(½dz/z0))² — как стенка решателя; u* — из того же ветра на ½dz,
	# что у эффективного z0 области: U(½dz) = u*_обл/κ·ln(½dz/z0_обл) → u* = κU(½dz)/ln(½dz/z0).
	# Без карты — побитно прежние скаляры.
	var z0c := z0_columns()
	var lr := log(0.5 * dz / float(p.z0))
	_cd_col.resize(n)
	_ust_col.resize(n)
	for c in n:
		var lc := log(0.5 * dz / z0c[c])
		_cd_col[c] = pow(KAPPA / lc, 2.0)
		_ust_col[c] = ustar * lr / lc if z0c[c] != float(p.z0) else ustar
	var sig := float(p.k_smooth_m) / dx
	var hs_heat := gauss2d(hk, nx, ny, sig) if any_heat else PackedFloat64Array()
	if not any_heat:
		hs_heat.resize(n)
	if _hs.size() != n:
		_hs = gauss2d(hc, nx, ny, sig)
	var hs := _hs
	h_bl = PackedFloat64Array()
	h_bl.resize(n)
	_wst.resize(n)
	_invl.resize(n)
	_unst.resize(n)
	var wmax := 0.0
	var hmax := 0.0
	for c in n:
		var us := _ust_col[c]
		var h_mech := NEUTRAL_BL_K * us / float(p.f_cor)
		var hsv := hs_heat[c]
		var unst := hsv > 1e-6
		var h_c := maxf(z_i - hs[c], float(p.zi_min)) if not is_nan(z_i) else float(p.zi_min)
		var h_u := maxf(h_c, h_mech)
		var ws := pow(G / THETA0 * maxf(hsv, 0.0) * h_u, 1.0 / 3.0) if unst else 0.0
		var lmo := INF
		if hsv < -1e-6:
			lmo = -us * us * us * THETA0 / (KAPPA * G * hsv)
		var h_s := h_mech
		if is_finite(lmo):
			h_s = minf(h_mech, 0.4 * sqrt(us * lmo / float(p.f_cor)))
		var h := maxf(h_u if unst else h_s, 1.0)
		h_bl[c] = h
		_wst[c] = ws
		_invl[c] = 1.0 / lmo if is_finite(lmo) and lmo != 0.0 else (INF if is_finite(lmo) else 0.0)
		_unst[c] = unst
		wmax = maxf(wmax, ws)
		hmax = maxf(hmax, h)
	closure_info = {
		ustar = ustar, h_mech = NEUTRAL_BL_K * ustar / float(p.f_cor), wstar_max = wmax, h_max = hmax
	}


## C_d стенки при шероховатости z0: (κ/ln(½dz/z0))² (air.py Air.cd).
func cd_of(z0: float) -> float:
	return pow(KAPPA / log(0.5 * dz / z0), 2.0)


func _count_unknowns(kf: PackedInt32Array) -> void:
	# клетки воздуха: k ∈ [max(kf, 1), nz_h − 2] во внутренних столбцах
	var nf := 0
	var nw := 0
	for j in range(1, ny_h - 1):
		for i in range(1, nx_h - 1):
			var c := maxi(nz_h - 2 - maxi(kf[j * nx_h + i], 1) + 1, 0)
			nf += c
			nw += maxi(c - 1, 0)
	var nu := 0
	for j in range(1, ny_h - 1):
		for i in range(2, nx_h - 1):
			var a := maxi(maxi(kf[j * nx_h + i], kf[j * nx_h + i - 1]), 1)
			nu += maxi(nz_h - 2 - a + 1, 0)
	var nv := 0
	for j in range(2, ny_h - 1):
		for i in range(1, nx_h - 1):
			var a := maxi(maxi(kf[j * nx_h + i], kf[(j - 1) * nx_h + i]), 1)
			nv += maxi(nz_h - 2 - a + 1, 0)
	n_fluid = nf
	n_unk = PackedInt32Array([nu, nv, nw, nf])


func _prof(agl: float, z_sat: float) -> float:
	return minf(pow(maxf(agl, float(p.z0)) / z_sat, float(p.alpha)), 1.0)


static func to_f32(a: PackedFloat64Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.size())
	for i in a.size():
		out[i] = a[i]
	return out


static func _ramp(d: float, side_len: float, rate: float) -> float:
	var r := clampf(1.0 - d / side_len, 0.0, 1.0)
	return r * r * rate


## Гауссово сглаживание (σ в клетках), края — отражение (как air.gauss2d / numpy «reflect»).
## Свёртка с отражением по оси — умножение на матрицу n × n (веса ядра, сложенные по отражённым
## индексам): при ядре длиннее оси (окна клипмапа: σ 15–30 клеток на 64) — n отводов вместо 2r + 1.
static func gauss2d(a: PackedFloat64Array, w: int, h: int, sigma: float) -> PackedFloat64Array:
	if sigma <= 0.3:
		return a.duplicate()
	var r := ceili(3.0 * sigma)
	var ker := PackedFloat64Array()
	var ks := 0.0
	for q in range(-r, r + 1):
		var e := exp(-0.5 * pow(q / sigma, 2.0))
		ker.append(e)
		ks += e
	for q in ker.size():
		ker[q] /= ks
	# по строкам (ось 1 = i), затем по столбцам (ось 0 = j)
	var tmp := _conv_axis(a, w, h, ker, r, true)
	return _conv_axis(tmp, w, h, ker, r, false)


## Свёртка по оси (rows — вдоль i) с отражением: отводы, сложенные по отражённому индексу.
static func _conv_axis(
	a: PackedFloat64Array, w: int, h: int, ker: PackedFloat64Array, r: int, rows: bool
) -> PackedFloat64Array:
	var n := w if rows else h
	var m := h if rows else w
	var step := 1 if rows else w
	var lane := w if rows else 1
	# для каждого выходного индекса — список (источник, вес)
	var src: Array[PackedInt32Array] = []
	var wts: Array[PackedFloat64Array] = []
	var acc := PackedFloat64Array()
	acc.resize(n)
	for i in n:
		acc.fill(0.0)
		for q in range(-r, r + 1):
			acc[_reflect(i + q, n)] += ker[q + r]
		var si := PackedInt32Array()
		var wi := PackedFloat64Array()
		for s in n:
			if acc[s] != 0.0:
				si.append(s)
				wi.append(acc[s])
		src.append(si)
		wts.append(wi)
	var out := PackedFloat64Array()
	out.resize(w * h)
	for l in m:
		var base := l * lane
		for i in n:
			var si := src[i]
			var wi := wts[i]
			var s := 0.0
			for t in si.size():
				s += wi[t] * a[base + si[t] * step]
			out[base + i * step] = s
	return out


## Индекс с отражением без повтора края (numpy pad mode="reflect").
static func _reflect(i: int, n: int) -> int:
	if n == 1:
		return 0
	var period := 2 * (n - 1)
	var m := posmod(i, period)
	return m if m < n else period - m
