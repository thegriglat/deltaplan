class_name CatchUpTow
extends RefCounted
## «Догнать» — буксир к другу (NET-42, docs/plan/multiplayer.md): кинематический перелёт без
## физики полёта. Сам по себе ничего не двигает — шаг возвращает, где должно быть крыло.
##
## API:
##   var tow := CatchUpTow.new()                       # числа — Config "net" → catch_up
##   var tow := CatchUpTow.new(cfg, height_fn)         # cfg — словарь как net.catch_up (тесты),
##                                                     # height_fn(x, z) -> float — высота земли
##                                                     # (обычно terrain.height_at); пусто — 0
##   tow.start(own_pos, own_vel, target_fn, own_heading_rad := NAN)
##       target_fn() -> Dictionary {position: Vector3, velocity: Vector3}; пустой словарь —
##       цель потеряна (ушла из зоны, села) → буксир сам останавливается (state "lost").
##       own_vel — текущая скорость крыла (с земли — Vector3.ZERO): скорость сводится плавно.
##   tow.step(dt) -> Dictionary      # раз в шаг физики, пока is_active()
##   tow.abort()                     # отмена (Esc / «=») — стоп «на месте», state "aborted"
##   tow.lose_target()               # цель ушла из зоны / села (или target_fn вернул {})
##   tow.is_active() -> bool
##   tow.last -> Dictionary          # последний результат step() (и после abort/lose)
## Результат step():
##   position: Vector3   — где крыло (ноги пилота, как Glider/FlightModel.position)
##   velocity: Vector3   — скорость над землёй, м/с
##   heading: float      — курс, рад (0 — север, π/2 — восток, как FlightModel.heading)
##   bank: float         — крен, рад (плюс — правое крыло вниз, как FlightModel.bank)
##   basis: Basis        — Basis.from_euler(Vector3(0, -heading, -bank)), как в телеметрии
##   speed: float        — модуль скорости, м/с (для звука потока)
##   rel_speed: float    — скорость относительно цели по «куполу», м/с
##   distance: float     — до точки прибытия, м;  target_distance — до самой цели, м
##   state: String       — "ramping", "cruising", "braking", "matching", "done", "aborted", "lost"
##   active: bool        — false: буксир закончен, физику пора вернуть пилоту
## Когда active == false: крыло ставят в position с курсом heading на триммерной скорости
## (Glider.reset_in_air(position, rad_to_deg(heading))), velocity — для справки (у "done" это
## скорость цели).
##
## Как летим. В плане — преследование точки прибытия A (arrive_offset_m позади-сбоку цели),
## пересчитывается каждый шаг. Движемся относительно A: скорость = скорость A + w, где |w| —
## «купол»: разгон ramp_s по smootherstep, середина v = d0 / (t_target_s − ramp_s) ≤ v_max,
## торможение — по оставшемуся пути (тот же smootherstep, начинается при d ≤ v·ramp_s/2);
## w направлено на A в 3D, поэтому высота цели набирается тем же куполом. Сверху —
## «подъём над рельефом» L ≥ 0: рельеф впереди по курсу + clearance_m, дальние точки с меньшим
## весом (плавная «горка»), сглажен тремя звеньями (ускорение без скачков). Разница начальной
## скорости крыла и скорости A гасится за время разгона (с земли — старт с нуля).

const G := 9.81

var cfg: Dictionary = {}
var height_fn: Callable = Callable()
var last: Dictionary = {}
## Сколько шагов сработала последняя страховка «не ниже земли» (в норме 0; для тестов).
var ground_hits := 0

var _target_fn: Callable = Callable()
var _state := "done"
var _t := 0.0
var _t_match := 0.0
var _v_c := 0.0  ## скорость середины купола, м/с
var _base := Vector3.ZERO  ## точка без подъёма над рельефом (чистое преследование)
var _lift := [0.0, 0.0, 0.0]  ## три звена сглаживания подъёма
var _pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _vel0_offset := Vector3.ZERO  ## начальная скорость минус скорость A — гасится за разгон
var _arrive := Vector3.ZERO
var _arrive_vel := Vector3.ZERO
var _side := 1.0
var _tgt_heading := 0.0
var _heading := 0.0
var _bank := 0.0
var _rel_speed := 0.0
var _tgt_pos := Vector3.ZERO


func _init(config: Dictionary = {}, height: Callable = Callable()) -> void:
	cfg = config if not config.is_empty() else Config.value("net", "catch_up", {})
	height_fn = height


func is_active() -> bool:
	return _state in ["ramping", "cruising", "braking", "matching"]


