class_name PendulumModel
extends RefCounted
## Модель полёта «Маятник» (PD-К1, docs/contracts/pendulum.md): крыло — твёрдое тело с 6
## степенями свободы, подъёмная сила и сопротивление — по полосам (PendulumWingStrips), пилот —
## точка на цепи из N звеньев (PendulumPilotChain, XPBD с подшагами), руки — сила с пределом
## между пилотом и трапецией (PendulumPilotArms). Рыскание свободно (скольжение — из полос и
## «эквивалентного киля»), гибкий парус — flex_relief, поперечное V — эффективное из «Аппарата».
## Порт прототипа tools/research/pendulum/pendulum/model.py (вариант B); числа и границы —
## docs/research/pendulum.md.
##
## Внутри — мир NED (x север, y восток, z вниз) с локальным началом, которое каждый шаг
## переносится в ЦМ крыла (float32 у Vector3 иначе даёт шум скоростей из позиций вдали от нуля).
## Наружу — оси игры (X восток, Y вверх, −Z север). Земли маятника в v1 нет (PD-3): только
## касание ступнями → LANDED; reset_on_ground стартует в воздухе.

signal took_off
signal landed(result: Dictionary)
signal takeoff_failed(reason: String)

const UP := Vector3.UP
const E3 := Vector3(0.0, 0.0, 1.0)  ## вниз (NED)
const FEET_BELOW_CM_M := 1.0  ## ступни ниже ЦМ пилота вдоль его оси, м (PD-К1)
## Умолчания configs/pendulum.json (PD-К2 v1) — на случай, если файла нет.
const DEFAULTS := {
	"chain": {
		"links": 3, "strap_mass_kg": 1.0, "compliance_m_per_n": 4.0e-5,
		"substeps_per_s": 480, "substeps_min": 4,
	},
	"arms": {
		"force_max_n": 300.0, "tau_s": 0.3, "ti_s": 0.6,
		"shift_y_max_m": 0.45, "shift_x_pull_m": 0.45, "shift_x_push_m": 0.3,
	},
	"strips": {"count": 16, "cp_chord": 0.25},
	"yaw": {"cn_beta": 0.06, "fin_arm_m": 1.6, "fin_slope_per_rad": 2.0},
	"pilot_cda_m2": 0.21,
	"apparent_roll": true,
	"billow_shift_deg": 0.0,
	"head": {"forward_m": 0.75, "up_m": 0.15},
	"apparatus_defaults": {
		"hang_shift_cm": 0.0, "hang_length_m": 1.2, "sail_flex": 0.2, "dihedral_eff_deg": 1.0,
	},
}

var telemetry := Telemetry.new()
var mode: FlightModel.Mode = FlightModel.Mode.AIR
var load := LoadMeter.new()
var landing_result: Dictionary = {}
var takeoff_failure: String = ""

var wing: Dictionary = {}
var pilot: Dictionary = {}
var flight: Dictionary = {}
var pendulum: Dictionary = {}
var apparatus: Dictionary = {}
var pilot_mass: float = 0.0
var mass: float = 0.0  ## пилот + крыло, кг
var area: float = 0.0
var span: float = 0.0
var rho: float = 1.225

var position := Vector3.ZERO  ## начало узла Glider (подвеска − basis·(0, hang_height, 0))
var velocity := Vector3.ZERO  ## скорость точки position относительно земли
var heading: float = 0.0  ## курс киля, рад (0 — север, по часовой)
var bank: float = 0.0  ## крен, рад (+ вправо)
var theta: float = 0.0  ## тангаж киля, рад
var roll_rate: float = 0.0  ## рад/с, + вправо
var alpha: float = 0.0  ## угол атаки киля в ЦМ крыла, рад
var stalled: bool = false
var time_s: float = 0.0
var hang_position := Vector3.ZERO
var pilot_position := Vector3.ZERO
var pilot_velocity := Vector3.ZERO
var pilot_basis := Basis.IDENTITY
var pilot_rel := Vector3.ZERO  ## пилот − подвеска в осях крыла (игра), м
var head_position := Vector3.ZERO
var bar_force := Vector3.ZERO  ## сила рук на пилота (мир игры), Н
var strap_tension: float = 0.0

## Для тестов и опытов (не PD-К1): руки отпущены (свободный маятник) и заданное поперечное
## усилие рук, Н (+ — пилот вправо; NAN — нет).
var arms_relaxed := false
var hands_force_y: float = NAN

