extends TestCase
## Фазы поля на CPU (P10 / P14, AirPhaseCpu): Σ весов = 1, пороги из конфига, оси фаз, F — подобие
## [LS80, LWP80] и AM-07 (calibration_data.md: Allen 2006), G — профиль Прандтля и скорость стока
## [ZW13], H — статистика штиля, детерминизм. Допуски — configs/atmosphere.json → air_phase.checks.
## Случаи — синтетические (холм/долина на малой сетке: CPU-путь медленный на 96 × 96).

const N := 24
const NZ := 30
const DX := 400.0
const DZ := 105.0


static func cfg() -> Dictionary:
	return AirPhase.config().duplicate(true)


static func chk(c: Dictionary, key: String) -> Variant:
	return c.checks[key]


## Синтетический случай: гауссов холм (relief, м) или долина (relief < 0) в центре, фон θ̄ с N над z_i.
static func make_case(
	relief: float, u10: float, heat_wm2: float, zi_agl: float, n_bv: float, wdir := 270.0, n := N
) -> AirCase:
	var c := AirCase.new()
	var base := 500.0
	var zb := base - DZ
	c.set_grid(DX, n, n, DZ, zb, NZ, -n * DX / 2, -n * DX / 2)
	var hc := PackedFloat64Array()
	hc.resize(n * n)
	var r0 := n * DX / 6
	for j in n:
		for i in n:
			var x := (i + 0.5 - n / 2.0) * DX
			var y := (j + 0.5 - n / 2.0) * DX
			var g := exp(-(x * x + y * y) / (2 * r0 * r0))
			hc[j * n + i] = base + (relief * g if relief > 0.0 else -relief * (1.0 - g))
	c.hc = hc
	c.z_i = base + zi_agl if zi_agl > 0.0 else NAN
	var gm := AirPhase.THETA0 * n_bv * n_bv / AirPhase.GRAV
	c.gam.resize(NZ + 2)
	for k in NZ + 2:
		c.gam[k] = gm if (is_nan(c.z_i) or c.zc(k) >= c.z_i) else 0.0
	if heat_wm2 != 0.0:
		var h := PackedFloat64Array()
		h.resize(n * n)
		h.fill(heat_wm2)
		c.heat = h
	c.u10 = u10
	c.u10_menu = u10
	c.wdir = wdir
	c.taper = false
	c.p.max_profile = 1.6
	c.label = "синт. %s м U%s H%s" % [relief, u10, heat_wm2]
	return c


func _run(c: AirCase, conf := {}) -> Dictionary:
	var r := AirPhaseCpu.run(c, conf if not conf.is_empty() else cfg())
	check(not r.has("error"), "AirPhaseCpu: %s" % r.get("error", ""))
	return r


func _sum_ok(r: Dictionary, key: String, tol: float) -> float:
	var w: PackedFloat32Array = r[key]
	var n2 := w.size() / AirPhase.K
	var worst := 0.0
	for c in n2:
		var s := 0.0
		for k in AirPhase.K:
			s += w[k * n2 + c]
			check(w[k * n2 + c] >= -tol, "вес ≥ 0")
		worst = maxf(worst, absf(s - 1.0))
	check(worst <= tol, "%s: |Σ w − 1| = %s ≤ %s" % [key, String.num_scientific(worst), tol])
	return worst


func test_contract_and_sum() -> void:
	var conf := cfg()
	var c := make_case(400.0, 4.0, 150.0, 1200.0, 0.01)
	var r := _run(c)
	if r.has("error"):
		return
	var n2 := N * N
	var big := (N + 2) * (N + 2) * (NZ + 2)
	check((r.weights as PackedFloat32Array).size() == AirPhase.K * n2, "weights K·n²")
	check((r.omega as PackedFloat32Array).size() == n2, "omega n²")
	check((r.freeze as PackedByteArray).size() == n2, "freeze n²")
	for key in ["u", "v", "w", "th", "p"]:
		check((r.warm[key] as PackedFloat32Array).size() == big, "warm.%s N с ореолом" % key)
	check(r.mech_field.has("u") and r.stats.has("phase_frac") and r.has("ms"), "mech_field, stats, ms")
	check(AirPhase.PHASES == ["A", "B", "C", "D", "F", "G", "H"], "порядок фаз P10")
	var tol := float(chk(conf, "sum_tol"))
	var e1 := _sum_ok(r, "weights", tol)
	var e2 := _sum_ok(r, "weights_mech", tol)
	print("air_phase: Σw max |Σ−1| h %s, m %s; доли %s; Fr %.2f, ω %.2f, %.0f мс (%s)" % [
		String.num_scientific(e1), String.num_scientific(e2), r.stats.phase_frac, r.stats.fr, r.stats.omega, r.ms, r.ms_parts
	])
	# под землёй — 0; над рельефом поле есть
	var u: PackedFloat32Array = r.warm.u
	var nyx := (N + 2) * (N + 2)
	check(u[0 * nyx + nyx / 2] == 0.0, "k = 0 — земля")
	var top := (NZ * nyx) + (N / 2) * (N + 2) + 2
	check(absf(u[top]) > 0.5, "поле над рельефом есть (u = %.2f)" % u[top])


