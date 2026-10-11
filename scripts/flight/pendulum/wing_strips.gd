class_name PendulumWingStrips
extends RefCounted
## Аэродинамика крыла «Маятника» по полосам (strip theory, простая теория стреловидности) —
## порт tools/research/pendulum/pendulum/{geometry,model}.py (make_strips, wing_aero).
##
## Оси — связанные B (авиационные): x — вперёд по килю, y — вправо, z — вниз; начало — ЦМ крыла.
## У каждой полосы местная скорость v + ω×r − ветер; подъёмная сила ⊥ нормальной к кромке
## скорости, сопротивление — поляра игры CD(CL) за вычетом доли пилота, × cd_scale крыла.
## Сваливание полосы (PD-22) — линейно до cl_max, дальше Viterna & Corrigan (1981): C_L и C_D
## непрерывны на срыве, к 90° — пластина конечного удлинения C_N 90° = 1,11 + 0,018·λ (≈ 1,2 при
## λ 5–8; Hoerner, «Fluid-Dynamic Drag», 1965, гл. 3: пластина λ 5 — 1,2, λ 10 — 1,3; 2D — 2,0).
## За срывом C_L падает плавно (≈ −15 % за 5–6°, как эскиз «Славутича» у Жеглова, с. 15) — наклон
## отрицательный: опускающаяся консоль теряет подъёмную силу, это авторотация (сваливание на крыло,
## штопор). strips.stall_model = "plate" — прежняя 2D-пластина CN = 2 (смешивание за 4°). cl_max
## полос подобран так, что C_L max всего крыла = поляры (скорость сваливания паспорта, PD-14).
## Центр давления сорванной части полосы уходит назад по хорде, как у плоской пластины:
## x/c = 0,25 + 0,25·sin α (≈ 0,38 при 30°, 0,5 при 90°; Fage & Johansen 1927, ARC R&M 1104) —
## пикирующий момент срыва, без него крыло зависает в глубоком срыве (PD-18); у обтекаемой — cp_chord.
## Сдвиг нарастает линейно за срывом на strips.stall_cp_blend_deg (20°, PD-22): отрыв развивается
## постепенно, как и падение C_L по Viterna; положение пластины — в глубоком срыве. С 4° (как
## смешивание пластины) срыв давал резкий клевок — «пикирование», а не «парашютирование» (Жеглов, с. 112).
## Гибкий парус (PD-24): полосы не урезают разницу нагрузок консолей — Clβ, Clp, Clr идут как у
## жёсткого крыла по полосам (к Hiway Demon, Cook & Spottiswoode 2005). Гибкость — «перекос пузыря»
## (billow shift, Kroo 1981, NASA TM-81269: киль-карман и плавающая поперечина): пилот толкает
## штангу вбок, рама сдвигает киль относительно паруса, крутка консолей антисимметрична — конец на
## стороне пилота теряет угол атаки на billow_shift_deg × sail_flex градусов на единицу отношения
## поперечной силы рук к весу пилота (в равновесии — тангенс угла стропы к крылу), линейно по
## размаху. Свободное качание пилота с отпущенной штангой парус не перекашивает. Это главный рычаг управления смещением веса; сам по себе
## сдвиг ЦМ перекладывает крыло 45→45 за 10 с и дольше (PD-24), с перекосом — за ≈ 4 с. Флюгерная
## устойчивость — «эквивалентный киль» (Cnβ) позади ЦМ. Момент паруса — dcm0 (Cm0).
##
## Экранный эффект (PD-14): у земли вихревой след крыла «отражается» от неё (метод зеркального
## вихря), индуктивный скос потока у полосы падает в (1 − σ) раз, σ — по высоте полосы над землёй
## h и размаху b, формула Wieselsberger (1922; NACA TM-77; McCormick, «Aerodynamics, Aeronautics
## and Flight Mechanics», 1995, гл. 9): σ = (1 − 1,32·h/b) / (1,05 + 7,4·h/b), σ ≥ 0 (нуль с
## h/b ≈ 0,76). Индуктивная часть сопротивления C_L²/(π·e·λ) — × (1 − σ); наклон подъёмной силы —
## теория несущей линии с тем же скосом: a = a₀ / (1 + (1 − σ)·a₀/(π·e·λ)), a₀ — профиля, из
## lift_slope крыла без экрана; C_L max прежний (срыв у земли — при меньшем угле атаки).

