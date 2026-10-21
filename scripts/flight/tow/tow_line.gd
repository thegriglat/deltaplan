class_name TowLine
extends RefCounted
## Трос и лебёдка (TW-К5 v6, docs/contracts/tow.md). Трос — неявное одностороннее звено TW-К4 (XPBD в модели
## полёта): TowLine отдаёт модели {anchor, anchor_vel, length_m, length_rate_ms, compliance_m_per_n, damping_s, at}
## и сам двигает длину L регулятором барабана по натяжению (T берётся из s.link_tension_n). Явной пружины нет.
## Допущения: трос в силе — невесомая нить (масса погонного метра идёт только в отрисовку points); воздух неподвижен
## (парашют свободного конца); ЕА постоянна (без нелинейности и ползучести Dyneema).

signal released(reason: String)
signal broken

const G := 9.80665
const RHO := 1.225

var kind: String
var cfg_rope: Dictionary = {}
var cfg: Dictionary = {}  ## блок kind (winch_static / aerotow)

## Якорь (мир игры). Лебёдка неподвижна; буксировщик обновляет владелец (TW-7).
var anchor_pos := Vector3.ZERO
var anchor_vel := Vector3.ZERO

## Только чтение.
var state: String = "slack"  ## slack | taut | released | broken
var phase: String = "idle"  ## idle | slack | ground | climb | top
var tension_n: float = 0.0
var length_m: float = 0.0
var rope_angle_deg: float = 0.0
var lockout_angle_deg: float = 0.0

## Свободный трос после отцепа/обрыва.
var end_pos := Vector3.ZERO
var end_vel := Vector3.ZERO
var reeled_in: bool = false
## f(x, z) -> высота земли; по умолчанию плоская на высоте якоря.
var ground_fn: Callable = Callable()

var _started: bool = false
var _gone: bool = false  ## отцеп или обрыв
var _len_init: bool = false
var _t_phase: float = 0.0
var _airborne: bool = false
var _climb_t: float = 0.0
var _ground_y: float = 0.0
var _attach_pos := Vector3.ZERO
var _attach_vel := Vector3.ZERO
var _attach_seen: bool = false
var _rate: float = 0.0
var _free_init: bool = false


static func create(kind_: String, anchor: Vector3, cfg_: Dictionary = {}) -> TowLine:
	var t := TowLine.new()
	t.kind = kind_
	var base: Dictionary = Config.get_config("tow").duplicate(true)
	for k: String in cfg_:
		if cfg_[k] is Dictionary and base.get(k) is Dictionary:
			base[k].merge(cfg_[k], true)
		else:
			base[k] = cfg_[k]
	t.cfg_rope = base.get("rope", {})
	t.cfg = base.get(kind_, {})
	t.anchor_pos = anchor
	t._ground_y = anchor.y
	if kind_ == "aerotow" and t.cfg.has("rope_length_m"):
		t.length_m = float(t.cfg.rope_length_m)
		t._len_init = true
	return t


func _rope(key: String) -> float:
	return float(cfg_rope[key])


func _c(key: String) -> float:
	return float(cfg[key])


## Старт по W: до вызова фаза idle, звено не возвращается.
func start() -> void:
	if _started or _gone:
		return
	_started = true
	_t_phase = 0.0
	phase = "slack"
	if kind != "winch_static":
		phase = "climb"


func release(reason: String = "pilot") -> void:
	if _gone:
		return
	_gone = true
	state = "released"
	tension_n = 0.0
	_begin_free()
	released.emit(reason)


## Функция для Glider.set_external_force: зовётся на каждом подшаге модели.
func force_fn() -> Callable:
	return Callable(self, "_force")


func _force(s: Dictionary) -> Dictionary:
	var at: String = cfg_rope.get("attach", "pilot")
	var p: Vector3 = s.pilot_pos if at == "pilot" else s.hang_pos
	_attach_pos = p
	_attach_vel = s.pilot_vel if at == "pilot" else s.hang_vel
	_attach_seen = true
	if _gone:
		return {}
	var h: float = s.h
	var d_vec: Vector3 = anchor_pos - p
	_update_angles(s, d_vec)
	if not _len_init or not _started:
		if kind == "winch_static":
			length_m = (anchor_pos - p).length() + _c("slack_m")
			_len_init = true
	if not _started:
		tension_n = 0.0
		state = "slack"
		return {}
	var t: float = s.link_tension_n
	tension_n = t
	if t > _rope("weak_link_daN") * 10.0:
		_gone = true
		state = "broken"
		tension_n = 0.0
		_begin_free()
		broken.emit()
		return {}
	state = "taut" if t > 0.0 else "slack"
	var ea := _rope("ea_n")
	if kind == "winch_static":
		_regulate(s, t, ea, h)
	else:
		_rate = 0.0
	var k_rope := ea / maxf(length_m, 0.5)
	var tau := 2.0 * _rope("damping_ratio") * sqrt(_rope("effective_mass_kg") / k_rope)
	return {"link": {
		"anchor": anchor_pos, "anchor_vel": anchor_vel, "length_m": maxf(length_m, 0.0),
		"length_rate_ms": _rate, "compliance_m_per_n": maxf(length_m, 0.5) / ea,
		"damping_s": tau, "at": at,
	}}


