class_name PendulumModel
extends RefCounted
## Модель полёта «Маятник» (PD-К1, docs/contracts/pendulum.md): крыло — твёрдое тело с 6
## степенями свободы, подъёмная сила и сопротивление — по полосам (PendulumWingStrips), пилот —
## точка на цепи из N звеньев (PendulumPilotChain, XPBD с подшагами), руки — сила с пределом
## между пилотом и трапецией (PendulumPilotArms). Рыскание свободно (скольжение — из полос и
## «эквивалентного киля»), гибкий парус — перекос пузыря (крутка консолей от угла стропы), поперечное V — эффективное из «Аппарата».
## Порт прототипа tools/research/pendulum/pendulum/model.py (вариант B); числа и границы —
## docs/research/pendulum.md.
##
## Внутри — мир NED (x север, y восток, z вниз) с локальным началом, которое каждый шаг
## переносится в ЦМ крыла (float32 у Vector3 иначе даёт шум скоростей из позиций вдали от нуля).
## Наружу — оси игры (X восток, Y вверх, −Z север).
##
## Земля (PD-К1 v2, PD-3; R6 плана) — PendulumGround: ноги — пружина-демпфер, руки держат стойки
## (_uprights). Отрыв — ступни перестали касаться земли под нагрузкой стропы; руки на штангу —
## через ground.bar_after_liftoff_s или когда ступни выше takeoff.upright_clear_m. Посадка —
## касание ступнями (PendulumTouchdown по скорости ЦМ пилота, PD-35); консоль или нос раньше ступней — авария.
## После посадки без аварии пилот снова на ногах с крылом на руках (пробежка, run/walk — снова
## разбег).

signal took_off
signal landed(result: Dictionary)
signal takeoff_failed(reason: String)