const BLEND_DEG := 4.0

var n: int = 0  ## число полос (чётное): [0, n/2) — правая консоль, [n/2, n) — левая
var r_b := PackedVector3Array()  ## точки приложения сил полос (четверть хорды), B
var c_b := PackedVector3Array()  ## хордовое направление (вперёд, ⊥ размаху), B
var n_b := PackedVector3Array()  ## нормаль панели (вниз, с поперечным V), B
var s_b := PackedVector3Array()  ## размах наружу, B
var sxc_b := PackedVector3Array()  ## s × c (для направления подъёмной силы)
var sxn_b := PackedVector3Array()  ## s × n
var twist := PackedFloat64Array()  ## геометрическая крутка, рад
var sc := PackedFloat64Array()  ## площадь полосы (хорда × ширина), м²
var chord := PackedFloat64Array()  ## хорда полосы, м
var yabs := PackedFloat64Array()  ## |y| / полуразмаха
var side := PackedFloat64Array()  ## +1 правая, −1 левая

var cos_sweep: float = 1.0
## Угол атаки полосы по потоку из угла ⊥ кромке (PD-35, strips.sweep_alpha_exact): true — точно,
## tg α = tg α⊥·cos Λ (atan2(u_z·cos Λ, u_c): на 90° — 90°, за ним — обратный поток), false —
## линейно α⊥·cos Λ (верно при малых α; поперёк паруса даёт 78° вместо 90°, сила не по нормали)
var sweep_alpha_exact := true
var cp_chord: float = 0.25  ## точка приложения сил обтекаемой полосы, доля хорды
var stall_cp_shift := true  ## центр давления сорванной части — назад (pendulum.json → stall_cp_shift)
## Обратный поток (|α| > 90°, PD-35, pendulum.json → stall_cp_reverse): пластина симметрична — центр
## давления от задней кромки как от передней, x/c = 0,75 − 0,25·|sin α| (иначе 0,25 + 0,25·|sin α|)
var stall_cp_reverse := true
var stall_vc := true  ## срыв по Viterna & Corrigan (strips.stall_model = "viterna"), иначе пластина CN = 2
## C_N (C_D) сорванной полосы при 90° в коэффициентах полосы: (1,11 + 0,018·λ)·cos²Λ (strips.stall_cd90_*,
## PD-35): сила полосы — q⊥/cos²Λ·C, а пластина поперёк потока держит C_N 90° по полному напору
## (q⊥ = q), поэтому в формулу Viterna идёт C_N·cos²Λ; без этого C_N крыла на 90° — 1,54–1,62 вместо 1,2
var cd90: float = 1.2
## Срыв по местному c_l, отнесённому к полному напору полосы (метод критического сечения,
## strips.stall_criterion = "streamwise"): потолок c_l по нормальной к кромке скорости — cl_max·|u|²·cos²Λ/
## (u_c² + u_z²). В скольжении наветренная консоль (меньше стреловидность, больше нагрузка) срывается
## первой; "normal" — по углу атаки в плоскости ⊥ кромке (простая теория стреловидности: первой —
## подветренная).
var stall_streamwise := true
## Сдвиг центра давления сорванной части нарастает за срывом на этом угле, рад (strips.stall_cp_blend_deg)
var stall_cp_blend: float = deg_to_rad(20.0)
var lift_slope: float = 0.0
var alpha0_root: float = 0.0  ## α нулевой подъёмной силы киля + средняя крутка
var cl_max: float = 1.0  ## C_L max полосы (поляра или подобранный под неё — match_polar_cl_max)
var cl_max_wing: float = 0.0  ## C_L max всего крыла (статика), справочно
var polar: WingPolar
var cd_scale: float = 1.0
var cd_pilot_share: float = 0.0
var billow_shift: float = 0.0  ## крутка конца, рад на единицу «сила рук вбок / вес пилота» (× гибкость)
var dcm0: float = 0.0
var area: float = 0.0
var chord_mean: float = 0.0
var fin_area: float = 0.0
var fin_slope: float = 0.0
var r_fin_b := Vector3.ZERO
var free_yaw := true
var cn_p_add: float = 0.0  ## добавка Cn на pb/2V (PD-К2 v4)
var cn_r_add: float = 0.0  ## добавка Cn на rb/2V (PD-К2 v4)
var _sb2_4: float = 0.0  ## S·b²/4 для добавок рыскания
## Экранный эффект: 1/(π·e·λ) и наклон профиля a₀ (lift_slope = a₀/(1 + a₀/(π·e·λ))).
var ind_k: float = 0.0
var a0_2d: float = 0.0