var strips := PendulumWingStrips.new()
var chain := PendulumPilotChain.new()
var arms := PendulumPilotArms.new()

var _polar: WingPolar
var _m_wing: float = 0.0
var _hang_len: float = 1.2
var _hang_height: float = 2.0
var _rho_ref: float = 1.225
var _cg_n := Vector3.ZERO
var _r_hang_b := Vector3.ZERO
var _r_bar_b := Vector3.ZERO
var _I_struct := Basis()
var _I_b := Basis()
var _I_inv := Basis()
var _sub_per_s: float = 480.0
var _sub_min: int = 4
var _head_fwd: float = 0.75
var _head_up: float = 0.15
var _v_trim_ref: float = 10.0
var _alpha0: float = 0.0
var _neutral_ok := false

# состояние крыла: ЦМ (локальное начало NED), скорость, B→мир, угловая скорость (мир)
var _on: float = 0.0  ## начало: север, м
var _oe: float = 0.0  ## восток, м
var _od: float = 0.0  ## вниз, м
var _pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _R := Basis.IDENTITY
var _w := Vector3.ZERO
var _air := PackedVector3Array()
var _zero_air := PackedVector3Array()
var _last_pitch: float = 0.0
var _feet_agl: float = INF


static func ned(g: Vector3) -> Vector3:
	return Vector3(-g.z, g.x, -g.y)


static func game(n: Vector3) -> Vector3:
	return Vector3(n.y, -n.z, -n.x)


## Матрица B→NED по курсу, тангажу, крену (ZYX).
static func basis_from_euler(ps: float, th: float, ph: float) -> Basis:
	var cps := cos(ps)
	var sps := sin(ps)
	var cth := cos(th)
	var sth := sin(th)
	var cph := cos(ph)
	var sph := sin(ph)
	return Basis(
		Vector3(cth * cps, cth * sps, -sth),
		Vector3(sph * sth * cps - cph * sps, sph * sth * sps + cph * cps, sph * cth),
		Vector3(cph * sth * cps + sph * sps, cph * sth * sps - sph * cps, cph * cth)
	)


static func _log_rot(b: Basis) -> Vector3:
	var q := b.get_rotation_quaternion()
	var vv := Vector3(q.x, q.y, q.z)
	var w := q.w
	if w < 0.0:
		vv = -vv
		w = -w
	var s := vv.length()
	if s < 1.0e-9:
		return vv * 2.0
	return vv * (2.0 * atan2(s, w) / s)


## wing_cfg — конфиг крыла с блоком pendulum (PD-К2), pilot_cfg — pilot.json (mass_kg уже
## ограничена), flight_override — правки flight.json, apparatus_cfg — настройки «Аппарат» (PD-К3).
func setup(
	wing_cfg: Dictionary, pilot_cfg: Dictionary, flight_override: Dictionary = {},
	apparatus_cfg: Dictionary = {}
) -> void:
	wing = wing_cfg
	pilot = pilot_cfg
	flight = Config._deep_merge(Config.get_config("flight"), flight_override)
	pendulum = DEFAULTS.duplicate(true)
	if FileAccess.file_exists("res://configs/pendulum.json"):
		pendulum = Config._deep_merge(pendulum, Config.get_config("pendulum"))
	apparatus = Config._deep_merge(pendulum.apparatus_defaults, apparatus_cfg)
	if not wing.has("pendulum"):
		push_error("PendulumModel: в конфиге крыла нет блока pendulum (PD-К2)")
		return
	var blk: Dictionary = wing.pendulum
	area = float(wing.area_m2)
	span = float(wing.span_m)
	_m_wing = float(wing.wing_mass_kg)
	pilot_mass = float(pilot.mass_kg)
	mass = pilot_mass + _m_wing
	_rho_ref = float(flight.air_density.polar_ref_kgm3)
	rho = _rho_ref
	var mass_ref := float(wing.pilot_mass_ref_kg) + _m_wing
	_polar = WingPolar.new(wing.polar.points_kmh_ms, mass_ref, _rho_ref, area)
	_v_trim_ref = Units.kmh(float(wing.trim_speed_kmh))
	_alpha0 = deg_to_rad(float(wing.zero_lift_alpha_deg))
	_hang_height = float(flight.visual.hang_height_m)
	_hang_len = float(apparatus.hang_length_m)
	var ch: Dictionary = pendulum.chain
	_sub_per_s = float(ch.substeps_per_s)
	_sub_min = int(ch.substeps_min)
	_head_fwd = float(pendulum.head.forward_m)
	_head_up = float(pendulum.head.up_m)
	# геометрия в осях «от носа» N (x назад по килю, z вниз) → связанные B около ЦМ крыла
	_cg_n = Vector3(float(blk.cg_x_from_nose_m), 0.0, -float(blk.cg_z_m))
	var shift := float(apparatus.hang_shift_cm) / 100.0
	var x_hang := float(blk.hang_from_nose_m) - shift
	_r_hang_b = Vector3(_cg_n.x - x_hang, 0.0, -_cg_n.z)
	# трапеция висит на подвеске: сдвигается вместе с ней (как в прототипе)
	var bar_x := float(blk.bar_x_from_nose_m) - shift
	_r_bar_b = Vector3(_cg_n.x - bar_x, 0.0, -float(blk.bar_z_m) - _cg_n.z)
	var ine: Dictionary = blk.inertia_kgm2
	var ixz := float(ine.get("ixz", 0.0))
	_I_struct = Basis(
		Vector3(float(ine.ixx), 0.0, ixz), Vector3(0.0, float(ine.iyy), 0.0),
		Vector3(ixz, 0.0, float(ine.izz))
	)
	_I_b = _I_struct
	if bool(pendulum.apparent_roll):
		# присоединённая масса воздуха по крену: π/48·ρ·c²·b³ (пластина)
		var c := area / span
		_I_b.x.x += PI / 48.0 * _rho_ref * c * c * pow(span, 3)
	_I_inv = _I_b.inverse()
	strips.setup(
		wing, blk, pendulum, _polar, deg_to_rad(float(apparatus.dihedral_eff_deg)),
		float(apparatus.sail_flex), _cg_n
	)
	_air.resize(strips.n)
	_zero_air.resize(strips.n)
	chain.setup(ch, pilot_mass, _hang_len)
	arms.setup(pendulum.arms)
	_neutral_ok = false
	telemetry = Telemetry.new()


