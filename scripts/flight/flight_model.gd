class_name FlightModel
extends RefCounted
## Модель полёта дельтаплана: точечная масса с ориентацией (крен, тангаж, курс).
##
## Подъём и сопротивление — из поляры крыла (WingPolar, CL→CD). Трапеция задаёт угол атаки,
## поэтому при той же трапеции скорости растут как √(M/ρ) — масса пилота и высота
## учитываются сами (FR-3). Скорость — состояние (относительно земли), поэтому порывы
## и потоки меняют воздушную скорость и угол атаки естественно. На земле шагает GroundRun,
## посадку оценивает LandingJudge. Подробности и допущения — docs/guide/flight.md.

signal took_off
signal landed(result: Dictionary)
signal takeoff_failed(reason: String)

enum Mode { GROUND, AIR, LANDED, FAILED }

const UP := Vector3.UP
## За сколько градусов крена сверх roll_overbank_deg устойчивость по крену сходит на нет, °.
const OVERBANK_FADE_DEG := 10.0

var telemetry := Telemetry.new()
var mode: Mode = Mode.GROUND
## Причина срыва взлёта: "wingtip" (консоль на земле) или "" (GroundRun.failure).
var takeoff_failure: String = ""
## Перегрузка n (load_factor, load_raw, load_max, load_min).
var load := LoadMeter.new()
## Результат последней посадки (LandingJudge.evaluate + position, flight_time_s).
var landing_result: Dictionary = {}

# параметры (СИ)
var wing: Dictionary = {}
var pilot: Dictionary = {}
var flight: Dictionary = {}
var polar: WingPolar
var pilot_mass: float = 0.0
var mass: float = 0.0  ## полная масса пилот + крыло, кг
var mass_ref: float = 0.0  ## эталонная полная масса, кг
var area: float = 0.0
var span: float = 0.0
var alpha_stall: float = 0.0  ## критический угол атаки киля, рад
var tau_pitch: float = 0.0
var rho: float = 1.225  ## текущая плотность воздуха, кг/м³

# состояние
var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO  ## относительно земли
var heading: float = 0.0  ## рад, 0 — север, по часовой
var bank: float = 0.0  ## рад, + вправо
var roll_rate: float = 0.0  ## рад/с
var theta: float = 0.0  ## тангаж киля, рад
var alpha: float = 0.0  ## угол атаки киля, рад
var stalled: bool = false
var time_s: float = 0.0

var _ground := GroundRun.new()
var _v_trim_ref: float = 0.0
var _v_pull_ref: float = 0.0
var _v_push_ref: float = 0.0
var _lift_slope: float = 0.0
var _alpha0: float = 0.0
var _tau_roll: float = 0.0
var _roll_rate_max: float = 0.0
var _ws: Dictionary = {}  ## режим «смещение веса»: wing.weight_shift
var _tau_roll_ws: float = 0.0
var _roll_rate_max_ws: float = 0.0
var _roll_stability: float = 0.0  ## собственная устойчивость по крену, 1/с
var _roll_stability_steep: float = 0.0  ## добавка устойчивости при крене 45°, 1/с
var _roll_overbank: float = PI  ## крен, круче которого устойчивость пропадает, рад
var _rho_ref: float = 1.225
var _stall_time: float = 0.0
var _attached: float = 1.0  ## доля присоединённого потока: 1 — обтекание, 0 — полный срыв
var _flare := LandingFlare.new()
## Пилот после отрыва ещё на ногах (не в подвеске): касание — снова разбег (К3 v3, без таймера).
var _upright := false
## После отрыва нос ещё не встал по потоку: курс доворачивается к воздушной скорости с
## постоянной takeoff.yaw_align_s, а не скачком (пока _upright — не доворачивается вовсе).
var _yaw_align := false
var _accel_t: float = 0.0  ## касательное ускорение по потоку с прошлого шага, м/с²


## Масса пилота в допустимом диапазоне крыла.
static func clamp_pilot_mass(wing_cfg: Dictionary, mass_kg: float) -> float:
	var lo := float(wing_cfg.pilot_mass_min_kg)
	return clampf(mass_kg, lo, float(wing_cfg.pilot_mass_max_kg))