# результат последнего вызова aero (мир NED, около ЦМ)
var force := Vector3.ZERO
var moment := Vector3.ZERO
var force_b := Vector3.ZERO  ## то же в осях B
var moment_b := Vector3.ZERO
var lift_n: float = 0.0  ## подъёмная сила (−F_b.z), Н
var blend := PackedFloat64Array()  ## 0 — обтекание, 1 — пластина (по полосам)
var margin := PackedFloat64Array()  ## угол атаки полосы минус срывной, рад (> 0 — за срывом)
var alpha_s := PackedFloat64Array()  ## угол атаки полосы от нулевой подъёмной, рад (для разбора)

## Запаздывание отрыва (PD-29, strips.dynamic_stall): доля обтекаемого потока полосы f отстаёт от
## статической — τ₁·ḟ = f_ст(Δα − τ₂·Δα̇) − f, τ = T·c/V (Goman & Khrabrov 1994). dyn_dt — время с
## прошлого вызова aero (≤ 0 — статика без состояния: балансировка, C_L max; больше DYN_DT_MAX —
## сброс: f = f_ст). Пока f > 0 за срывом, обтекаемая часть несёт нормальную силу пластины без подсасывания
## кромки — подъёмная выше cl_max и сопротивление растут вместе (perching); нормальная сила не больше
## dyn_cn_max (пик динамического срыва).
const DYN_DT_MAX := 0.25
var dyn_on := false
var dyn_t1: float = 3.0  ## τ₁ в c/V
var dyn_t2: float = 2.0  ## τ₂ в c/V
var dyn_cn_max: float = 3.0  ## предел нормальной силы обтекаемой части за срывом
var dyn_dt: float = 0.0
var attached := PackedFloat64Array()  ## f — доля обтекаемого потока полосы (1 — обтекание)
var _m_prev := PackedFloat64Array()  ## Δα прошлого вызова (для Δα̇)

# рабочие массивы
var _inv_blend: float = 1.0
## Таблица сопротивления полосы cd_scale·(CD поляры − доля пилота) по CL от _cd_lo до C_L max поляры.
var _cd_tab := PackedFloat64Array()
var _cd_lo: float = -2.0
var _cd_hi: float = 1.0  ## верх таблицы — C_L max поляры (выше — сопротивление как на нём, как прототип)
var _cd_inv: float = 1.0


