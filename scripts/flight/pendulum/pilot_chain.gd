class_name PendulumPilotChain
extends RefCounted
## Подвеска «Маятника»: цепь из N звеньев от точки подвески на киле до ЦМ пилота (последний
## узел). Связи XPBD (Macklin et al. 2019, «Small Steps»): звено только тянет (провисает без
## сопротивления), податливость стропы делится на звенья. Первое звено тянет крыло как твёрдое
## тело (масса и инерция в точке подвески). Порт цикла связей Sim._substep
## (tools/research/pendulum/pendulum/model.py). Координаты — мир NED (локальное начало модели).

var links: int = 3
var link_len: float = 0.4
var compliance: float = 4.0e-5  ## м/Н на всю подвеску
var x := PackedVector3Array()  ## узлы 1..N (последний — пилот), м
var v := PackedVector3Array()  ## их скорости, м/с
var m := PackedFloat64Array()  ## массы узлов, кг
var inv_m := PackedFloat64Array()
var _prev := PackedVector3Array()

# результат последней проекции
var wing_pos := Vector3.ZERO
var wing_R := Basis.IDENTITY
var tension: float = 0.0  ## натяжение верхнего звена, Н (≥ 0)
var pilot_force := Vector3.ZERO  ## сила последнего звена на пилота, Н (мир)
var max_stretch: float = 0.0  ## наибольшее растяжение звена с последнего сброса, м
# результат project_bridle (TW-К4 v6)
var bridle_f_pilot := Vector3.ZERO
var bridle_f_hang := Vector3.ZERO
var bridle_t_pilot: float = 0.0
var bridle_t_hang: float = 0.0


func setup(chain: Dictionary, m_pilot: float, hang_len: float) -> void:
	links = maxi(int(chain.links), 1)
	link_len = hang_len / links
	compliance = float(chain.compliance_m_per_n)
	var ms := float(chain.strap_mass_kg) / maxf(links - 1, 1)
	x.resize(links)
	v.resize(links)
	m.resize(links)
	inv_m.resize(links)
	_prev.resize(links)
	for i in links:
		m[i] = ms
	m[links - 1] = m_pilot
	for i in links:
		inv_m[i] = 1.0 / m[i]


## Цепь прямая от h_pt по направлению dir (единичный), все узлы со скоростью vel.
func place(h_pt: Vector3, dir: Vector3, vel: Vector3) -> void:
	for i in links:
		x[i] = h_pt + dir * (link_len * (i + 1))
		v[i] = vel
	max_stretch = 0.0


func pilot() -> Vector3:
	return x[links - 1]


func pilot_vel() -> Vector3:
	return v[links - 1]


## Проекция связей на шаге h. pos, R — ЦМ и ориентация крыла; r_hang_b — подвеска в осях B;
## m_wing — масса крыла; iw_inv — обратный тензор инерции крыла в мировых осях.
## Результат — wing_pos, wing_R, tension, pilot_force.
func project(
	h: float, pos: Vector3, R: Basis, r_hang_b: Vector3, m_wing: float, iw_inv: Basis
) -> void:
	var alpha_t := compliance / links / (h * h)
	var t := 0.0
	var pf := Vector3.ZERO
	for i in links:
		var b: Vector3 = x[i]
		var a: Vector3 = pos + R * r_hang_b if i == 0 else x[i - 1]
		var d := b - a
		var L := d.length()
		var C := L - link_len
		if C <= 0.0 or L < 1.0e-9:
			continue
		var nn := d / L
		var wb := inv_m[i]
		var wa: float
		var r := Vector3.ZERO
		if i == 0:
			r = a - pos
			var rn := r.cross(nn)
			wa = 1.0 / m_wing + rn.dot(iw_inv * rn)
		else:
			wa = inv_m[i - 1]
		var dl := -C / (wa + wb + alpha_t)
		x[i] = b + nn * (wb * dl)
		if i == 0:
			pos -= nn * (dl / m_wing)
			var dth: Vector3 = iw_inv * r.cross(-dl * nn)
			var ang := dth.length()
			if ang > 1.0e-12:
				R = Basis(dth / ang, ang) * R
			t = -dl / (h * h)
		else:
			x[i - 1] = a - nn * (wa * dl)
		if i == links - 1:
			pf = nn * (dl / (h * h))
		max_stretch = maxf(max_stretch, C)
	wing_pos = pos
	wing_R = R
	tension = t
	pilot_force = pf