## Старт в воздухе: установившееся планирование на триме (airspeed_ms > 0 — с этой воздушной
## скоростью на траектории трима), пилот висит в равновесии, ω = 0, курс по потоку.
func reset_in_air(
	pos: Vector3, heading_deg: float, airspeed_ms: float = 0.0, wind: Vector3 = Vector3.ZERO
) -> void:
	_reset_common()
	rho = air_density(pos.y)
	var st := solve_trim()
	var ps := deg_to_rad(heading_deg)
	var g: float = st.gamma
	var V: float = st.V
	if airspeed_ms > 0.0:
		V = airspeed_ms
	_R = basis_from_euler(ps, float(st.theta), 0.0)
	_vel = Vector3(cos(g) * cos(ps), cos(g) * sin(ps), sin(g)) * V + ned(wind)
	_place_wing(pos)
	var h := _pos + _R * _r_hang_b
	chain.place(h, _R * Vector3(st.pilot_dir_b), _vel)
	mode = FlightModel.Mode.AIR
	_update_outputs(Callable(), Callable())


## v1 (до PD-3): земли маятника нет — старт в воздухе на 100 м выше.
func reset_on_ground(pos: Vector3, heading_deg: float) -> void:
	push_error("PendulumModel v1: reset_on_ground не поддерживается — старт в воздухе (PD-3)")
	reset_in_air(pos + Vector3(0.0, 100.0, 0.0), heading_deg)


## Буксир (NET-42): крыло жёстко в заданное положение, пилот в равновесии под подвеской, ω = 0.
func set_kinematic(pos: Vector3, vel: Vector3, heading_: float, bank_: float, theta_: float) -> void:
	if not _neutral_ok:
		rho = air_density(pos.y)
		solve_trim()
	_R = basis_from_euler(heading_, theta_, bank_)
	_vel = ned(vel)
	_w = Vector3.ZERO
	_place_wing(pos)
	var h := _pos + _R * _r_hang_b
	chain.place(h, E3, _vel)
	arms.reset()
	mode = FlightModel.Mode.AIR
	_update_outputs(Callable(), Callable())