## wing — конфиг крыла, blk — его блок pendulum (PD-К2), pend — configs/pendulum.json,
## dihedral — эффективное поперечное V, рад; cg_n — ЦМ крыла в осях «от носа» (x назад, z вниз).
func setup(
	wing: Dictionary, blk: Dictionary, pend: Dictionary, polar_: WingPolar, dihedral: float,
	flex: float, cg_n: Vector3
) -> void:
	var st: Dictionary = pend.strips
	n = int(st.count)
	var n_side := n / 2
	area = float(wing.area_m2)
	var span := float(wing.span_m)
	chord_mean = area / span
	var half := 0.5 * span
	var root := float(blk.root_chord_m)
	var tip := float(blk.tip_chord_m)
	var k := area / (0.5 * (root + tip) * span)
	var sweep := deg_to_rad(float(blk.sweep_deg))
	var t := tan(sweep)
	var washout := deg_to_rad(float(blk.washout_deg))
	var cp := float(st.cp_chord)
	cp_chord = cp
	cos_sweep = cos(sweep)
	var sl := sin(sweep)
	var sg := sin(dihedral)
	var cg := cos(dihedral)
	r_b.resize(n)
	c_b.resize(n)
	n_b.resize(n)
	s_b.resize(n)
	sxc_b.resize(n)
	sxn_b.resize(n)
	twist.resize(n)
	sc.resize(n)
	chord.resize(n)
	yabs.resize(n)
	side.resize(n)
	var i := 0
	for s: float in [1.0, -1.0]:
		var s_vec := Vector3(-sl, s * cos_sweep * cg, -cos_sweep * sg)
		var n_vec := Vector3(0.0, s * sg, cg)
		var c_vec := s_vec.cross(n_vec)
		if c_vec.x < 0.0:
			c_vec = -c_vec
		c_vec = c_vec.normalized()
		for j in n_side:
			var y := (j + 0.5) * half / n_side
			var c := k * (root + (tip - root) * y / half)
			var x := y * t + cp * c
			var z := -y * tan(dihedral)
			r_b[i] = Vector3(cg_n.x - x, s * y, z - cg_n.z)
			c_b[i] = c_vec
			n_b[i] = n_vec
			s_b[i] = s_vec
			sxc_b[i] = s_vec.cross(c_vec)
			sxn_b[i] = s_vec.cross(n_vec)
			twist[i] = -washout * y / half
			sc[i] = c * half / n_side
			chord[i] = c
			yabs[i] = y / half
			side[i] = s
			i += 1
	lift_slope = float(wing.lift_slope_per_rad)
	var tw := 0.0
	var ss := 0.0
	for j in n:
		tw += twist[j] * sc[j]
		ss += sc[j]
	alpha0_root = deg_to_rad(float(wing.zero_lift_alpha_deg)) + tw / ss
	polar = polar_
	cl_max = polar.cl_max
	cd_scale = float(blk.cd_scale)
	cd_pilot_share = float(pend.pilot_cda_m2) / area
	billow_shift = deg_to_rad(float(pend.get("billow_shift_deg", 0.0))) * flex
	dcm0 = float(blk.dcm0)
	var yaw: Dictionary = pend.yaw
	fin_slope = float(yaw.fin_slope_per_rad)
	var fin_arm := float(yaw.fin_arm_m)
	fin_area = float(yaw.cn_beta) * area * span / (fin_slope * fin_arm)
	r_fin_b = Vector3(-fin_arm, 0.0, 0.0)
	cn_p_add = float(yaw.get("cn_p_add", 0.0))
	cn_r_add = float(yaw.get("cn_r_add", 0.0))
	_sb2_4 = 0.25 * area * span * span
	blend.resize(n)
	margin.resize(n)
	alpha_s.resize(n)
	attached.resize(n)
	_m_prev.resize(n)
	attached.fill(1.0)
	_m_prev.fill(0.0)
	_inv_blend = 1.0 / deg_to_rad(BLEND_DEG)
	var ge: Dictionary = pend.get("ground_effect", {})
	var e := float(ge.get("span_efficiency", 0.9))
	ind_k = 1.0 / (PI * e * span * span / area)
	a0_2d = lift_slope / maxf(1.0 - lift_slope * ind_k, 0.2)
	build_cd_table()
	stall_cp_shift = bool(pend.get("stall_cp_shift", true))
	stall_cp_reverse = bool(pend.get("stall_cp_reverse", true))
	sweep_alpha_exact = bool(st.get("sweep_alpha_exact", true))
	stall_vc = String(st.get("stall_model", "viterna")) == "viterna"
	stall_streamwise = String(st.get("stall_criterion", "streamwise")) == "streamwise"
	stall_cp_blend = deg_to_rad(float(st.get("stall_cp_blend_deg", 20.0)))
	cd90 = float(st.get("stall_cd90_base", 1.11)) + float(st.get("stall_cd90_per_ar", 0.018)) * span * span / area
	if bool(st.get("stall_cd90_sweep_norm", true)):
		cd90 *= cos_sweep * cos_sweep
	var ds: Dictionary = st.get("dynamic_stall", {})
	dyn_on = bool(ds.get("enabled", false))
	dyn_t1 = float(ds.get("t1_c_per_v", 3.0))
	dyn_t2 = float(ds.get("t2_c_per_v", 2.0))
	dyn_cn_max = float(ds.get("cn_max", 3.0))
	cl_max_wing = wing_cl_max()
	if bool(pend.get("strip_cl_max_match_polar", true)):
		match_polar_cl_max()