const UP := Vector3.UP
const E3 := Vector3(0.0, 0.0, 1.0)  ## вниз (NED)
## Умолчания configs/pendulum.json (PD-К2 v1) — на случай, если файла нет.
const DEFAULTS := {
	"chain": {
		"links": 3, "strap_mass_kg": 1.0, "compliance_m_per_n": 4.0e-5,
		"substeps_per_s": 480, "substeps_min": 4,
	},
	"arms": {
		"force_max_n": 300.0, "tau_s": 0.3, "ti_s": 0.0,
		"shift_y_max_m": 0.45, "shift_x_pull_m": 0.45, "shift_x_push_m": 0.3,
	},
	"strips": {"count": 16, "cp_chord": 0.25, "aero_hz": 60.0},
	"yaw": {"cn_beta": 0.05, "fin_arm_m": 1.6, "fin_slope_per_rad": 2.0, "cn_p_add": 0.15, "cn_r_add": -0.03},
	"pilot_cda_m2": 0.21,
	"apparent_roll": true,
	"billow_shift_deg": 40.0,
	"head": {"forward_m": 0.75, "up_m": 0.15},
	"ground": {
		"leg_length_m": 1.0, "leg_stiffness_n_per_m": 3.0e4, "foot_friction": 0.8,
		"side_damping_n_s_per_m": 2000.0, "stand_stiffness_n_per_m": 2.0e4,
		"shoulder_forward_m": 0.35, "shoulder_up_m": 0.45, "grip_along_upright_m": 0.7,
		"grip_stiffness_n_per_m": 3000.0, "grip_force_max_n": 600.0, "grip_down_max_n": 100.0,
		"pitch_hold_nm_per_deg": 30.0, "pitch_hold_ti_s": 0.5, "pitch_moment_max_nm": 300.0,
		"liftoff_feet_clear_m": 0.05, "liftoff_strap_fraction": 0.25, "bar_after_liftoff_s": 1.0,
		"fell_cm_height_m": 0.5,
	},
	"ground_effect": {"enabled": true, "span_efficiency": 0.9},
	"strip_cl_max_match_polar": true,
	"stall_cp_shift": true,
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
var pilot_shift := Vector2.ZERO  ## смещение пилота от нейтрали / предел хода (FB-К1): x + вправо, y + к носу
var head_position := Vector3.ZERO
var bar_force := Vector3.ZERO  ## сила рук на пилота (мир игры), Н
var strap_tension: float = 0.0

## Для тестов и опытов (не PD-К1): руки отпущены (свободный маятник) и заданное поперечное
## усилие рук, Н (+ — пилот вправо; NAN — нет).
var arms_relaxed := false
var hands_force_y: float = NAN
## Частота пересчёта аэродинамики полос и выборки ветра, Гц — configs/pendulum.json →
## strips.aero_hz (PD-К2 v2; ≤ 0 — на каждом подшаге, как прототип); между пересчётами сила и
## момент заморожены в осях крыла. Цепь и руки — на каждом подшаге.
var aero_hz: float = 60.0

var strips := PendulumWingStrips.new()
var chain := PendulumPilotChain.new()
var arms := PendulumPilotArms.new()
var ground := PendulumGround.new()

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
var _ground_neutral := Vector3.ZERO  ## pilot_rel в позе стоя при постановке на землю (FB-К1)

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
var _ge := PackedFloat64Array()  ## σ экранного эффекта по полосам (последний пересчёт аэродинамики)
var _ge_on := true
var _last_pitch: float = 0.0
var _air_p := Vector3.ZERO
var _aero_age: float = INF  ## время с последнего пересчёта аэродинамики, с
var _air_c := Vector3.ZERO  ## ветер в ЦМ крыла при последнем пересчёте аэродинамики (NED)
var _aero_f_b := Vector3.ZERO
var _aero_m_b := Vector3.ZERO
var _pilot_cda: float = 0.21
var _alt_dep := true
var _rho_sea: float = 1.225
var _scale_h: float = 10400.0
var _lf_filter: float = 0.3
var _lf_jitter: float = 1.0
var _flare_h: float = 4.0
var _feet_agl: float = INF
# земля (PD-3)
var _uprights := false  ## руки на стойках, ноги работают (земля, сразу после отрыва, после посадки)
var _t_air: float = 0.0  ## с отрыва, пока руки на стойках
var _fresh := false  ## reset_on_ground: поза по уклону — на первом шаге (склон ещё не известен)
var _h_ground0: float = 0.0  ## высота земли при reset_on_ground (если ground_fn нет)
var _leg_len: float = 1.0
var _feet_clear: float = 0.05
var _strap_frac: float = 0.25
var _bar_after: float = 1.0
var _upright_clear: float = 1.0
var _fell_h: float = 0.5
var _slope_d: float = 1.0
var _tension_avg: float = 0.0
var _hands_p := Vector3.ZERO  ## сила рук на пилота (NED), последний подшаг
var _contact_pts: Array[Vector3] = []  ## нос, концы консолей (правая, левая), конец киля, трапеция — оси B
## Оценка касания (PD-35): пилот встаёт на ноги / пробегает / жёстко (pendulum.json → touchdown).
var touchdown := PendulumTouchdown.new()
const CONTACT_NAMES := ["nose", "wingtip", "wingtip", "keel", "bar"]
## Посадка: консоль на земле раньше ступней — авария, если крыло накренено хотя бы на это, рад.
const LANDING_TIP_BANK := deg_to_rad(10.0)


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
	# пропуски «Аппарата» (PD-К1 v3): умолчания крыла (класса, PD-К2 v3), потом общие
	var app_d: Dictionary = pendulum.apparatus_defaults
	if wing.has("pendulum"):
		app_d = Config._deep_merge(app_d, wing.pendulum.get("apparatus_defaults", {}))
	apparatus = Config._deep_merge(app_d, apparatus_cfg)
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
	_pilot_cda = float(pendulum.pilot_cda_m2)
	aero_hz = float(pendulum.strips.get("aero_hz", 60.0))
	var ad: Dictionary = flight.air_density
	_alt_dep = bool(ad.altitude_dependent)
	_rho_sea = float(ad.sea_level_kgm3)
	_scale_h = float(ad.scale_height_m)
	_lf_filter = float(flight.load_factor.filter_s)
	_lf_jitter = float(flight.load_factor.jitter_window_s)
	_flare_h = float(flight.flare.height_m)
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
	_ge.resize(strips.n)
	_ge_on = bool(pendulum.ground_effect.get("enabled", true))
	chain.setup(ch, pilot_mass, _hang_len)
	arms.setup(pendulum.arms)
	# земля: ноги, хват за стойки, точки касания крыла
	var gc: Dictionary = pendulum.ground
	ground.setup(gc, pilot, flight, wing, pilot_mass, _m_wing)
	ground.set_grip(
		Vector3(x_hang, 0.0, 0.0), Vector3(bar_x, 0.0, -float(blk.bar_z_m)),
		float(gc.grip_along_upright_m), _cg_n
	)
	_leg_len = float(gc.leg_length_m)
	_feet_clear = float(gc.liftoff_feet_clear_m)
	_strap_frac = float(gc.liftoff_strap_fraction)
	_bar_after = float(gc.bar_after_liftoff_s)
	_fell_h = float(gc.fell_cm_height_m)
	_upright_clear = float(flight.takeoff.upright_clear_m)
	_slope_d = float(flight.takeoff.slope_sample_m)
	var half := 0.5 * span
	var x_tip := half * tan(deg_to_rad(float(blk.sweep_deg))) + 0.5 * float(blk.tip_chord_m)
	_contact_pts = []
	for r_n: Vector3 in [
		Vector3.ZERO, Vector3(x_tip, half, 0.0), Vector3(x_tip, -half, 0.0),
		Vector3(float(blk.keel_len_m), 0.0, 0.0),
	]:
		_contact_pts.append(Vector3(_cg_n.x - r_n.x, r_n.y, r_n.z - _cg_n.z))
	_contact_pts.append(_r_bar_b)  # середина трапеции — только на посадке
	touchdown.setup(pendulum.get("touchdown", {}))
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
	_uprights = false
	_air_c = ned(wind)  # до первого step воздушная скорость — относительно ветра
	_update_outputs(Callable(), Callable())


## Пилот стоит ступнями в pos (мир игры; высота — земля, её даёт Glider) лицом по курсу, крыло
## на руках: хват за стойки у плеч, нос — wing.launch.alpha_neutral_deg к земле по курсу, стропа
## провисает. Уклон склона модель узнаёт на первом шаге (ground_fn) — тогда поза ставится заново.
func reset_on_ground(pos: Vector3, heading_deg: float) -> void:
	_reset_common()
	rho = air_density(pos.y)
	solve_trim()  # нейтраль рук на штанге — для полёта после отрыва
	_h_ground0 = pos.y
	_on = -pos.z
	_oe = pos.x
	_od = -pos.y
	ground.set_plane(0.0, 0.0, 0.0, 0.0, 0.0)
	_place_on_ground(deg_to_rad(heading_deg), Vector3.ZERO)
	_fresh = true
	mode = FlightModel.Mode.GROUND
	_update_outputs(Callable(), Callable())


## Поза стоя: ступни в feet (локальная NED, на земле), курс ps; ЦМ пилота над ступнями на длину
## ноги со статическим сжатием, плечи — хват за стойки, крыло с носом на alpha_neutral к земле.
func _place_on_ground(ps: float, feet: Vector3) -> void:
	_w = Vector3.ZERO
	_aero_age = INF
	_air_c = Vector3.ZERO
	arms.reset()
	_uprights = true
	_t_air = 0.0
	ground.heading_cmd = ps
	var squash := mass * Units.G / ground.leg_k
	var xp := feet + PendulumGround.UP_NED * (_leg_len - squash)
	ground.set_flow(Vector3.ZERO)
	var th := ground.flow_gamma + ground.alpha_neutral
	_R = basis_from_euler(ps, th, 0.0)
	var f := ground.fwd()
	var sh := xp + f * ground.shoulder_fwd + PendulumGround.UP_NED * ground.shoulder_up
	_pos = sh - _R * ground.grip_b
	_vel = Vector3.ZERO
	var h := _pos + _R * _r_hang_b
	chain.place(h, Vector3.ZERO, Vector3.ZERO)
	for i in chain.links:  # провисшая цепь: узлы на прямой подвеска — пилот
		chain.x[i] = h + (xp - h) * (float(i + 1) / chain.links)
	ground.reset(ps, xp)
	_recentre()
	# нейтраль индикатора на земле — поза стоя без ввода (крыло на плечах), в осях крыла (FB-К1)
	_ground_neutral = wing_basis().transposed() * game(xp - h)


## Буксир (NET-42): крыло жёстко в заданное положение, пилот в равновесии под подвеской, ω = 0.
func set_kinematic(pos: Vector3, vel: Vector3, heading_: float, bank_: float, theta_: float) -> void:
	if not _neutral_ok:
		rho = air_density(pos.y)
		solve_trim()
	_R = basis_from_euler(heading_, theta_, bank_)
	_vel = ned(vel)
	_w = Vector3.ZERO
	_aero_age = INF
	_place_wing(pos)
	var h := _pos + _R * _r_hang_b
	chain.place(h, E3, _vel)
	_air_c = Vector3.ZERO
	arms.reset()
	_uprights = false
	mode = FlightModel.Mode.AIR
	_update_outputs(Callable(), Callable())


## Один шаг: dt 1/240…1/30 с; подшагов max(substeps_min, ceil(dt·substeps_per_s)).
func step(dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> void:
	if not _simulating():
		_update_outputs(air_fn, ground_fn)
		return
	time_s += dt
	rho = air_density(-(_od + _pos.z))
	_recentre()
	var landed_ := mode == FlightModel.Mode.LANDED
	if landed_ and (input.run or absf(input.walk) > 0.01):
		# после посадки без аварии: пошёл или побежал — снова на земле с крылом
		mode = FlightModel.Mode.GROUND
		landed_ = false
		landing_result = {}
		ground.decel = ground.stop_decel
	if _uprights:
		_sample_ground(ground_fn)
		if _fresh:
			_fresh = false
			var xp0 := chain.pilot()
			var feet := Vector3(xp0.x, xp0.y, ground.ground_z(xp0))
			_place_on_ground(ground.heading_cmd, feet)
			_sample_ground(ground_fn)
		ground.begin_step(dt, input, chain.pilot_vel(), landed_)
		ground.set_flow(chain.pilot_vel() - _air_c)  # поток на бегущего пилота (не качание крыла)
	var inp := input
	if landed_:
		inp = ControlInput.new()  # стоит после посадки: руки держат крыло в нейтрали
	# у земли пилот стоит в подвеске, руки на стойках: ход «от себя» — стоящего (PD-29), за 1 м
	# выше flight.flare.height_m нарастает
	arms.flare_mix = 0.0
	if mode == FlightModel.Mode.AIR and not _uprights:
		arms.flare_mix = clampf(_flare_h + 1.0 - _feet_agl, 0.0, 1.0)
	var n := maxi(_sub_min, ceili(dt * _sub_per_s - 1.0e-9))
	var h := dt / n
	_last_pitch = input.pitch
	var t_aero := 0.0 if aero_hz <= 0.0 else 1.0 / aero_hz - 1.0e-9
	var f_sum := Vector3.ZERO  # сила на пилота, усреднённая по подшагам (звено может провиснуть в последнем)
	var t_sum := 0.0
	for k in n:
		if _aero_age >= t_aero:
			strips.dyn_dt = _aero_age
			_aero_update(air_fn, ground_fn)
			strips.dyn_dt = 0.0
			_aero_age = 0.0
		_substep(h, inp)
		f_sum += chain.pilot_force + _hands_p
		t_sum += chain.tension
		_aero_age += h
	_R = _R.orthonormalized()
	_tension_avg = t_sum / n
	var f_p := f_sum / n
	load.update(f_p.length(), pilot_mass * Units.G, _lf_filter, dt, _lf_jitter)
	_update_outputs(air_fn, ground_fn)
	match mode:
		FlightModel.Mode.GROUND:
			_check_ground(ground_fn)
		FlightModel.Mode.AIR:
			if _uprights:
				_check_after_liftoff(dt, ground_fn)
			else:
				_check_touchdown(ground_fn)


## Шагает ли модель: в воздухе, на земле и после посадки без аварии (пилот на ногах).
func _simulating() -> bool:
	match mode:
		FlightModel.Mode.AIR, FlightModel.Mode.GROUND:
			return true
		FlightModel.Mode.LANDED:
			return _uprights
	return false


## Плоскость земли под пилотом (ground_fn; нет — ровная земля на высоте reset_on_ground).
func _sample_ground(ground_fn: Callable) -> void:
	var xp := chain.pilot()
	var g := _world(xp)
	var d := _slope_d
	var hc := FlightModel.ground_height(ground_fn, g.x, g.z)
	if hc == -INF:
		ground.set_plane(xp.x, xp.y, -_h_ground0 - _od, 0.0, 0.0)
		return
	var hx := (
		FlightModel.ground_height(ground_fn, g.x + d, g.z)
		- FlightModel.ground_height(ground_fn, g.x - d, g.z)
	) / (2.0 * d)
	var hz := (
		FlightModel.ground_height(ground_fn, g.x, g.z + d)
		- FlightModel.ground_height(ground_fn, g.x, g.z - d)
	) / (2.0 * d)
	# NED: север = −z игры, восток = x; «вниз» земли = −h
	ground.set_plane(xp.x, xp.y, -hc - _od, hz, -hx)


## Высота земли под локальной точкой p (мир игры; без ground_fn — плоскость под пилотом).
func _ground_alt(ground_fn: Callable, p: Vector3) -> float:
	var g := _world(p)
	var hg := FlightModel.ground_height(ground_fn, g.x, g.z)
	return hg if hg > -INF else -(ground.ground_z(p) + _od)


## Первая точка крыла (нос, консоли, конец киля) на земле или ниже; −1 — нет.
## landing — касание в полёте: конец киля и консоли при ровном крыле (|крен| < LANDING_TIP_BANK:
## задранный на выравнивании парус задевает землю задней кромкой) аварией не считаются.
func _wing_contact(ground_fn: Callable, landing: bool) -> int:
	for i in _contact_pts.size():
		if landing and (i == 3 or ((i == 1 or i == 2) and absf(bank) < LANDING_TIP_BANK)):
			continue
		if i == 4 and not landing:
			continue
		var p: Vector3 = _pos + _R * _contact_pts[i]
		if -(_od + p.z) <= _ground_alt(ground_fn, p):
			return i
	return -1


## На земле: срыв (крыло коснулось земли, пилот упал) или отрыв (ступни над землёй без опоры,
## стропа под нагрузкой — из сил, без порога скорости).
func _check_ground(ground_fn: Callable) -> void:
	var c := _wing_contact(ground_fn, false)
	var xp := chain.pilot()
	if c >= 0:
		_fail(CONTACT_NAMES[c])
		return
	if ground.agl(xp) < _fell_h:
		_fail("fell")
		return
	var feet := ground.agl(xp) - _leg_len
	if (
		not ground.contact and feet > _feet_clear
		and _tension_avg > _strap_frac * pilot_mass * Units.G
	):
		mode = FlightModel.Mode.AIR
		_t_air = 0.0
		_update_outputs(Callable(), ground_fn)
		took_off.emit()


## Сразу после отрыва (руки ещё на стойках): касание ступнями — снова разбег; крыло о землю —
## срыв взлёта; через bar_after_liftoff_s (или ступни выше upright_clear_m) — руки на штангу.
func _check_after_liftoff(dt: float, ground_fn: Callable) -> void:
	if ground.contact:
		mode = FlightModel.Mode.GROUND
		_update_outputs(Callable(), ground_fn)
		return
	var c := _wing_contact(ground_fn, false)
	if c >= 0:
		_fail(CONTACT_NAMES[c])
		return
	_t_air += dt
	var feet := ground.agl(chain.pilot()) - _leg_len
	if _t_air >= _bar_after or feet > _upright_clear:
		_uprights = false
		arms.reset()


func _fail(reason: String) -> void:
	takeoff_failure = reason
	mode = FlightModel.Mode.FAILED
	_uprights = false
	_freeze()
	takeoff_failed.emit(reason)


func _freeze() -> void:
	_vel = Vector3.ZERO
	_w = Vector3.ZERO
	chain.stop()
	_hands_p = Vector3.ZERO
	arms.reset()
	_update_outputs(Callable(), Callable())


## Значения Telemetry.phase.
func phase() -> String:
	match mode:
		FlightModel.Mode.AIR:
			return "flying"
		FlightModel.Mode.LANDED:
			return "landed"
		FlightModel.Mode.FAILED:
			return "failed"
	return ground.phase


## Доля «от себя» (0…1) у земли — ступни ниже flight.flare.height_m (в полёте, руки на штанге),
## иначе 0 (v2).
func flare_amount() -> float:
	if mode != FlightModel.Mode.AIR or _uprights or _feet_agl > _flare_h:
		return 0.0
	return clampf(_last_pitch, 0.0, 1.0)


## Доля сорванных полос.
func stall_amount() -> float:
	return strips.stall_fraction()


## Плотность воздуха на высоте, кг/м³ (как FlightModel).
func air_density(altitude_m: float) -> float:
	if not _alt_dep:
		return _rho_ref
	return _rho_sea * exp(-altitude_m / _scale_h)


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
## Аэродинамика крыла и воздух у пилота: раз в 1/aero_hz с (между вызовами сила и момент
## заморожены в осях крыла и поворачиваются с ним; цепь и руки — на каждом подшаге).
## Экранный эффект — по высоте каждой полосы над ground_fn (выше размаха над землёй — нет).
func _aero_update(air_fn: Callable, ground_fn: Callable = Callable()) -> void:
	var R := _R
	var air_c := Vector3.ZERO
	_air_p = Vector3.ZERO
	if air_fn.is_valid():
		var rb := strips.r_b
		for i in strips.n:
			# точка полосы в мире игры (сложение с началом в float64) → ветер → NED
			var p: Vector3 = _pos + R * rb[i]
			var g: Vector3 = air_fn.call(Vector3(_oe + p.y, -(_od + p.z), -(_on + p.x)))
			_air[i] = Vector3(-g.z, g.x, -g.y)
		air_c = _air_at(air_fn, _pos)
		_air_p = _air_at(air_fn, chain.pilot())
	_air_c = air_c
	# перекос пузыря: поперечная сила рук на вес пилота (в равновесии = tg угла стропы к крылу)
	var lam := 0.0
	if strips.billow_shift != 0.0 and pilot_mass > 0.0:
		lam = arms.force_b.y / (pilot_mass * Units.G)
	var ge := PackedFloat64Array()
	if _ge_on and _ground_effect(ground_fn):
		ge = _ge
	strips.aero(_vel, R, _w, _air if air_fn.is_valid() else _zero_air, air_c, lam, rho, ge)
	_aero_f_b = strips.force_b
	_aero_m_b = strips.moment_b


func _substep(h: float, input: ControlInput) -> void:
	var R := _R
	var Rt := R.transposed()
	var H: Vector3 = _pos + R * _r_hang_b
	var last := chain.links - 1
	var xp: Vector3 = chain.x[last]
	var vp: Vector3 = chain.v[last]
	var wb: Vector3 = Rt * _w
	var f_wb := _aero_f_b  # сила на крыло без веса, оси B
	var tb := _aero_m_b  # момент около ЦМ, оси B
	# пилот: вес, сопротивление (CD·A)_п, руки
	var va := vp - _air_p
	var f_p := E3 * (pilot_mass * Units.G) - va * (0.5 * rho * _pilot_cda * va.length())
	var rel: Vector3 = Rt * (xp - H)
	var fb := Vector3.ZERO
	if _uprights:
		# руки на стойках: горизонтальная сила — в хвате, вертикальная опора — под ЦМ крыла
		var rg := R * ground.grip_b
		var fw := ground.grip_force(_pos + rg, _vel + _w.cross(rg), xp, vp)
		var fv := Vector3(0.0, 0.0, fw.z)
		f_wb += Rt * fw
		tb += Rt * (rg.cross(fw - fv) + (R * Vector3(0.0, 0.0, ground.grip_b.z)).cross(fv))
		tb += ground.torque_b(R, wb, _I_b, input.pitch, input.roll, h)
		f_p -= fw
		_hands_p = -fw
		f_p += ground.legs(xp, vp, h)
	else:
		# скорость пилота относительно подвески во вращающихся осях крыла
		var vrel: Vector3 = Rt * (vp - _vel) - wb.cross(_r_hang_b + rel)
		fb = arms.compute(
			rel, vrel, input.roll, input.pitch, pilot_mass, h, arms_relaxed, hands_force_y
		)
		_hands_p = R * fb
	if fb != Vector3.ZERO:
		f_p += R * fb
		f_wb -= fb
		# продольная сила рук — в середине штанги (момент по тангажу); поперечная — на высоте
		# штанги, но на продольной координате ЦМ пилота (пилот держит тело ⊥ штанге: пара
		# «штанга — стропа» по рысканию на крыло не передаётся; Takamatsu & Ochi 2022)
		var r_pil_x := _r_hang_b.x + rel.x
		tb += _r_bar_b.cross(Vector3(-fb.x, 0.0, 0.0))
		tb += Vector3(r_pil_x, 0.0, _r_bar_b.z).cross(Vector3(0.0, -fb.y, 0.0))
	# скорости и позиции
	var pos_prev := _pos
	var r_prev := R
	_vel += (R * f_wb) * (h / _m_wing) + E3 * (Units.G * h)
	# гироскопический член — по инерции конструкции (присоединённая масса — не твёрдое тело)
	wb += _I_inv * (tb - wb.cross(_I_struct * wb)) * h
	_w = R * wb
	_pos += _vel * h
	var ang := _w.length() * h
	if ang > 1.0e-12:
		R = Basis(_w / (ang / h), ang) * R
	chain.integrate(h, f_p)
	# связи цепи
	var iw_inv := R * _I_inv * R.transposed()
	chain.project(h, _pos, R, _r_hang_b, _m_wing, iw_inv)
	_pos = chain.wing_pos
	_R = chain.wing_R
	# скорости из позиций; поворот за подшаг мал (|ω|·h ≲ 0,01 рад) — ω из кососимметричной
	# части R·R_prevᵀ (ошибка ~θ²/6)
	_vel = (_pos - pos_prev) / h
	var d := _R * r_prev.transposed()
	_w = Vector3(d.y.z - d.z.y, d.z.x - d.x.z, d.x.y - d.y.x) * (0.5 / h)
	chain.velocities_from_prev(h)


## σ экранного эффекта полос → _ge (PendulumWingStrips.ground_sigma по высоте полосы над землёй).
## false — земли нет или крыло выше размаха над ней (σ = 0 у всех полос).
func _ground_effect(ground_fn: Callable) -> bool:
	if not ground_fn.is_valid() and not _uprights:
		return false
	if -(_od + _pos.z) - _ground_alt(ground_fn, _pos) > span:
		return false
	var R := _R
	var rb := strips.r_b
	var any := false
	for i in strips.n:
		var p: Vector3 = _pos + R * rb[i]
		_ge[i] = PendulumWingStrips.ground_sigma(-(_od + p.z) - _ground_alt(ground_fn, p), span)
		any = any or _ge[i] > 0.0
	return any


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
	ground.anchor -= Vector2(d.x, d.y)
	ground.gpx -= d.x
	ground.gpy -= d.y
	ground.gz -= d.z


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
	_aero_age = INF
	_w = Vector3.ZERO
	arms.reset()
	load.reset()
	landing_result = {}
	takeoff_failure = ""
	_feet_agl = INF
	_last_pitch = 0.0
	_fresh = false
	_hands_p = Vector3.ZERO


## Касание в полёте (руки на штанге): ступни (ЦМ пилота − длина ноги по его оси) у земли →
## PendulumTouchdown по скорости ЦМ пилота (PD-35: встал на ноги / пробежал / жёстко; пороги
## вертикальной, крена, аварии — LandingJudge); трапеция раньше ступней — жёстко, консоль или нос
## в землю раньше ступней — авария. После
## посадки без аварии пилот на ногах с крылом на руках (пробежка гасит скорость), после аварии —
## всё стоит.
func _check_touchdown(ground_fn: Callable) -> void:
	if not ground_fn.is_valid():
		return
	var feet := pilot_position - pilot_basis.y * _leg_len
	var gh := FlightModel.ground_height(ground_fn, feet.x, feet.z)
	_feet_agl = feet.y - gh
	var wing_hit := -1
	if _feet_agl < span:
		wing_hit = _wing_contact(ground_fn, true)
	if _feet_agl > 0.0 and wing_hit < 0:
		return
	var lc: Dictionary = flight.landing
	var nrm := LandingJudge.ground_normal(ground_fn, feet.x, feet.z, float(lc.normal_sample_m))
	var contact := "feet" if _feet_agl <= 0.0 else String(CONTACT_NAMES[wing_hit])
	if contact == "wingtip" and absf(bank) > PI * 0.5:
		contact = "tail"  # крыло за вертикалью (крен Эйлера ±180°): хвостом в землю (PD-35)
	var result := touchdown.evaluate(pilot_velocity, nrm, rad_to_deg(bank), contact, lc)
	result["position"] = Vector3(feet.x, gh, feet.z)
	result["flight_time_s"] = time_s
	landing_result = result
	mode = FlightModel.Mode.LANDED
	if result.grade == "crash":
		_freeze()
	else:
		# на ноги: руки со штанги на стойки, ступни держат землю, пробежка с runout_decel
		_uprights = true
		var xp := chain.pilot()
		_sample_ground(ground_fn)
		ground.reset(heading, xp)
		var f := ground.fwd()
		var vp := chain.pilot_vel()
		ground.v_walk = maxf(vp.x * f.x + vp.y * f.y, 0.0)
		ground.decel = float(lc.runout_decel_ms2)
		arms.reset()
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
	var air_c := _air_c if _simulating() else Vector3.ZERO
	var vb := R.transposed() * (_vel - air_c)
	alpha = atan2(vb.z, vb.x)
	stalled = strips.root_stalled()
	var xp := chain.pilot()
	pilot_position = _world(xp)
	pilot_velocity = game(chain.pilot_vel())
	var rel_g := game(xp - h_loc)
	pilot_rel = bg.transposed() * rel_g
	pilot_shift = _shift_of(bg, rel_g)
	var up := -rel_g.normalized()
	pilot_basis = Basis(Quaternion(bg.y, up)) * bg if up.length() > 0.5 else bg
	head_position = pilot_position + pilot_basis * Vector3(0.0, _head_up, -_head_fwd)
	bar_force = game(_hands_p)
	strap_tension = chain.tension
	_fill_telemetry(air_c, ground_fn, bg)


## Смещение пилота (FB-К1): (pilot_rel − нейтраль) / предел хода по осям крыла. В воздухе на штанге
## нейтраль — положение рук без усилия (arms.neutral_rel, оси тела NED → оси крыла игры);
## на земле до отрыва — поза стоя при постановке (_ground_neutral); после посадки и до расчёта нейтрали — пилот под подвеской по отвесу (висит спокойно).
## Предел: поперёк shift_y_max, к носу shift_x_pull, к хвосту shift_x_push (pilot_arms).
func _shift_of(bg: Basis, rel_g: Vector3) -> Vector2:
	if not (rel_g.is_finite() and pilot_rel.is_finite()):
		return Vector2.ZERO
	var neutral := Vector3.ZERO
	if mode == FlightModel.Mode.AIR and not _uprights and _neutral_ok:
		var n := arms.neutral_rel
		neutral = Vector3(n.y, -n.z, -n.x)
	elif mode == FlightModel.Mode.GROUND and _uprights and _ground_neutral != Vector3.ZERO:
		neutral = _ground_neutral
	else:
		neutral = bg.transposed() * (Vector3.DOWN * rel_g.length())
	var d := pilot_rel - neutral
	var fwd := -d.z
	var sx := d.x / maxf(arms.shift_y_max, 1.0e-3)
	var sy := fwd / maxf(arms.shift_x_pull if fwd > 0.0 else arms.shift_x_push, 1.0e-3)
	var v := Vector2(sx, sy)
	return v if v.is_finite() else Vector2.ZERO


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
	t.pilot_shift = pilot_shift
	t.load_factor = load.load_factor
	t.flare_amount = flare_amount()
