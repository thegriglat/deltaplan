class_name PendulumWingStrips
extends RefCounted
## Аэродинамика крыла «Маятника» по полосам (strip theory, простая теория стреловидности) —
## порт tools/research/pendulum/pendulum/{geometry,model}.py (make_strips, wing_aero).
##
## Оси — связанные B (авиационные): x — вперёд по килю, y — вправо, z — вниз; начало — ЦМ крыла.
## У каждой полосы местная скорость v + ω×r − ветер; подъёмная сила ⊥ нормальной к кромке
## скорости, сопротивление — поляра игры CD(CL) за вычетом доли пилота, × cd_scale крыла.
## Сваливание полосы — линейно до cl_max поляры, дальше пластина CN = 2 (смешивание за 4°).
## Гибкий парус: антисимметричная часть нагрузки консолей × flex_relief. Флюгерная
## устойчивость — «эквивалентный киль» (Cnβ) позади ЦМ. Момент паруса — dcm0 (Cm0).

const BLEND_DEG := 4.0

var n: int = 0  ## число полос (чётное): [0, n/2) — правая консоль, [n/2, n) — левая
var r_b := PackedVector3Array()  ## точки приложения сил полос (четверть хорды), B
var c_b := PackedVector3Array()  ## хордовое направление (вперёд, ⊥ размаху), B
var n_b := PackedVector3Array()  ## нормаль панели (вниз, с поперечным V), B
var s_b := PackedVector3Array()  ## размах наружу, B
var twist := PackedFloat64Array()  ## геометрическая крутка, рад
var sc := PackedFloat64Array()  ## площадь полосы (хорда × ширина), м²
var yabs := PackedFloat64Array()  ## |y| / полуразмаха
var side := PackedFloat64Array()  ## +1 правая, −1 левая

var cos_sweep: float = 1.0
var lift_slope: float = 0.0
var alpha0_root: float = 0.0  ## α нулевой подъёмной силы киля + средняя крутка
var cl_max: float = 1.0
var polar: WingPolar
var cd_scale: float = 1.0
var cd_pilot_share: float = 0.0
var flex_relief: float = 1.0
var billow_shift: float = 0.0  ## рад на единицу tg угла стропы к крылу
var dcm0: float = 0.0
var area: float = 0.0
var chord_mean: float = 0.0
var fin_area: float = 0.0
var fin_slope: float = 0.0
var r_fin_b := Vector3.ZERO
var free_yaw := true

# результат последнего вызова aero (мир NED, около ЦМ)
var force := Vector3.ZERO
var moment := Vector3.ZERO
var lift_n: float = 0.0  ## подъёмная сила (−F_b.z), Н
var blend := PackedFloat64Array()  ## 0 — обтекание, 1 — пластина (по полосам)

# рабочие массивы
var _rw := PackedVector3Array()
var _uc := PackedFloat64Array()
var _uz := PackedFloat64Array()
var _qn := PackedFloat64Array()
var _cl := PackedFloat64Array()
var _cdx := PackedFloat64Array()
var _u := PackedVector3Array()


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
	cos_sweep = cos(sweep)
	var sl := sin(sweep)
	var sg := sin(dihedral)
	var cg := cos(dihedral)
	r_b.resize(n)
	c_b.resize(n)
	n_b.resize(n)
	s_b.resize(n)
	twist.resize(n)
	sc.resize(n)
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
			twist[i] = -washout * y / half
			sc[i] = c * half / n_side
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
	flex_relief = flex
	billow_shift = deg_to_rad(float(pend.get("billow_shift_deg", 0.0)))
	dcm0 = float(blk.dcm0)
	var yaw: Dictionary = pend.yaw
	fin_slope = float(yaw.fin_slope_per_rad)
	var fin_arm := float(yaw.fin_arm_m)
	fin_area = float(yaw.cn_beta) * area * span / (fin_slope * fin_arm)
	r_fin_b = Vector3(-fin_arm, 0.0, 0.0)
	for arr: Variant in [_rw, _uc, _uz, _qn, _cl, _cdx, _u, blend]:
		arr.resize(n)


## Сила и момент около ЦМ (мир NED) → force, moment. vel — скорость ЦМ (земля), R — B→мир,
## w — угловая скорость (мир), air — ветер в точках полос (мир, порядок r_b), air_c — в ЦМ,
## billow_lam — tg угла стропы к крылу поперёк (для billow_shift), rho — плотность.
func aero(
	vel: Vector3, R: Basis, w: Vector3, air: PackedVector3Array, air_c: Vector3,
	billow_lam: float, rho: float
) -> void:
	var Rt := R.transposed()
	var cs2 := cos_sweep * cos_sweep
	for i in n:
		var rw: Vector3 = R * r_b[i]
		_rw[i] = rw
		var u: Vector3 = Rt * (vel + w.cross(rw) - air[i])
		_u[i] = u
		var uc := u.dot(c_b[i])
		var uz := u.dot(n_b[i])
		_uc[i] = uc
		_uz[i] = uz
		var a_eff := atan2(uz, uc) * cos_sweep + twist[i]
		if billow_shift != 0.0:
			a_eff -= side[i] * billow_shift * billow_lam * yabs[i]
		# CL полосы: линейно до cl_max, дальше пластина CN = 2 (смешивание за 4°)
		var a_rel := a_eff - alpha0_root
		var a_st := cl_max / lift_slope
		var b := clampf((a_rel - a_st) / deg_to_rad(BLEND_DEG), 0.0, 1.0)
		var cl_att := minf(lift_slope * a_rel, cl_max)
		if a_rel < -a_st:
			cl_att = -cl_max
		var sa := sin(a_rel)
		_cl[i] = (1.0 - b) * cl_att + b * 2.0 * sa * cos(a_rel)
		_cdx[i] = b * maxf(2.0 * sa * sa, 0.0)
		blend[i] = b
		_qn[i] = 0.5 * rho * (uc * uc + uz * uz) / cs2
	if flex_relief < 1.0:
		# гибкий парус: разница нагрузок консолей частично снимается круткой
		var h := n / 2
		for i in h:
			var lr := _qn[i] * _cl[i]
			var ll := _qn[i + h] * _cl[i + h]
			var m := 0.5 * (lr + ll)
			var d := 0.5 * (lr - ll) * flex_relief
			_cl[i] = (m + d) / maxf(_qn[i], 1.0e-6)
			_cl[i + h] = (m - d) / maxf(_qn[i + h], 1.0e-6)
	var f_sum := Vector3.ZERO
	var m_sum := Vector3.ZERO
	for i in n:
		var cl := _cl[i]
		var cd := cd_scale * (polar.cd_at(clampf(cl, -2.0, cl_max)) - cd_pilot_share) + _cdx[i]
		var un: Vector3 = c_b[i] * _uc[i] + n_b[i] * _uz[i]
		var ld: Vector3 = s_b[i].cross(un)
		if ld.z > 0.0:
			ld = -ld
		var ln := ld.length()
		ld = ld / maxf(ln, 1.0e-9)
		var u: Vector3 = _u[i]
		var um := u.length()
		var dd := -u / maxf(um, 1.0e-9)
		var fb: Vector3 = (ld * cl + dd * cd) * (_qn[i] * sc[i])
		f_sum += fb
		m_sum += r_b[i].cross(fb)
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
	lift_n = -f_sum.z
	force = R * f_sum
	moment = R * m_sum


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