## C_L max всего крыла (статика, симметричный поток, без экрана): перебор угла атаки киля.
func wing_cl_max() -> float:
	var best := 0.0
	var a_best := 0.0
	var zero := PackedVector3Array()
	zero.resize(n)
	var cl_at := func(a: float) -> float:
		aero(Vector3(1.0, 0.0, 0.0), Basis(Vector3(0, 1, 0), a), Vector3.ZERO, zero, Vector3.ZERO,
			0.0, 1.0)
		return -force.z / (0.5 * area)  # ⊥ потоку (поток вдоль x мира)
	for ad in range(5, 46):
		var c: float = cl_at.call(deg_to_rad(ad))
		if c > best:
			best = c
			a_best = ad
	for j in 41:
		var c: float = cl_at.call(deg_to_rad(a_best - 1.0 + j * 0.05))
		best = maxf(best, c)
	return best


## C_L max полос — так, чтобы C_L max всего крыла был у поляры (скорость сваливания паспорта):
## у полос со стреловидностью и круткой корень срывается раньше, чем крыло набирает C_L max
## поляры. Бисекция по cl_max полос; сопротивление выше C_L max поляры — как на нём.
func match_polar_cl_max() -> void:
	var target := polar.cl_max
	var lo := target
	var hi := 1.6 * target
	for _it in 24:
		var mid := 0.5 * (lo + hi)
		_set_strip_cl_max(mid)
		if wing_cl_max() < target:
			lo = mid
		else:
			hi = mid
	_set_strip_cl_max(0.5 * (lo + hi))
	cl_max_wing = wing_cl_max()


func _set_strip_cl_max(c: float) -> void:
	cl_max = c


## Экранный эффект Wieselsberger: σ по высоте над землёй h и размаху b (h ≤ 0 — как h/b = 0,033,
## нижняя граница опытов). 0 — экрана нет (h/b ≥ 0,758).
static func ground_sigma(h: float, b: float) -> float:
	var hb := maxf(h / b, 0.033)
	return maxf((1.0 - 1.32 * hb) / (1.05 + 7.4 * hb), 0.0)


## Таблица CD полосы (после смены cd_scale — пересобрать): 512 отрезков, ошибка < 1e-5.
func build_cd_table() -> void:
	var nt := 512
	_cd_tab.resize(nt + 1)
	_cd_hi = polar.cl_max
	_cd_inv = nt / (_cd_hi - _cd_lo)
	for j in nt + 1:
		var cl := _cd_lo + j / _cd_inv
		_cd_tab[j] = cd_scale * (polar.cd_at(cl) - cd_pilot_share)