static func sample_air(air_fn: Callable, p: Vector3) -> Vector3:
	return air_fn.call(p) if air_fn.is_valid() else Vector3.ZERO


## Высота земли; −INF, если функции рельефа нет.
static func ground_height(ground_fn: Callable, x: float, z: float) -> float:
	return float(ground_fn.call(x, z)) if ground_fn.is_valid() else -INF


## wing — конфиг крыла (configs/wings/*.json), pilot — конфиг пилота (configs/pilot.json,
## "mass_kg" можно переопределить), flight_override — правки поверх configs/flight.json.
func setup(wing_cfg: Dictionary, pilot_cfg: Dictionary, flight_override: Dictionary = {}) -> void:
	wing = wing_cfg
	pilot = pilot_cfg
	flight = Config._deep_merge(Config.get_config("flight"), flight_override)
	area = float(wing.area_m2)
	span = float(wing.span_m)
	pilot_mass = float(pilot.mass_kg)
	mass = pilot_mass + float(wing.wing_mass_kg)
	mass_ref = float(wing.pilot_mass_ref_kg) + float(wing.wing_mass_kg)
	_rho_ref = float(flight.air_density.polar_ref_kgm3)
	rho = _rho_ref
	polar = WingPolar.new(wing.polar.points_kmh_ms, mass_ref, _rho_ref, area)
	_v_trim_ref = Units.kmh(float(wing.trim_speed_kmh))
	_v_pull_ref = Units.kmh(float(wing.full_pull_speed_kmh))
	_v_push_ref = Units.kmh(float(wing.full_push_speed_kmh))
	_lift_slope = float(wing.lift_slope_per_rad)
	_alpha0 = Units.deg(float(wing.zero_lift_alpha_deg))
	alpha_stall = polar.cl_max / _lift_slope + _alpha0
	var mf := mass / mass_ref
	var inertia: Dictionary = flight.inertia
	var tc_exp := float(inertia.time_constant_mass_exponent)
	tau_pitch = float(wing.pitch_time_constant_s) * pow(mf, tc_exp)
	_tau_roll = float(wing.roll_time_constant_s) * pow(mf, tc_exp)
	var rr_scale := pow(mf, float(inertia.roll_rate_mass_exponent))
	_roll_rate_max = Units.deg(float(wing.roll_rate_max_dps)) * rr_scale
	_ws = wing.weight_shift
	_tau_roll_ws = float(_ws.roll_time_constant_s) * pow(mf, tc_exp)
	_roll_rate_max_ws = Units.deg(float(_ws.roll_rate_max_dps)) * rr_scale
	_roll_stability = float(_ws.roll_stability_per_s)
	_roll_stability_steep = float(_ws.roll_stability_steep_per_s)
	_roll_overbank = Units.deg(float(_ws.roll_overbank_deg))
	telemetry = Telemetry.new()


## Пилот стоит на склоне в точке pos (Y берётся из ground_fn при первом шаге), лицом по курсу.
func reset_on_ground(pos: Vector3, heading_deg: float) -> void:
	_reset_common(pos, heading_deg)
	mode = Mode.GROUND
	theta = Units.deg(float(wing.launch.alpha_neutral_deg))
	_update_telemetry(Callable(), Callable())


## Старт в воздухе (свободный полёт, тесты). airspeed_ms ≤ 0 — скорость трима.
## wind — скорость воздуха в точке старта, чтобы начать без скачка воздушной скорости.
func reset_in_air(
	pos: Vector3, heading_deg: float, airspeed_ms: float = 0.0, wind: Vector3 = Vector3.ZERO
) -> void:
	_reset_common(pos, heading_deg)
	mode = Mode.AIR
	rho = air_density(pos.y)
	var v := airspeed_ms if airspeed_ms > 0.0 else trim_speed()
	var gamma := -asin(clampf(steady_glide(v).y / v, -1.0, 1.0))
	velocity = heading_dir() * v * cos(gamma) + UP * v * sin(gamma) + wind
	alpha = _alpha_for_cl(2.0 * mass * Units.G / (rho * area * v * v))
	theta = gamma + alpha
	_update_telemetry(Callable(), Callable())