func _update_angles(s: Dictionary, d_vec: Vector3) -> void:
	var dh := Vector2(d_vec.x, d_vec.z).length()
	rope_angle_deg = rad_to_deg(atan2(-d_vec.y, maxf(dh, 1.0e-6)))
	var fwd: Vector3 = -(s.wing_basis as Basis).z
	var f2 := Vector2(fwd.x, fwd.z)
	var a2 := Vector2(d_vec.x, d_vec.z)
	if f2.length() > 1.0e-6 and a2.length() > 1.0e-6:
		lockout_angle_deg = rad_to_deg(absf(f2.angle_to(a2)))


func _regulate(s: Dictionary, t: float, ea: float, h: float) -> void:
	var target := 0.0
	_t_phase += h
	var ramp := maxf(_c("ramp_s"), 1.0e-3)
	var t_ground := _c("tension_ground_daN") * 10.0
	var t_climb := _c("tension_climb_daN") * 10.0
	var rate: float
	if phase == "slack":
		if t > 0.0:
			phase = "ground"
			_t_phase = 0.0
		else:
			# слабину выбирают со скоростью slack_reel_speed_ms относительно пилота: оператор следит, чтобы
			# пилот, пошедший вперёд, не создавал новой слабины (сближение пилота с лебёдкой добавляется)
			var to_anchor: Vector3 = (anchor_pos - (s.pilot_pos as Vector3)).normalized()
			var closing := maxf(((s.pilot_vel as Vector3) - anchor_vel).dot(to_anchor), 0.0)
			rate = -minf(_c("slack_reel_speed_ms") + closing, _c("max_reel_speed_ms"))
			_apply_rate(rate, h)
			return
	if phase == "ground" and not bool(s.on_ground):
		_airborne = true
		phase = "climb"
		_climb_t = 0.0
	if phase == "ground":
		target = t_ground * minf(_t_phase / ramp, 1.0)
	else:
		_climb_t += h
		# переход T* от tension_ground к tension_climb за ramp_s (плавный, без ступени; К5 даёт только конечное значение)
		target = lerpf(t_ground, t_climb, minf(_climb_t / ramp, 1.0))
		var top_a := _c("top_angle_deg")
		if rope_angle_deg >= top_a:
			phase = "top"
			target = t_climb * clampf(1.0 - (rope_angle_deg - top_a) / (90.0 - top_a), 0.0, 1.0)
		elif phase == "top":
			phase = "climb"
	var vmax := _c("max_reel_speed_ms")
	rate = clampf((t - target) / (ea / maxf(length_m, 0.5)) / _c("ctrl_tau_s"), -vmax, vmax)
	_apply_rate(rate, h)


func _apply_rate(rate: float, h: float) -> void:
	var l_new := maxf(length_m + rate * h, 0.0)
	_rate = (l_new - length_m) / h
	length_m = l_new


## Конец троса после отцепа — точка массой end_mass_kg с парашютом.
func _begin_free() -> void:
	if _free_init:
		return
	_free_init = true
	end_pos = _attach_pos if _attach_seen else anchor_pos
	end_vel = _attach_vel if _attach_seen else Vector3.ZERO
	_ground_y = anchor_pos.y if not ground_fn.is_valid() else 0.0


func _ground_at(p: Vector3) -> float:
	return float(ground_fn.call(p.x, p.z)) if ground_fn.is_valid() else _ground_y


## Шаг свободного троса (после отцепа/обрыва): точка с тяжестью и сопротивлением парашюта, связь «не длиннее L»,
## лебёдка выбирает трос со скоростью max_reel_speed_ms до нуля.
func step_free(dt: float) -> void:
	if not _gone or reeled_in or dt <= 0.0:
		return
	var m := _rope("end_mass_kg")
	var cds := _rope("drogue_cd_area_m2")
	var sp := end_vel.length()
	var acc := Vector3(0.0, -G, 0.0) - end_vel * (0.5 * RHO * cds * sp / m)
	end_vel += acc * dt
	end_pos += end_vel * dt
	var reel := -_c("max_reel_speed_ms") if cfg.has("max_reel_speed_ms") else 0.0
	var l_new := maxf(length_m + reel * dt, 0.0)
	var rate := (l_new - length_m) / dt
	length_m = l_new
	var to := end_pos - anchor_pos
	var dist := to.length()
	if dist > length_m and dist > 1.0e-9:
		var n := to / dist
		end_pos = anchor_pos + n * length_m
		var vr := end_vel.dot(n)
		if vr > rate:
			end_vel -= n * (vr - rate)
	var gy := _ground_at(end_pos)
	if end_pos.y < gy:
		end_pos.y = gy
		if end_vel.y < 0.0:
			end_vel.y = 0.0
	if length_m <= 0.5:
		reeled_in = true
		length_m = 0.0
		end_pos = anchor_pos
		end_vel = Vector3.ZERO


## n ≥ 2 точек троса от конца (крепление / свободный конец) к якорю; пусто, когда трос выбран полностью.
func points(n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if n < 2 or reeled_in or length_m < 0.5:
		return out
	var a: Vector3 = end_pos if _gone else (_attach_pos if _attach_seen else anchor_pos)
	var b := anchor_pos
	var d := a.distance_to(b)
	var sag := 0.0
	if length_m > d:
		sag = sqrt(3.0 * d * (length_m - d) / 8.0)
	elif tension_n > 1.0:
		sag = float(cfg_rope.get("mass_per_m_kg", 0.0)) * G * d * d / (8.0 * tension_n)
	sag = minf(sag, 0.25 * d)
	for i in n:
		var u := float(i) / float(n - 1)
		var p := a.lerp(b, u)
		p.y -= 4.0 * sag * u * (1.0 - u)
		out.append(p)
	return out