## TW-К4: одностороннее звено XPBD «якорь — ЦМ пилота» (трос): C = |x − якорь| − length, действует
## только при C > 0; податливость comp (м/Н) → α/h², демпфирование tau (с) — XPBD с демпфированием,
## γ = tau/h (сила k·(C + tau·Ċ)). Якорь — бесконечная масса, движется со скоростью anchor_vel; демпфирование по скорости растяжения
## Ċ = n·(v − anchor_vel) − length_rate (dL/dt лебёдки), не по абсолютной скорости тела. → натяжение λ/h², Н (≥ 0).
## Вызывать после integrate, до project: позиции до шага запомнил integrate.
func project_anchor(
	h: float, anchor: Vector3, length: float, comp: float, tau: float,
	anchor_vel := Vector3.ZERO, length_rate := 0.0
) -> float:
	var i := links - 1
	var d: Vector3 = x[i] - anchor
	var L := d.length()
	var C := L - length
	if C <= 0.0 or L < 1.0e-9:
		return 0.0
	var nn := d / L
	var w := inv_m[i]
	var g := tau / h
	var c_dot_h := nn.dot((x[i] - _prev[i]) - anchor_vel * h) - length_rate * h  # Ċ·h: скорость растяжения
	var dl := (-C - g * c_dot_h) / ((1.0 + g) * w + comp / (h * h))
	if dl >= 0.0:  # трос не толкает
		return 0.0
	x[i] += nn * (w * dl)
	return -dl / (h * h)