## Один шаг: dt 1/240…1/30 с; подшагов max(substeps_min, ceil(dt·substeps_per_s)).
func step(dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> void:
	if mode != FlightModel.Mode.AIR:
		_update_outputs(air_fn, ground_fn)
		return
	time_s += dt
	rho = air_density(-(_od + _pos.z))
	_recentre()
	var n := maxi(_sub_min, ceili(dt * _sub_per_s - 1.0e-9))
	var h := dt / n
	_last_pitch = input.pitch
	for _k in n:
		_substep(h, input, air_fn)
	var lf: Dictionary = flight.load_factor
	var f_p := chain.pilot_force + _R * arms.force_b
	load.update(
		f_p.length(), pilot_mass * Units.G, float(lf.filter_s), dt, float(lf.jitter_window_s)
	)
	_update_outputs(air_fn, ground_fn)
	_check_touchdown(ground_fn)


## Значения Telemetry.phase.
func phase() -> String:
	match mode:
		FlightModel.Mode.AIR:
			return "flying"
		FlightModel.Mode.LANDED:
			return "landed"
		FlightModel.Mode.FAILED:
			return "failed"
	return "standing"


## v1: доля «от себя» (0…1) только ниже flight.flare.height_m (ступни над землёй), иначе 0.
func flare_amount() -> float:
	if mode != FlightModel.Mode.AIR or _feet_agl > float(flight.flare.height_m):
		return 0.0
	return clampf(_last_pitch, 0.0, 1.0)


## Доля сорванных полос.
func stall_amount() -> float:
	return strips.stall_fraction()


## Плотность воздуха на высоте, кг/м³ (как FlightModel).
func air_density(altitude_m: float) -> float:
	var ad: Dictionary = flight.air_density
	if not bool(ad.altitude_dependent):
		return _rho_ref
	return float(ad.sea_level_kgm3) * exp(-altitude_m / float(ad.scale_height_m))


## Ориентация крыла в осях игры (−Z вперёд по килю, +Y вверх, +X вправо).
func wing_basis() -> Basis:
	return Basis(game(_R * Vector3(0, 1, 0)), game(_R * Vector3(0, 0, -1)), game(_R * Vector3(-1, 0, 0)))


# ------------------------------------------------------------------ балансировка
## При угле атаки киля a: скорость и наклон траектории, при которых крыло с пилотом
## уравновешены (руки без усилия). → {V, gamma, alpha, theta, M (момент около подвески по
## тангажу, Н·м), pilot_dir_b}. Порт trim.glide_balance.
func glide_balance(a: float, v0: float) -> Dictionary:
	var V := v0
	var gam := 0.1
	var cda := float(pendulum.pilot_cda_m2)
	for _it in 30:
		var R := basis_from_euler(0.0, a - gam, 0.0)
		var vel := Vector3(cos(gam), 0.0, sin(gam)) * V
		strips.aero(vel, R, Vector3.ZERO, _zero_air, Vector3.ZERO, 0.0, rho)
		var dp := -0.5 * rho * cda * V * vel
		var F := strips.force + dp + E3 * (mass * Units.G)
		var u := vel / V
		var nn := Vector3(-sin(gam), 0.0, cos(gam))
		var fn := F.dot(nn)
		var L := -(strips.force + dp).dot(nn)
		var D := -(strips.force + dp).dot(u)
		var gam_new := atan2(D, L)
		V = minf(V * sqrt(minf(maxf(1.0 + fn / maxf(L, 1.0), 0.25), 4.0)), 80.0)
		var done := absf(gam_new - gam) < 1.0e-7 and absf(fn) < 1.0e-3
		gam = gam_new
		if done:
			break
	var R2 := basis_from_euler(0.0, a - gam, 0.0)
	var vel2 := Vector3(cos(gam), 0.0, sin(gam)) * V
	strips.aero(vel2, R2, Vector3.ZERO, _zero_air, Vector3.ZERO, 0.0, rho)
	var dp2 := -0.5 * rho * cda * V * vel2
	var rh := R2 * _r_hang_b
	var mh := strips.moment + (-rh).cross(strips.force + E3 * (_m_wing * Units.G))
	var load_v := E3 * (pilot_mass * Units.G) + dp2
	var d_b := R2.transposed() * load_v.normalized()
	return {
		"V": V, "gamma": gam, "alpha": a, "theta": a - gam,
		"M": (R2.transposed() * mh).y, "pilot_dir_b": d_b,
	}


## Угол атаки, при котором момент около подвески 0 (руки без усилия); задаёт нейтраль рук.
func solve_trim() -> Dictionary:
	var lo := _alpha0 + deg_to_rad(3.0)
	var hi := deg_to_rad(28.0)
	var mlo: float = glide_balance(lo, _v_trim_ref).M
	for _it in 50:
		var mid := 0.5 * (lo + hi)
		var mm: float = glide_balance(mid, _v_trim_ref).M
		if mm * mlo > 0.0:
			lo = mid
			mlo = mm
		else:
			hi = mid
	var st := glide_balance(0.5 * (lo + hi), _v_trim_ref)
	arms.neutral_rel = Vector3(st.pilot_dir_b) * _hang_len
	_neutral_ok = true
	return st


# ------------------------------------------------------------------ шаг
func _substep(h: float, input: ControlInput, air_fn: Callable) -> void:
	var R := _R
	var Rt := R.transposed()
	var rh: Vector3 = R * _r_hang_b
	var H := _pos + rh
	var xp := chain.pilot()
	var vp := chain.pilot_vel()
	# воздух в точках полос и пилота
	var air_c := Vector3.ZERO
	var air_p := Vector3.ZERO
	if air_fn.is_valid():
		for i in strips.n:
			_air[i] = _air_at(air_fn, _pos + R * strips.r_b[i])
		air_c = _air_at(air_fn, _pos)
		air_p = _air_at(air_fn, xp)
	var lam := 0.0
	if strips.billow_shift != 0.0:
		var d_b := Rt * (chain.x[0] - H)
		lam = d_b.y / maxf(d_b.z, 1.0e-3)
	strips.aero(_vel, R, _w, _air if air_fn.is_valid() else _zero_air, air_c, lam, rho)
	var f_w := strips.force + E3 * (_m_wing * Units.G)
	var m_w := strips.moment
	# пилот: вес, сопротивление (CD·A)_п, руки
	var va := vp - air_p
	var f_p := E3 * (pilot_mass * Units.G) - va * (0.5 * rho * float(pendulum.pilot_cda_m2) * va.length())
	var rel := Rt * (xp - H)
	var vh := _vel + _w.cross(rh)
	var vrel := Rt * (vp - vh - _w.cross(xp - H))
	var fb := arms.compute(
		rel, vrel, input.roll, input.pitch, pilot_mass, h, arms_relaxed, hands_force_y
	)
	if fb != Vector3.ZERO:
		var fh: Vector3 = R * fb
		f_p += fh
		# продольная сила рук — в середине штанги (момент по тангажу); поперечная — на высоте
		# штанги, но на продольной координате ЦМ пилота (пилот держит тело ⊥ штанге: пара
		# «штанга — стропа» по рысканию на крыло не передаётся; Takamatsu & Ochi 2022)
		var rb_x: Vector3 = R * _r_bar_b
		var r_pil_b := Rt * (xp - _pos)
		var rb_y: Vector3 = R * Vector3(r_pil_b.x, 0.0, _r_bar_b.z)
		f_w -= fh
		m_w += rb_x.cross(-(R * Vector3(fb.x, 0.0, 0.0))) + rb_y.cross(-(R * Vector3(0.0, fb.y, 0.0)))
	# скорости и позиции
	var pos_prev := _pos
	var r_prev := R
	var x_prev := chain.x.duplicate()
	_vel += f_w * (h / _m_wing)
	var wb := Rt * _w
	var tb := Rt * m_w
	# гироскопический член — по инерции конструкции (присоединённая масса — не твёрдое тело)
	wb += _I_inv * (tb - wb.cross(_I_struct * wb)) * h
	_w = R * wb
	_pos += _vel * h
	var ang := _w.length() * h
	if ang > 1.0e-12:
		R = Basis(_w.normalized(), ang) * R
	chain.integrate(h, f_p)
	# связи цепи
	var iw_inv := R * _I_inv * R.transposed()
	chain.project(h, _pos, R, _r_hang_b, _m_wing, iw_inv)
	_pos = chain.wing_pos
	_R = chain.wing_R.orthonormalized()
	# скорости из позиций
	_vel = (_pos - pos_prev) / h
	_w = _log_rot(_R * r_prev.transposed()) / h
	chain.velocities_from(x_prev, h)


func _air_at(air_fn: Callable, p_local: Vector3) -> Vector3:
	var g: Vector3 = air_fn.call(_world(p_local))
	return Vector3(-g.z, g.x, -g.y)


## Точка в мире игры по локальной NED (сложение в float64, потом в Vector3).
func _world(p: Vector3) -> Vector3:
	return Vector3(_oe + p.y, -(_od + p.z), -(_on + p.x))


## Перенос локального начала в ЦМ крыла.
func _recentre() -> void:
	var d := _pos
	_on += d.x
	_oe += d.y
	_od += d.z
	_pos = Vector3.ZERO
	chain.shift(-d)


## Крыло по точке position узла Glider (pos — мир игры) при текущих _R.
func _place_wing(pos: Vector3) -> void:
	_on = -pos.z
	_oe = pos.x
	_od = -pos.y
	# подвеска = position + (вверх по крылу)·hang_height; вверх по крылу в B — −z
	var h_loc := _R * Vector3(0.0, 0.0, -_hang_height)
	_pos = h_loc - _R * _r_hang_b
	_recentre()


func _reset_common() -> void:
	time_s = 0.0
	_w = Vector3.ZERO
	arms.reset()
	load.reset()
	landing_result = {}
	takeoff_failure = ""
	_feet_agl = INF
	_last_pitch = 0.0


func _check_touchdown(ground_fn: Callable) -> void:
	if not ground_fn.is_valid():
		return
	var feet := pilot_position - pilot_basis.y * FEET_BELOW_CM_M
	var gh := FlightModel.ground_height(ground_fn, feet.x, feet.z)
	_feet_agl = feet.y - gh
	if _feet_agl > 0.0:
		return
	var lc: Dictionary = flight.landing
	var nrm := LandingJudge.ground_normal(ground_fn, feet.x, feet.z, float(lc.normal_sample_m))
	var result := LandingJudge.evaluate(pilot_velocity, nrm, rad_to_deg(bank), lc)
	result["position"] = Vector3(feet.x, gh, feet.z)
	result["flight_time_s"] = time_s
	landing_result = result
	mode = FlightModel.Mode.LANDED
	_vel = Vector3.ZERO
	_w = Vector3.ZERO
	chain.stop()
	_update_outputs(Callable(), ground_fn)
	landed.emit(result)


func _update_outputs(air_fn: Callable, ground_fn: Callable) -> void:
	var R := _R
	theta = -asin(clampf(R.x.z, -1.0, 1.0))
	bank = atan2(R.y.z, R.z.z)
	heading = atan2(R.x.y, R.x.x)
	roll_rate = (R.transposed() * _w).x
	var bg := wing_basis()
	var h_loc := _pos + R * _r_hang_b
	var p_loc := h_loc + R * Vector3(0.0, 0.0, _hang_height)
	hang_position = _world(h_loc)
	position = _world(p_loc)
	velocity = game(_vel + _w.cross(p_loc - _pos))
	var air_c := Vector3.ZERO
	if air_fn.is_valid() and mode == FlightModel.Mode.AIR:
		air_c = _air_at(air_fn, _pos)
	var vb := R.transposed() * (_vel - air_c)
	alpha = atan2(vb.z, vb.x)
	stalled = strips.root_stalled()
	var xp := chain.pilot()
	pilot_position = _world(xp)
	pilot_velocity = game(chain.pilot_vel())
	var rel_g := game(xp - h_loc)
	pilot_rel = bg.transposed() * rel_g
	var up := -rel_g.normalized()
	pilot_basis = Basis(Quaternion(bg.y, up)) * bg if up.length() > 0.5 else bg
	head_position = pilot_position + pilot_basis * Vector3(0.0, _head_up, -_head_fwd)
	bar_force = game(R * arms.force_b)
	strap_tension = chain.tension
	_fill_telemetry(air_c, ground_fn, bg)


func _fill_telemetry(air_c_ned: Vector3, ground_fn: Callable, bg: Basis) -> void:
	var t := telemetry
	t.time_s = time_s
	t.phase = phase()
	t.position = position
	t.velocity = velocity
	t.air_velocity = game(_vel - air_c_ned)
	t.airspeed = t.air_velocity.length()
	t.groundspeed = Vector2(velocity.x, velocity.z).length()
	t.vario = velocity.y
	t.altitude_msl = position.y
	var gh := FlightModel.ground_height(ground_fn, position.x, position.z)
	t.altitude_agl = position.y - gh if gh > -INF else position.y
	t.heading_deg = fposmod(rad_to_deg(heading), 360.0)
	t.track_deg = t.heading_deg
	if t.groundspeed > 0.1:
		t.track_deg = fposmod(rad_to_deg(atan2(velocity.x, -velocity.z)), 360.0)
	t.bank_deg = rad_to_deg(bank)
	t.pitch_deg = rad_to_deg(theta)
	t.on_ground = mode != FlightModel.Mode.AIR
	t.stalled = stalled
	t.glide_ratio = t.groundspeed / -velocity.y if velocity.y < -0.05 else 0.0
	t.basis = bg
	t.pilot_position = pilot_position
	t.pilot_velocity = pilot_velocity
	t.pilot_basis = pilot_basis
	t.load_factor = load.load_factor
	t.flare_amount = flare_amount()