func test_phase_axes() -> void:
	# штиль (Fr < 0,25) → H, вся область — механизм; блокирование (Fr ≈ 0,5) → D, ω = 0,5;
	# сильный ветер (Fr ≫ 1) → A, ω = 1, без заморозки
	var rows := [[0.3, "H", true], [1.5, "D", false], [12.0, "A", false]]
	for row in rows:
		var r := _run(make_case(500.0, row[0], 0.0, 0.0, 0.01))
		if r.has("error"):
			return
		var fr: Dictionary = r.stats.phase_frac
		var best := ""
		var bv := -1.0
		for k in fr:
			if fr[k] > bv:
				bv = fr[k]
				best = k
		var fz: float = r.stats.frozen_frac
		print("air_phase: U10 %.1f → Fr %.2f, фаза %s (%.2f), ω %.2f, заморожено %.2f" % [
			row[0], r.stats.fr, best, bv, r.stats.omega, fz
		])
		check(best == row[1], "U10 %.1f (Fr %.2f): ведущая фаза %s, ожидалась %s" % [row[0], r.stats.fr, best, row[1]])
		check((fz > 0.99) == row[2], "заморозка всей области при Fr < fr_freeze")
	var r2 := _run(make_case(500.0, 1.5, 0.0, 0.0, 0.01))
	check(absf(float(r2.stats.omega) - 0.5) < 0.05, "ω у границ ≈ 0,5 (%.2f)" % r2.stats.omega)


func test_thresholds_from_config() -> void:
	var c := make_case(500.0, 12.0, 0.0, 0.0, 0.01)
	var conf := cfg()
	conf.classifier.fr_h = 1000.0
	var r := _run(c, conf)
	check(float(r.stats.phase_frac.H) > 0.9, "fr_h из конфига → H (%.2f)" % r.stats.phase_frac.H)
	conf = cfg()
	conf.freeze.fr_freeze = 1000.0
	r = _run(make_case(500.0, 12.0, 0.0, 0.0, 0.01), conf)
	check(float(r.stats.frozen_frac) > 0.99, "fr_freeze из конфига → заморозка")
	conf = cfg()
	conf.omega.omega_band = 0.7
	r = _run(make_case(500.0, 1.5, 0.0, 0.0, 0.01), conf)
	check(absf(float(r.stats.omega) - 0.7) < 0.05, "omega_band из конфига (%.2f)" % r.stats.omega)