func start(
	own_pos: Vector3, own_vel: Vector3, target_fn: Callable, own_heading_rad: float = NAN
) -> void:
	_target_fn = target_fn
	var tg := _target()
	if tg.is_empty():
		_pos = own_pos
		_vel = own_vel
		_heading = own_heading_rad if not is_nan(own_heading_rad) else 0.0
		_state = "lost"
		last = _result()
		return
	var tp: Vector3 = tg.position
	var tv: Vector3 = tg.velocity
	_tgt_pos = tp
	var tvh := Vector2(tv.x, tv.z)
	if tvh.length() > 1.0:
		_tgt_heading = atan2(tvh.x, -tvh.y)
	else:  # цель почти стоит — «позади» считаем со стороны, откуда летим
		_tgt_heading = atan2(tp.x - own_pos.x, -(tp.z - own_pos.z))
	# сторона прибытия — та, с которой подлетаем (не пересекать курс цели в конце)
	var right := Vector3(cos(_tgt_heading), 0.0, sin(_tgt_heading))
	_side = 1.0 if (own_pos - tp).dot(right) >= 0.0 else -1.0
	_arrive = _arrive_point(tp)
	_arrive_vel = tv
	_pos = own_pos
	_base = own_pos
	_vel = own_vel
	_vel0_offset = own_vel - tv
	_lift = [0.0, 0.0, 0.0]
	_t = 0.0
	_t_match = 0.0
	_rel_speed = 0.0
	_bank = 0.0
	var d0 := _base.distance_to(_arrive)
	var t_a := float(cfg.ramp_s)
	var t_total := float(cfg.t_target_s)
	var v_max := float(cfg.v_max_kmh) / 3.6
	_v_c = clampf(d0 / maxf(t_total - t_a, 0.1), float(cfg.get("v_min_ms", 3.0)), v_max)
	if not is_nan(own_heading_rad):
		_heading = own_heading_rad
	elif Vector2(own_vel.x, own_vel.z).length() > 1.0:
		_heading = atan2(own_vel.x, -own_vel.z)
	else:
		_heading = atan2(_arrive.x - own_pos.x, -(_arrive.z - own_pos.z))
	_state = "matching" if d0 < float(cfg.match_enter_m) else "ramping"
	last = _result()


func abort() -> void:
	if is_active():
		_state = "aborted"
	last = _result()


func lose_target() -> void:
	if is_active():
		_state = "lost"
	last = _result()


func step(dt: float) -> Dictionary:
	if not is_active() or dt <= 0.0:
		last = _result()
		return last
	var tg := _target()
	if tg.is_empty():
		lose_target()
		return last
	_t += dt
	_tgt_pos = tg.position
	var t_a := float(cfg.ramp_s)

	# точка прибытия: курс цели сглажен (разворот цели не дёргает точку)
	var tv: Vector3 = tg.velocity
	if Vector2(tv.x, tv.z).length() > 1.0:
		var want := atan2(tv.x, -tv.z)
		var k_h := 1.0 - exp(-dt / float(cfg.target_heading_tau_s))
		_tgt_heading += wrapf(want - _tgt_heading, -PI, PI) * k_h
	var new_arrive := _arrive_point(tg.position)
	_arrive_vel = (new_arrive - _arrive) / dt
	_base += new_arrive - _arrive  # движемся в системе точки прибытия
	_arrive = new_arrive

	# купол скорости относительно точки прибытия
	var to_a := _arrive - _base
	var d := to_a.length()
	var s_ramp := _v_c * (_smoother(_t / t_a) if _t < t_a else 1.0)
	var s_brake := _brake_speed(d, _v_c, t_a)
	var s := minf(s_ramp, s_brake)
	var move := minf(s * dt, d)
	if d > 1e-6:
		_base += to_a / d * move
	_rel_speed = move / dt
	# начальная скорость крыла сводится к скорости точки за время разгона
	var fade := 1.0 - _smoother(_t / t_a)
	_base += _vel0_offset * fade * dt

	# подъём над рельефом
	var lift_req := _lift_required(_arrive - _base)
	var k_l := 1.0 - exp(-dt / float(cfg.lift_tau_s))
	_lift[0] += (lift_req - _lift[0]) * k_l
	_lift[1] += (_lift[0] - _lift[1]) * k_l
	_lift[2] += (_lift[1] - _lift[2]) * k_l
	var new_pos := _base + Vector3.UP * float(_lift[2])
	if height_fn.is_valid():  # последняя страховка — не должна срабатывать
		var ground := float(height_fn.call(new_pos.x, new_pos.z))
		if new_pos.y < ground - 0.01:
			ground_hits += 1
			new_pos.y = ground
	_vel = (new_pos - _pos) / dt
	_pos = new_pos
	_orient(dt)

	# состояние
	var d_left := _base.distance_to(_arrive)
	match _state:
		"matching":
			_t_match += dt
			if _t_match >= float(cfg.match_s):
				_state = "done"
		_:
			if d_left < float(cfg.match_enter_m) and _t >= t_a:
				_state = "matching"
			elif _t < t_a:
				_state = "ramping"
			elif s_brake < _v_c:
				_state = "braking"
			else:
				_state = "cruising"
	last = _result()
	return last