## TW-К4 v6: уздечка — два параллельных односторонних звена XPBD «якорь — ЦМ пилота» (доля share, податливость
## comp/share) и «якорь — точка подвески на киле» (доля 1 − share, comp/(1 − share), с моментом на крыле) решаются
## ВМЕСТЕ со связями цепи подвески: iters проходов Гаусса–Зейделя с накоплением множителей λ (XPBD), потому что
## один проход «звено на крыло, затем цепь» не учитывает массу пилота под подвеской (звено видит только m_wing,
## цепь возвращает крыло — рывки натяжения). Суммарная жёсткость плеч = EA/L. Односторонность — зажим накопленного
## λ ≤ 0 (плечо может отдать натяжение внутри шага). lk: anchor, length, comp, tau, avel, lrate; hang_prev —
## точка подвески на начало шага; i_inv_b — обратный тензор инерции крыла в осях B. Результат — как у project, плюс
## bridle_f_pilot, bridle_f_hang (сила плеча на тело, мир), bridle_t_pilot, bridle_t_hang (Н).
func project_bridle(
	h: float, pos: Vector3, R: Basis, r_hang_b: Vector3, m_wing: float, i_inv_b: Basis,
	lk: Dictionary, share: float, hang_prev: Vector3, iters: int
) -> void:
	var inv_h2 := 1.0 / (h * h)
	var alpha_t := compliance / links * inv_h2
	var g: float = lk.tau / h
	var anchor: Vector3 = lk.anchor
	var s := clampf(share, 0.0, 1.0)
	var comp: float = lk.comp
	var a_p: float = comp / maxf(s, 1.0e-9) * inv_h2
	var a_h: float = comp / (1.0 - s) * inv_h2
	var lam_p := 0.0
	var lam_h := 0.0
	var lam_c := PackedFloat64Array()
	lam_c.resize(links)
	var last := links - 1
	var wp := inv_m[last]
	for _k in iters:
		var iw_inv := R * i_inv_b * R.transposed()
		# плечо на пилота
		if s > 0.0:
			var d: Vector3 = x[last] - anchor
			var L := d.length()
			if L > 1.0e-9:
				var nn := d / L
				var cdh: float = nn.dot((x[last] - _prev[last]) - lk.avel * h) - lk.lrate * h
				var dl: float = (-(L - lk.length) - a_p * lam_p - g * cdh) / ((1.0 + g) * wp + a_p)
				var nl := minf(lam_p + dl, 0.0)
				dl = nl - lam_p
				lam_p = nl
				x[last] += nn * (wp * dl)
		# плечо на подвеске крыла
		if s < 1.0:
			var r := R * r_hang_b
			var d: Vector3 = pos + r - anchor
			var L := d.length()
			if L > 1.0e-9:
				var nn := d / L
				var rn := r.cross(nn)
				var w := 1.0 / m_wing + rn.dot(iw_inv * rn)
				var cdh: float = nn.dot((pos + r - hang_prev) - lk.avel * h) - lk.lrate * h
				var dl: float = (-(L - lk.length) - a_h * lam_h - g * cdh) / ((1.0 + g) * w + a_h)
				var nl := minf(lam_h + dl, 0.0)
				dl = nl - lam_h
				lam_h = nl
				pos += nn * (dl / m_wing)
				var dth: Vector3 = iw_inv * r.cross(nn * dl)
				var ang := dth.length()
				if ang > 1.0e-12:
					R = Basis(dth / ang, ang) * R
		# связи цепи
		iw_inv = R * i_inv_b * R.transposed()
		for i in links:
			var b: Vector3 = x[i]
			var a: Vector3 = pos + R * r_hang_b if i == 0 else x[i - 1]
			var d := b - a
			var L := d.length()
			if L < 1.0e-9:
				continue
			var C := L - link_len
			var nn := d / L
			var wb := inv_m[i]
			var wa: float
			var r := Vector3.ZERO
			if i == 0:
				r = a - pos
				var rn := r.cross(nn)
				wa = 1.0 / m_wing + rn.dot(iw_inv * rn)
			else:
				wa = inv_m[i - 1]
			var dl := (-C - alpha_t * lam_c[i]) / (wa + wb + alpha_t)
			var nl := minf(lam_c[i] + dl, 0.0)
			dl = nl - lam_c[i]
			lam_c[i] = nl
			x[i] = b + nn * (wb * dl)
			if i == 0:
				pos -= nn * (dl / m_wing)
				var dth: Vector3 = iw_inv * r.cross(-dl * nn)
				var ang := dth.length()
				if ang > 1.0e-12:
					R = Basis(dth / ang, ang) * R
			else:
				x[i - 1] = a - nn * (wa * dl)
			if _k == iters - 1:
				max_stretch = maxf(max_stretch, C)
	wing_pos = pos
	wing_R = R
	tension = -lam_c[0] * inv_h2
	var dn: Vector3 = x[last] - (pos + R * r_hang_b if last == 0 else x[last - 1])
	pilot_force = dn.normalized() * (lam_c[last] * inv_h2) if dn.length() > 1.0e-9 else Vector3.ZERO
	bridle_t_pilot = -lam_p * inv_h2
	bridle_t_hang = -lam_h * inv_h2
	bridle_f_pilot = Vector3.ZERO
	bridle_f_hang = Vector3.ZERO
	if lam_p < 0.0:
		bridle_f_pilot = (anchor - x[last]).normalized() * bridle_t_pilot
	if lam_h < 0.0:
		bridle_f_hang = (anchor - (pos + R * r_hang_b)).normalized() * bridle_t_hang


## Явный шаг узлов: вес промежуточных узлов, у пилота — f_pilot (вес + сопротивление + руки).
## Запоминает позиции до шага (для скоростей из позиций).
func integrate(h: float, f_pilot: Vector3) -> void:
	var last := links - 1
	for i in links:
		_prev[i] = x[i]
		var f := Vector3(0.0, 0.0, m[i] * Units.G) if i < last else f_pilot
		v[i] += f * (h * inv_m[i])
		x[i] += v[i] * h


## Скорости узлов из позиций (XPBD): (x − x_prev) / h.
func velocities_from_prev(h: float) -> void:
	for i in links:
		v[i] = (x[i] - _prev[i]) / h


func shift(d: Vector3) -> void:
	for i in links:
		x[i] += d


func stop() -> void:
	for i in links:
		v[i] = Vector3.ZERO