func test_f_similarity() -> void:
	var conf := cfg()
	# подобие [LWP80]: доля восходящих 0,3–0,5 [LS80], σ_w/w* ≈ 0,6 на 0,3 z_i (№19), ŵ ≥ 0,45 w* (№16)
	var band: Array = chk(conf, "f_updraft_frac")
	var peak := 0.0
	var zpk := 0.0
	for q in range(2, 9):
		var zr := q / 10.0
		var u := AirPhase.updraft(conf, zr)
		check(u.a_up >= band[0] and u.a_up <= band[1], "a_up(%.1f) = %.3f в [%s, %s] [LS80]" % [zr, u.a_up, band[0], band[1]])
	for q in range(1, 100):
		var u := AirPhase.updraft(conf, q / 100.0)
		if u.sigma_w > peak:
			peak = u.sigma_w
			zpk = q / 100.0
	var u25 := AirPhase.updraft(conf, 0.25)
	print("air_phase F: a_up(0,25…0,75) %.3f…%.3f; σ_w max %.3f w* на %.2f z_i; w_up(0,25) %.2f w*" % [
		AirPhase.updraft(conf, 0.25).a_up, AirPhase.updraft(conf, 0.75).a_up, peak, zpk, u25.w_up
	])
	var pz: Array = chk(conf, "f_sigw_peak_z")
	check(absf(peak / float(chk(conf, "f_sigw_peak")) - 1.0) <= float(chk(conf, "f_sigw_peak_tol")), "σ_w/w* max ≈ 0,6")
	check(zpk >= pz[0] and zpk <= pz[1], "максимум σ_w на 0,2–0,45 z_i")
	check(u25.w_up >= float(chk(conf, "f_wmean_peak")), "w_up(0,25 z_i) ≥ ŵ [LS80]")
	# летний полдень (H 250 Вт/м², z_i 1500 м, ветер 0,8 м/с): w* в годовой статистике Allen 2006,
	# F ведущая, колонны свободной конвекции (w* ≥ U_sat) — механизму
	var r := _run(make_case(150.0, 0.8, 250.0, 1500.0, 0.01))
	if r.has("error"):
		return
	var wr: Array = chk(conf, "f_wstar_range")
	var ws: float = r.stats.wstar_max
	print("air_phase F: w* %.2f м/с, z_i %.0f м над низом, доля F %.2f, заморожено %.2f, U_sat %.2f" % [
		ws, r.stats.zi_agl, r.stats.phase_frac.F, r.stats.frozen_frac, r.stats.u_sat
	])
	check(ws >= wr[0] and ws <= wr[1], "w* %.2f в [%s, %s] (Allen 2006 ±2σ)" % [ws, wr[0], wr[1]])
	check(absf(float(r.stats.zi_agl) - 1500.0) < 1.0, "z_i над низом рельефа — из случая")
	check(float(r.stats.phase_frac.F) > 0.5, "F ведущая при сильном нагреве и слабом ветре")
	check(float(r.stats.frozen_frac) > 0.5, "свободная конвекция (w* ≥ U_sat) отдана механизму")
	check(float(r.stats.frozen_frac_mech) < 0.01, "без нагрева F нет")
	# θ′ слоя перемешивания > 0 (баланс тепла столба), выше z_i — не тёплый
	var th: PackedFloat32Array = r.warm.th
	var nyx := (N + 2) * (N + 2)
	var col := (N / 2) * (N + 2) + N / 2
	check(th[3 * nyx + col] > 0.0, "θ′ в слое перемешивания > 0 (%.3f К)" % th[3 * nyx + col])