## Один шаг физики. air_fn(pos: Vector3) -> Vector3 — скорость воздуха (пустой — штиль);
## ground_fn(x: float, z: float) -> float — высота земли (пустой — земли нет).
func step(dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> void:
	time_s += dt
	match mode:
		Mode.AIR:
			_step_air(dt, input, air_fn, ground_fn)
		Mode.GROUND:
			_step_ground(dt, input, air_fn, ground_fn)
		Mode.LANDED:
			_flare.runout(self, dt, ground_fn)
			# после нормальной посадки можно уйти пешком или снова разбежаться
			var moving := input.run or absf(input.walk) > 0.01
			if landing_result.get("grade", "") != "crash" and moving:
				reset_on_ground(position, rad_to_deg(heading))
				_step_ground(dt, input, air_fn, ground_fn)
		_:
			velocity = Vector3.ZERO
	_update_telemetry(air_fn, ground_fn)


## Фаза: "standing", "walking", "running", "flying", "landed", "failed".
func phase() -> String:
	match mode:
		Mode.AIR:
			return "flying"
		Mode.LANDED:
			return "landed"
		Mode.FAILED:
			return "failed"
	return _ground.phase


## Плотность воздуха на высоте, кг/м³.
func air_density(altitude_m: float) -> float:
	var ad: Dictionary = flight.air_density
	if not bool(ad.altitude_dependent):
		return _rho_ref
	return float(ad.sea_level_kgm3) * exp(-altitude_m / float(ad.scale_height_m))


## Множитель скоростей √(M·ρ_эт / (M_эт·ρ)) для текущей массы и плотности.
func speed_scale() -> float:
	return sqrt(mass * _rho_ref / (mass_ref * rho))


func trim_speed() -> float:
	return _v_trim_ref * speed_scale()


## Скорость сваливания в прямолинейном полёте при текущей массе и плотности, м/с.
func stall_speed() -> float:
	return sqrt(2.0 * mass * Units.G / (rho * area * polar.cl_max))


## Установившееся планирование на воздушной скорости v (м/с) при текущей массе и плотности:
## Vector2(v, снижение м/с) — то, к чему сходится модель в спокойном воздухе.
func steady_glide(v: float) -> Vector2:
	# CL из условия L = M·g·cosγ; итерации по cosγ (сходится за 2–3 шага)
	var cos_g := 1.0
	var ld := 1.0
	for i in 4:
		var cl := 2.0 * mass * Units.G * cos_g / (rho * area * v * v)
		ld = cl / polar.cd_at(cl)
		cos_g = cos(atan(1.0 / ld))
	return Vector2(v, v * sin(atan(1.0 / ld)))


## Выравнивание у земли 0..1 (для позы пилота): 0 — нет, 1 — трапеция от себя до упора.
func flare_amount() -> float:
	return _flare.amount if mode == Mode.AIR else 0.0


## Насколько сорван поток: 0 — обтекание, 1 — полный срыв (для паруса и звука).
func stall_amount() -> float:
	return 1.0 - _attached


func heading_dir() -> Vector3:
	return Vector3(sin(heading), 0.0, -cos(heading))


func right_dir() -> Vector3:
	return Vector3(cos(heading), 0.0, sin(heading))


## CL и CD при текущем угле атаки. Срыв развивается и уходит не мгновенно (динамический
## срыв): за lift_loss_time_s обтекание переходит к сорванному — парус работает как пластина
## поперёк потока: CL = CN·sinα·cosα, CD = CN·sin²α (α от линии нулевой подъёмной силы).
## На большом угле атаки (выравнивание) крыло — чистый тормоз: подъёмная сила → 0.
func aero_coefs(dt: float) -> Vector2:
	var st: Dictionary = wing.stall
	var target := 0.0 if stalled else 1.0
	# на выравнивании: динамический срыв — CL кратко выше статической, парус давит сильнее
	var f := _flare.aero_factors(self, float(st.lift_loss_time_s))
	_attached = move_toward(_attached, target, dt / f.x)
	var cl_att := minf(_lift_slope * (alpha - _alpha0), polar.cl_max * f.y)
	var cd_att := polar.cd_at(minf(cl_att, polar.cl_max))
	var a_e := wrapf(alpha - _alpha0, -PI, PI)  # пластина: формулы верны при любом угле
	var cn := float(st.post_stall_cn) * f.z
	var cl_sep := cn * sin(a_e) * cos(a_e)
	var cd_sep := maxf(cn * sin(a_e) * sin(a_e), cd_att)
	return Vector2(lerpf(cl_sep, cl_att, _attached), lerpf(cd_sep, cd_att, _attached))


func _reset_common(pos: Vector3, heading_deg: float) -> void:
	position = pos
	velocity = Vector3.ZERO
	heading = Units.deg(heading_deg)
	bank = 0.0
	roll_rate = 0.0
	theta = 0.0
	alpha = 0.0
	stalled = false
	time_s = 0.0
	_stall_time = 0.0
	_attached = 1.0
	_flare.reset()
	load.reset()
	_accel_t = 0.0
	_ground.reset()
	_upright = false
	_yaw_align = false
	takeoff_failure = ""
	landing_result = {}


func _alpha_for_cl(cl: float) -> float:
	return cl / _lift_slope + _alpha0


## Трапеция → заданный угол атаки. Скорость трапеции задана при эталонной массе и линейно
## интерполируется между «на себя», тримом и «от себя»; угол атаки от массы не зависит.
func _alpha_command(pitch_in: float) -> float:
	var p := clampf(pitch_in, -1.0, 1.0)
	var v_ref := lerpf(_v_trim_ref, _v_push_ref, p)
	if p < 0.0:
		v_ref = lerpf(_v_trim_ref, _v_pull_ref, -p)
	return _alpha_for_cl(2.0 * mass_ref * Units.G / (_rho_ref * area * v_ref * v_ref))


func _step_air(dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> void:
	rho = air_density(position.y)
	# воздух в центре и на концах крыла (FR-8)
	var tip := right_dir() * cos(bank) - UP * sin(bank)
	var half := 0.5 * span * float(flight.air_sampling.tip_fraction)
	var w_c := sample_air(air_fn, position)
	var w_r := sample_air(air_fn, position + tip * half)
	var w_l := sample_air(air_fn, position - tip * half)

	var v_air := velocity - w_c
	var v := v_air.length()
	var min_v := float(flight.min_airspeed_ms)
	var u := v_air / v if v > min_v else heading_dir()
	var side := u.cross(UP)
	side = side.normalized() if side.length() > 1.0e-3 else right_dir()
	var lift_dir := side.cross(u) * cos(bank) + side * sin(bank)
	var q := 0.5 * rho * v * v * area if v > min_v else 0.0

	var agl := position.y - ground_height(ground_fn, position.x, position.z)
	if agl > float(flight.takeoff.upright_clear_m):
		_upright = false  # ступни высоко — пилот в подвеске, касание дальше — посадка
	_flare.update(self, input, agl, dt)
	_update_pitch(dt, input, asin(clampf(u.y, -1.0, 1.0)), q)
	var c := aero_coefs(dt)
	var force := lift_dir * (q * c.x) - u * (q * c.y) + UP * (-mass * Units.G)
	force += _flare.hang_force(self)
	var lf: Dictionary = flight.load_factor
	load.update(q * c.x, mass * Units.G, float(lf.filter_s), dt, float(lf.jitter_window_s))
	_accel_t = force.dot(u) / mass
	velocity += force / mass * dt
	position += velocity * dt
	_update_roll(dt, input, v, w_l.y - w_r.y)

	# курс — по горизонтальной воздушной скорости (полёт без скольжения). Пока пилот на ногах
	# (_upright), курс — направление разбега: пилот держит крыло за стойки и бежит, крыло с ним
	# не разворачивается по потоку (иначе каждый подскок — скачок курса на угол бокового ветра,
	# а касание продолжает разбег уже по новому курсу). В подвеске нос встаёт по потоку плавно.
	var v_air_new := velocity - w_c
	if not _upright and Vector2(v_air_new.x, v_air_new.z).length() > min_v:
		var target := atan2(v_air_new.x, -v_air_new.z)
		if _yaw_align:
			var diff := wrapf(target - heading, -PI, PI)
			heading += diff * (1.0 - exp(-dt / float(flight.takeoff.yaw_align_s)))
			if absf(diff) < Units.deg(0.5):
				_yaw_align = false
		else:
			heading = target

	# касание земли (FR-10)
	var gh := ground_height(ground_fn, position.x, position.z)
	if position.y <= gh:
		if _upright:
			# пилот ещё на ногах (после отрыва ступни не поднялись выше takeoff.upright_clear_m):
			# касание — это снова шаги разбега, а не посадка; дальше — GroundRun (отрыв, когда L ≥ W)
			position.y = gh
			mode = Mode.GROUND
			_ground.resume(self)
		else:
			landing_result = _flare.touchdown(self, ground_fn, gh)
			mode = Mode.LANDED
			landed.emit(landing_result)


## Тангаж: крыло с запаздыванием выходит на угол атаки от трапеции (FR-4); сваливание (FR-6).
## У земли работает выравнивание (LandingFlare).
func _update_pitch(dt: float, input: ControlInput, gamma: float, q: float) -> void:
	var st: Dictionary = wing.stall
	var alpha_target := _alpha_command(input.pitch)
	if _upright:
		# пилот ещё на ногах и держит крыло за стойки, как на разбеге (GroundRun._aero_force):
		# угол атаки — launch.alpha_neutral_deg + pitch·alpha_range_deg, не трим подвески
		var la: Dictionary = wing.launch
		alpha_target = Units.deg(
			float(la.alpha_neutral_deg) + clampf(input.pitch, -1.0, 1.0) * float(la.alpha_range_deg)
		)
	var tau := tau_pitch
	if stalled and not _flare.active and _stall_time > float(st.nose_drop_delay_s):
		alpha_target -= Units.deg(float(st.nose_drop_deg))
	# демпфирование фугоиды: при разгоне крыло чуть поднимает нос (устойчивость по скорости)
	if q > 0.0:
		var pd: Dictionary = flight.phugoid_damping
		var d_alpha := float(pd.gain) * mass * _accel_t / (q * _lift_slope)
		var lim := Units.deg(float(pd.max_alpha_deg))
		alpha_target += clampf(d_alpha, -lim, lim)
	var theta_target := gamma + alpha_target
	if _flare.active:
		# киль встаёт на заданный тангаж к горизонту, парус поперёк потока тормозит
		theta_target = _flare.theta_target(self, gamma + _alpha_command(0.0), input.pitch)
		tau = _flare.pitch_time(self)
	theta += (theta_target - theta) * (1.0 - exp(-dt / tau))
	alpha = theta - gamma

	if not stalled and alpha > alpha_stall:
		stalled = true
		_stall_time = 0.0
	elif stalled:
		_stall_time += dt
		var recovered := alpha < alpha_stall - Units.deg(float(st.recover_margin_deg))
		if _stall_time > float(st.min_duration_s) and recovered:
			stalled = false


## Крен: смещение веса (FR-5) + разница вертикальных потоков на концах крыла (FR-8).
## Два режима (ControlInput.weight_shift, настройка controls.roll_control_mode):
## «как раньше» — input.roll задаёт угловую скорость крена, без управления крен держится;
## «смещение веса» — input.roll = положение пилота в трапеции (_roll_weight_shift).
func _update_roll(dt: float, input: ControlInput, v: float, dw_left_right: float) -> void:
	var st: Dictionary = wing.stall
	var p_air := float(wing.air_roll_gain) * dw_left_right / span
	if input.weight_shift:
		_roll_weight_shift(dt, input, v, p_air)
	else:
		var sf := pow(
			maxf(v, float(flight.min_airspeed_ms)) / trim_speed(), float(wing.roll_speed_exponent)
		)
		sf = clampf(sf, float(wing.roll_speed_factor_min), float(wing.roll_speed_factor_max))
		var p_cmd := clampf(input.roll, -1.0, 1.0) * _roll_rate_max * sf
		if stalled:
			p_cmd *= float(st.roll_authority_factor)
		# сваливание на крыло: в крене опущенная консоль срывается первой и продолжает падать
		if stalled and absf(bank) > Units.deg(float(st.wing_drop_bank_deg)):
			p_cmd += signf(bank) * Units.deg(float(st.wing_drop_roll_rate_dps))
		roll_rate += (p_cmd + p_air - roll_rate) * (1.0 - exp(-dt / _tau_roll))
	bank += roll_rate * dt
	var max_bank := Units.deg(float(wing.max_bank_deg))
	if absf(bank) > max_bank:
		bank = signf(bank) * max_bank
		roll_rate = 0.0


## «Смещение веса»: input.roll — положение пилота (−1..+1, 0 — центр). Смещение даёт кренящий
## момент (угловая скорость weight_shift.roll_rate_max_dps · u на триме), собственная
## устойчивость крыла возвращает его к горизонту (−roll_stability · крен). Держишь смещение —
## установившийся крен ∝ смещению; вернулся в центр — крыло выравнивается и летит прямо.
func _roll_weight_shift(dt: float, input: ControlInput, v: float, p_air: float) -> void:
	var st: Dictionary = wing.stall
	var p_cmd := clampf(input.roll, -1.0, 1.0) * _roll_rate_max_ws * roll_authority(v)
	var p_stab := -roll_stability(bank) * bank
	if stalled:
		p_cmd *= float(st.roll_authority_factor)
		p_stab *= float(st.roll_authority_factor)
	if stalled and absf(bank) > Units.deg(float(st.wing_drop_bank_deg)):
		p_cmd += signf(bank) * Units.deg(float(st.wing_drop_roll_rate_dps))
		p_stab = 0.0
	roll_rate += (p_cmd + p_stab + p_air - roll_rate) * (1.0 - exp(-dt / _tau_roll_ws))


## «Смещение веса»: эффективность смещения на воздушной скорости v (1 — на триме): ниже трима
## крыло вялое ((V/V_трим)^roll_speed_exponent), выше — тяжелеет ((V_трим/V)^roll_heavy_exponent).
func roll_authority(v: float) -> float:
	var vr := maxf(v, float(flight.min_airspeed_ms)) / trim_speed()
	var sf := pow(vr, float(wing.roll_speed_exponent))
	if vr > 1.0:
		sf = pow(vr, -float(_ws.roll_heavy_exponent))
	return clampf(sf, float(wing.roll_speed_factor_min), float(wing.roll_speed_factor_max))


## «Смещение веса»: собственная устойчивость по крену при крене bank_rad, 1/с: база + добавка,
## растущая как (крен/45°)² — на малом крене спортивное крыло почти нейтрально, круто завалить
## труднее.
## Круче roll_overbank_deg (смещением туда не попасть — только болтанкой или сваливанием)
## возвращающий момент за OVERBANK_FADE_DEG сходит на нет: крыло в спирали, из центра само
## не выходит — только смещением в обратную сторону.
func roll_stability(bank_rad: float) -> float:
	var a := absf(bank_rad)
	var ob := minf(a, _roll_overbank)
	var r := ob / (0.25 * PI)
	var k := _roll_stability + _roll_stability_steep * r * r
	if a > _roll_overbank:
		k *= ob / a * maxf(0.0, 1.0 - (a - ob) / Units.deg(OVERBANK_FADE_DEG))
	return k


## «Смещение веса»: положение пилота, при котором на воздушной скорости v установившийся крен
## равен bank_rad (без потоков) — упреждение к регулятору крена.
func roll_input_for_bank(bank_rad: float, v: float) -> float:
	var p := _roll_rate_max_ws * roll_authority(v)
	return roll_stability(bank_rad) * bank_rad / maxf(p, 1.0e-3)


func _step_ground(dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> void:
	match _ground.step(self, dt, input, air_fn, ground_fn):
		GroundRun.Result.TOOK_OFF:
			mode = Mode.AIR
			_upright = true
			_yaw_align = true
			_accel_t = 0.0
			took_off.emit()
		GroundRun.Result.FAILED:
			takeoff_failure = _ground.failure
			mode = Mode.FAILED
			velocity = Vector3.ZERO
			takeoff_failed.emit(takeoff_failure)


func _update_telemetry(air_fn: Callable, ground_fn: Callable) -> void:
	FlightTelemetry.fill(self, air_fn, ground_fn)