# ---------------- внутреннее ----------------


func _target() -> Dictionary:
	if not _target_fn.is_valid():
		return {}
	var r: Variant = _target_fn.call()
	if r is Dictionary and r.has("position"):
		if not r.has("velocity"):
			r["velocity"] = Vector3.ZERO
		return r
	return {}


func _arrive_point(tp: Vector3) -> Vector3:
	var fwd := Vector3(sin(_tgt_heading), 0.0, -cos(_tgt_heading))
	var right := Vector3(cos(_tgt_heading), 0.0, sin(_tgt_heading))
	var a := deg_to_rad(float(cfg.arrive_side_deg))
	var off := float(cfg.arrive_offset_m)
	return tp - fwd * off * cos(a) + right * _side * off * sin(a)


## smootherstep: 6x⁵ − 15x⁴ + 10x³ (в начале и в конце скорость и ускорение нулевые).
static func _smoother(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)


## Скорость торможения по оставшемуся пути d: при торможении smootherstep за t_a с скорости v
## путь до конца D(x) = v·t_a·(1/2 − x + x⁶ − 3x⁵ + 5x⁴/2), x — доля времени торможения.
## Находим x по d, скорость — v·(1 − S(x)). В номинале совпадает с торможением по времени,
## а если цель сместилась — тормозим точно в точку.
static func _brake_speed(d: float, v: float, t_a: float) -> float:
	var full := v * t_a * 0.5
	if d >= full:
		return v
	if d <= 0.0:
		return 0.0
	var lo := 0.0
	var hi := 1.0
	for i in 40:
		var x := (lo + hi) * 0.5
		var x4 := x * x * x * x
		var rest := v * t_a * (0.5 - x + x4 * x * x - 3.0 * x4 * x + 2.5 * x4)
		if rest > d:
			lo = x
		else:
			hi = x
	return v * (1.0 - _smoother((lo + hi) * 0.5))


## Насколько поднять точку преследования над рельефом впереди по курсу, м (≥ 0).
func _lift_required(to_arrive: Vector3) -> float:
	if not height_fn.is_valid():
		return 0.0
	var hv := Vector2(_vel.x, _vel.z)
	var ta := Vector2(to_arrive.x, to_arrive.z)
	var d_h := ta.length()
	var dir := hv.normalized() if hv.length() > 2.0 else (ta / d_h if d_h > 0.01 else Vector2.ZERO)
	var speed := maxf(hv.length(), 1.0)
	var look_s := float(cfg.look_ahead_s)
	var full_s := float(cfg.look_full_s)
	var look := maxf(speed * look_s, float(cfg.look_min_m))
	var clr := float(cfg.clearance_m)
	var clr_min := float(cfg.arrive_min_agl_m)
	var fade_m := float(cfg.arrive_fade_m)
	var n := int(cfg.look_samples)
	var need := 0.0
	for j in n + 1:
		var k := look * float(j) / float(n)
		var p := Vector2(_base.x, _base.z) + dir * k
		# высота «чистого преследования» в этой точке — по прямой к точке прибытия
		var along := clampf(k / d_h, 0.0, 1.0) if d_h > 0.01 else 1.0
		var base_y := _base.y + to_arrive.y * along
		var rest := maxf(d_h - k, 0.0)
		var c := lerpf(clr_min, clr, clampf(rest / fade_m, 0.0, 1.0))
		var t_k := k / speed
		var w := 1.0
		if t_k > full_s:
			w = _smoother(1.0 - (t_k - full_s) / maxf(look_s - full_s, 0.01))
		var h := float(height_fn.call(p.x, p.y))
		need = maxf(need, (h + c - base_y) * w)
	return need


func _orient(dt: float) -> void:
	var hv := Vector2(_vel.x, _vel.z)
	var prev := _heading
	if hv.length() > 1.0:
		var want := atan2(hv.x, -hv.y)
		var k := 1.0 - exp(-dt / float(cfg.heading_tau_s))
		_heading = wrapf(_heading + wrapf(want - _heading, -PI, PI) * k, -PI, PI)
	var omega := wrapf(_heading - prev, -PI, PI) / dt
	var bank_max := deg_to_rad(float(cfg.bank_max_deg))
	var want_bank := clampf(atan(hv.length() * omega / G), -bank_max, bank_max)
	_bank += (want_bank - _bank) * (1.0 - exp(-dt / float(cfg.bank_tau_s)))


func _result() -> Dictionary:
	return {
		"position": _pos,
		"velocity": _vel,
		"heading": _heading,
		"bank": _bank,
		"basis": Basis.from_euler(Vector3(0.0, -_heading, -_bank)),
		"speed": _vel.length(),
		"rel_speed": _rel_speed,
		"distance": _base.distance_to(_arrive),
		"target_distance": _pos.distance_to(_tgt_pos),
		"state": _state,
		"active": is_active(),
	}