func test_g_prandtl_and_speed() -> void:
	var conf := cfg()
	var gc: Dictionary = conf.g
	var tol := float(chk(conf, "g_prandtl_tol"))
	# профиль Прандтля: максимум u на n = πl/4, u_max = e^(−π/4) sin(π/4)·u_s, θ′(0) = −Δθ, Δθ = |H|l/(ρc_pK)
	var pr := AirPhase.prandtl(0.1, 0.01, -30.0, gc)
	var best := 0.0
	var nbest := 0.0
	for q in 4000:
		var nn: float = q * pr.l / 1000.0
		var u: float = pr.us * exp(-nn / pr.l) * sin(nn / pr.l)
		if u > best:
			best = u
			nbest = nn
	check(absf(nbest / pr.nj - 1.0) < 2 * tol + 1.0 / 1000 * 4, "максимум на πl/4 (%.2f против %.2f м)" % [nbest, pr.nj])
	check(absf(best / pr.umax - 1.0) < tol, "u_max = 0,322·u_s")
	var dth_closure: float = 30.0 * pr.l / (AirPhase.RHO_CP * float(gc.k_m2s))
	check(absf(pr.dth / dth_closure - 1.0) < tol, "Δθ по замыканию потоком")
	print("air_phase G: N 0,01, sin α 0,1, H −30: l %.1f м, Δθ %.2f К, u_max %.2f м/с на %.1f м" % [
		pr.l, pr.dth, pr.umax, pr.nj
	])
	# скорость стока на типичных склонах [ZW13: 1–4 м/с]
	var rng: Array = chk(conf, "g_speed_range")
	for row in [[0.1, 0.01, -30.0], [0.2, 0.01, -40.0], [0.15, 0.012, -40.0], [0.05, 0.01, -20.0]]:
		var p2 := AirPhase.prandtl(row[0], row[1], row[2], gc)
		check(p2.umax >= rng[0] and p2.umax <= rng[1], "u_max %.2f м/с в [%s, %s] (sin α %s, N %s, H %s)" % [
			p2.umax, rng[0], rng[1], row[0], row[1], row[2]
		])
	# вечер в долине: выхолаживание −40 Вт/м², штиль; G включён, сток вниз по склону у земли
	var c := make_case(-400.0, 0.5, -40.0, 0.0, 0.02)
	var r := _run(c)
	if r.has("error"):
		return
	var g: Dictionary = r.stats.g
	print("air_phase G (долина): %s; доля G %.2f" % [g, r.stats.phase_frac.G])
	check(bool(g.active), "G включён вечером")
	check(float(g.umax_med) >= rng[0] and float(g.umax_med) <= rng[1], "медиана u_max %.2f в [1, 4]" % g.umax_med)
	check(float(r.stats.phase_frac.G) > 0.1, "вес G есть при штиле")
	# у земли на склоне (восточный склон долины — к центру на запад) u < 0
	var nyx := (N + 2) * (N + 2)
	var i := N * 3 / 4
	var j := N / 2
	var hc: float = c.hc[j * N + i]
	var k := ceili((hc - c.z_bot) / DZ + 0.5)
	var u: PackedFloat32Array = r.warm.u
	var uc: float = 0.5 * (u[(k * (N + 2) + j + 1) * (N + 2) + i + 1] + u[(k * (N + 2) + j + 1) * (N + 2) + i + 2])
	check(uc < 0.0, "сток вниз по склону (u = %.2f м/с у земли на восточном склоне)" % uc)
	# дно долины — гидравлический слой: θ′ = −Δθ(1 − z/d) < 0 у земли
	var th: PackedFloat32Array = r.warm.th
	var ic := N / 2
	var kc := ceili((c.hc[ic * N + ic] - c.z_bot) / DZ + 0.5)
	var thc := th[(kc * (N + 2) + ic + 1) * (N + 2) + ic + 1]
	check(thc < 0.0, "холодное озеро на дне долины (θ′ = %.2f К)" % thc)


func test_h_statistics() -> void:
	var conf := cfg()
	var c := make_case(300.0, 0.3, 0.0, 0.0, 0.01)
	var r := _run(c)
	if r.has("error"):
		return
	var st: Dictionary = r.stats
	check(float(st.h_spread) > 0.0, "разброс H > 0 (%.3f м/с)" % st.h_spread)
	# среднее по области — без направленного дрейфа против фона: |⟨u⟩ − ⟨U(z)·e⟩| ≤ доля U_sat
	var p := AirPhase.prepare(c, conf)
	var u: PackedFloat32Array = r.warm.u
	var v: PackedFloat32Array = r.warm.v
	var nx2 := N + 2
	var su := Vector2.ZERO
	var sb := Vector2.ZERO
	var cnt := 0
	for k in range(1, NZ + 1):
		var z := c.zc(k)
		for j in range(1, N + 1):
			for i in range(2, N + 1):
				var h := c.hc[(j - 1) * N + i - 1]
				if z < h or z < c.hc[(j - 1) * N + i - 2]:
					continue
				var q := (k * nx2 + j) * nx2 + i
				su += Vector2(u[q], v[q])
				sb += AirPhase.u_prof(p, z - h) * Vector2(p.ex, p.ey)
				cnt += 1
	var d := (su - sb).length() / maxi(cnt, 1)
	print("air_phase H: Fr %.2f, доля H %.2f, разброс %.3f м/с, дрейф %.3f м/с (U_sat %.2f)" % [
		st.fr, st.phase_frac.H, st.h_spread, d, st.u_sat
	])
	check(d <= float(chk(conf, "h_drift_max")) * float(st.u_sat), "нет направленного дрейфа в штиле")


func test_determinism() -> void:
	var c := make_case(400.0, 3.0, 120.0, 1000.0, 0.01, 200.0)
	var a := _run(c)
	var b := _run(make_case(400.0, 3.0, 120.0, 1000.0, 0.01, 200.0))
	if a.has("error") or b.has("error"):
		return
	check(a.weights == b.weights, "веса повторяются побитно")
	check(a.warm.u == b.warm.u and a.warm.th == b.warm.th, "тёплый старт повторяется побитно")