## Сила и момент около ЦМ (мир NED) → force, moment (и в осях B — force_b, moment_b).
## vel — скорость ЦМ (земля), R — B→мир, w — угловая скорость (мир), air — ветер в точках
## полос (мир, порядок r_b), air_c — в ЦМ, billow_lam — сила рук вбок / вес пилота
## (для billow_shift), rho — плотность, ge — σ экранного эффекта по полосам (пусто — нет).
## Полосы считаются парами (правая i, левая i + n/2).
func aero(
	vel: Vector3, R: Basis, w: Vector3, air: PackedVector3Array, air_c: Vector3,
	billow_lam: float, rho: float, ge := PackedFloat64Array()
) -> void:
	var has_ge := ge.size() == n
	var Rt := R.transposed()
	var wb: Vector3 = Rt * w
	var vb: Vector3 = Rt * vel
	var q_half := 0.5 * rho / (cos_sweep * cos_sweep)
	var h := n / 2
	var f_sum := Vector3.ZERO
	var m_sum := Vector3.ZERO
	var nt2 := _cd_tab.size() - 2
	for j in h:
		var i := j
		var k := j + h
		var rbi: Vector3 = r_b[i]
		var rbk: Vector3 = r_b[k]
		var cbi: Vector3 = c_b[i]
		var nbi: Vector3 = n_b[i]
		var cbk: Vector3 = c_b[k]
		var nbk: Vector3 = n_b[k]
		# скорость полос относительно воздуха в осях B: v + ω×r − ветер
		var ui: Vector3 = vb + wb.cross(rbi) - Rt * air[i]
		var uk: Vector3 = vb + wb.cross(rbk) - Rt * air[k]
		var uci := ui.dot(cbi)
		var uzi := ui.dot(nbi)
		var uck := uk.dot(cbk)
		var uzk := uk.dot(nbk)
		var ai := (atan2(uzi * cos_sweep, uci) if sweep_alpha_exact else atan2(uzi, uci) * cos_sweep) + twist[i]
		var ak := (atan2(uzk * cos_sweep, uck) if sweep_alpha_exact else atan2(uzk, uck) * cos_sweep) + twist[k]
		if billow_shift != 0.0:
			# перекос пузыря: на стороне пилота конец теряет угол атаки (Kroo 1981)
			ai -= side[i] * billow_shift * billow_lam * yabs[i]
			ak -= side[k] * billow_shift * billow_lam * yabs[k]
		# CL полосы: линейно до cl_max, дальше пластина CN = 2 (смешивание за 4°); у земли наклон
		# больше (экран), cl_max тот же
		var ri := ai - alpha0_root
		var rk := ak - alpha0_root
		var gi := 0.0
		var gk := 0.0
		var sli := lift_slope
		var slk := lift_slope
		if has_ge:
			gi = ge[i]
			gk = ge[k]
			sli = a0_2d / (1.0 + (1.0 - gi) * a0_2d * ind_k)
			slk = a0_2d / (1.0 + (1.0 - gk) * a0_2d * ind_k)
		var q2i := uci * uci + uzi * uzi
		var q2k := uck * uck + uzk * uzk
		var capi := cl_max
		var capk := cl_max
		if stall_streamwise:
			capi = cl_max * cos_sweep * cos_sweep * ui.length_squared() / maxf(q2i, 1.0e-9)
			capk = cl_max * cos_sweep * cos_sweep * uk.length_squared() / maxf(q2k, 1.0e-9)
		var oi := _strip_cl(i, ri, sli, capi, sqrt(q2i))
		var ok := _strip_cl(k, rk, slk, capk, sqrt(q2k))
		var cli := oi.x
		var clk := ok.x
		var cdxi := oi.y
		var cdxk := ok.y
		var bi := oi.z
		var bk := ok.z
		var qi := q_half * q2i
		var qk := q_half * q2k
		# сопротивление: поляра (таблица по CL) + пластина при срыве
		var xi := (clampf(cli, _cd_lo, _cd_hi) - _cd_lo) * _cd_inv
		var xk := (clampf(clk, _cd_lo, _cd_hi) - _cd_lo) * _cd_inv
		var ii := mini(int(xi), nt2)
		var ik := mini(int(xk), nt2)
		var c0i := _cd_tab[ii]
		var c0k := _cd_tab[ik]
		# за срывом (Viterna) — сопротивление поляры на срыве × cos α / cos α_кр (oi.w ≥ 0)
		var cdi := (c0i + (_cd_tab[ii + 1] - c0i) * (xi - ii) if oi.w < 0.0 else _cd_tab[nt2 + 1] * oi.w) + cdxi
		var cdk := (c0k + (_cd_tab[ik + 1] - c0k) * (xk - ik) if ok.w < 0.0 else _cd_tab[nt2 + 1] * ok.w) + cdxk
		if has_ge:
			# экран: индуктивная часть обтекаемой доли — × (1 − σ)
			cdi -= gi * (1.0 - bi) * cd_scale * ind_k * cli * cli
			cdk -= gk * (1.0 - bk) * cd_scale * ind_k * clk * clk
		# подъёмная ⊥ размаху и нормальной к кромке скорости (s × (c·uc + n·uz)), вверх
		var ldi: Vector3 = sxc_b[i] * uci + sxn_b[i] * uzi
		var ldk: Vector3 = sxc_b[k] * uck + sxn_b[k] * uzk
		if ldi.z > 0.0:
			ldi = -ldi
		if ldk.z > 0.0:
			ldk = -ldk
		var fi: Vector3 = (ldi * (cli / maxf(sqrt(q2i), 1.0e-9)) - ui * (cdi / maxf(ui.length(), 1.0e-9))) * (qi * sc[i])
		var fk: Vector3 = (ldk * (clk / maxf(sqrt(q2k), 1.0e-9)) - uk * (cdk / maxf(uk.length(), 1.0e-9))) * (qk * sc[k])
		f_sum += fi + fk
		if bi > 0.0 and stall_cp_shift:
			# центр давления сорванной части — назад по хорде (пластина), нарастает за stall_cp_blend
			var ci := clampf(margin[i] / stall_cp_blend, 0.0, 1.0)
			rbi -= cbi * (ci * chord[i] * (_cp_stalled(ri) - cp_chord))
		if bk > 0.0 and stall_cp_shift:
			var ck := clampf(margin[k] / stall_cp_blend, 0.0, 1.0)
			rbk -= cbk * (ck * chord[k] * (_cp_stalled(rk) - cp_chord))
		m_sum += rbi.cross(fi) + rbk.cross(fk)
	# момент паруса (Cm0) по скоростному напору в ЦМ
	var v_c := vel - air_c
	var V := v_c.length()
	m_sum.y += 0.5 * rho * V * V * area * chord_mean * dcm0
	if free_yaw:
		# «эквивалентный киль»: флюгерная устойчивость Cnβ (и Cnr, CYβ)
		var vf: Vector3 = Rt * (v_c + w.cross(R * r_fin_b))
		var beta_f := atan2(vf.y, maxf(vf.x, 0.1))
		var fy := -0.5 * rho * (vf.x * vf.x + vf.y * vf.y) * fin_area * fin_slope * beta_f
		var ff := Vector3(0.0, fy, 0.0)
		f_sum += ff
		m_sum += r_fin_b.cross(ff)
		# добавочные производные рыскания (Cnp, Cnr полос — к литературе, PD-23):
		# ΔN = ½ρV²·S·b·(cn_p_add·pb/2V + cn_r_add·rb/2V)
		if V > 0.1:
			m_sum.z += rho * V * _sb2_4 * (cn_p_add * wb.x + cn_r_add * wb.z)
	lift_n = -f_sum.z
	force_b = f_sum
	moment_b = m_sum
	force = R * f_sum
	moment = R * m_sum


