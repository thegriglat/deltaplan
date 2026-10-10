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