## Центр давления сорванной полосы, доля хорды от передней кромки: пластина (Fage & Johansen 1927)
## 0,25 + 0,25·|sin α|; в обратном потоке (cos α < 0, stall_cp_reverse) — то же от задней кромки.
func _cp_stalled(r: float) -> float:
	var sa := 0.25 * absf(sin(r))
	if stall_cp_reverse and cos(r) < 0.0:
		return 0.75 - sa
	return 0.25 + sa


## CL полосы j: линейно до cl_max, дальше Viterna & Corrigan (или пластина CN = 2 со смешиванием
## за BLEND_DEG); r — угол атаки от нулевой подъёмной, sl — наклон (у земли больше).
## cap — потолок c_l полосы (cl_max или по методу критического сечения).
## → (CL, добавка CD, доля срыва, множитель CD поляры на срыве: −1 — CD поляры по CL).
## Viterna (α_s — срыв, C_N90 = cd90): CL = cd90/2·sin 2α + A2·cos²α/sin α,
## A2 = (cl_max − cd90·sin α_s·cos α_s)·sin α_s/cos²α_s; CD = CD_s·cos α/cos α_s +
## cd90·(sin²α − sin²α_s·cos α/cos α_s); за 90° — пластина (cos α → 0).
func _strip_cl(j: int, r: float, sl: float, cap: float, un := 0.0) -> Vector4:
	var ast := cap / sl
	var m := r - ast
	var b := clampf(m * _inv_blend, 0.0, 1.0)
	margin[j] = m
	alpha_s[j] = r
	var f := 1.0 - b
	if dyn_on:
		f = _dyn_attached(j, m, un)
	if m <= 0.0 or not stall_vc:
		blend[j] = b
		var cl := -cap if r < -ast else minf(sl * r, cap)
		if m <= 0.0:
			return Vector4(cl, 0.0, b, -1.0)
		cl += b * (sin(2.0 * r) - cl)
		return Vector4(cl, b * 2.0 * sin(r) * sin(r), b, -1.0)
	var sa := sin(ast)
	var ca := cos(ast)
	var s := sin(r)
	var c := maxf(cos(r), 0.0)
	var clv := 0.5 * cd90 * sin(2.0 * r)
	if c > 0.0:
		clv += (cap - cd90 * sa * ca) * sa / (ca * ca) * c * c / s
	var fv := c / ca
	var cdv := cd90 * (s * s - sa * sa * fv)
	if not dyn_on or f <= 0.0:
		blend[j] = b
		return Vector4(clv, cdv, b, fv)
	# обтекаемая часть за срывом: нормальная сила пластины без подсасывания кромки,
	# N = cap/(sin α_s·cos α_s)·sin α (на срыве — ровно cl_max и CD поляры)
	var nn := cap / maxf(sa * ca, 1.0e-6)  # cap = 0 при нулевом потоке
	var na := minf(nn * s, maxf(dyn_cn_max, nn * sa))
	var cla := na * c
	var cda := na * s - nn * sa * sa
	# центр давления — как у сорванной (blend = b): вихрь передней кромки уходит назад по хорде,
	# пикирующий момент «срыва момента» (McCroskey 1981) — не держать нос задранным
	var g := 1.0 - f
	blend[j] = b
	return Vector4(g * clv + f * cla, g * cdv + f * cda, b, g * fv + f)


## Доля обтекаемого потока полосы j (Goman & Khrabrov 1994): статическая f_ст = 1 − доля срыва по
## Δα − τ₂·Δα̇; релаксация за τ₁. Δα̇ — по прошлому вызову (dyn_dt).
func _dyn_attached(j: int, m: float, un: float) -> float:
	var fs := 1.0 - clampf(m * _inv_blend, 0.0, 1.0)
	if dyn_dt <= 0.0:
		return fs  # статика (балансировка, C_L max): состояние не трогает
	if dyn_dt > DYN_DT_MAX:
		attached[j] = fs  # первый вызов после сброса
		_m_prev[j] = m
		return fs
	var cv := chord[j] / maxf(un, 1.0)
	var mdot := (m - _m_prev[j]) / dyn_dt
	_m_prev[j] = m
	var ft := 1.0 - clampf((m - dyn_t2 * cv * mdot) * _inv_blend, 0.0, 1.0)
	var f := ft + (attached[j] - ft) * exp(-dyn_dt / (dyn_t1 * cv))
	attached[j] = f
	return f


## Доля полос с сорванным потоком.
func stall_fraction() -> float:
	var k := 0
	for i in n:
		if blend[i] > 0.01:
			k += 1
	return float(k) / maxf(n, 1)


## Сорвана середина крыла: корневые полосы обеих консолей.
func root_stalled() -> bool:
	return n > 0 and (blend[0] > 0.01 or blend[n / 2] > 0.01)
