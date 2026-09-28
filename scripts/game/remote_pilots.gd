class_name RemotePilots
extends Node3D
## Чужие пилоты сетевой зоны (docs/plan/multiplayer.md → NET-41): живые пилоты и боты ведущего
## рисуются тем же видом, что боты одиночной игры (BotGlider: крыло своей расцветки, пилот,
## позы по фазе, шаги, имя над крылом). Физики нет — только вид; столкновений нет.
##
## Вход — PilotState (server/proto/deltaplan/v1/net.proto) словарём: как отдаёт
## NetMessages.decode (lowerCamelCase: pilotId, isBot, name, t, pos, rot, vel, phase, wing,
## colors) или те же поля в snake_case (pilot_id, is_bot).
##   pos, vel — Vector3 | {x, y, z} | [x, y, z]; rot — Basis | Quaternion | {x, y, z, w} |
##   [x, y, z, w]; phase — имя PilotPhase ("PILOT_PHASE_FLY") или число enum, или фаза
##   Telemetry ("standing" / "walking" / "running" / "flying" / "landed" / "failed");
##   wing — "wings/sport" или "sport"; colors — WingColors {hueDeg | hue_deg, sat, value}
##   | номер или имя схемы bots.json → visual.sail_schemes | Color; null — родная текстура.
##   Нет поля — остаётся прежнее значение.
## upsert(state) — новое состояние (создаёт пилота); remove(id) — ушёл. Позу между пакетами
## считает интерполяция сети (NET-32) и отдаёт каждый кадр через set_pose(); без неё — последнее
## состояние, продлённое по скорости (не дальше extrapolate_max_s).
## Нет состояний дольше lost_after_s — пилот «пропал» и убирается.
## Для других систем (близость, «догнать»): pilots(), get_pilot(); узел в группе GROUP.

signal pilot_added(pilot_id: String)
## reason: "left" (remove) или "lost" (нет состояний lost_after_s).
signal pilot_removed(pilot_id: String, reason: String)

const GROUP := "remote_pilots"
## Фазы (нормализованные): порядок = PilotPhase из net.proto (1 — standing …).
const PHASES: Array[String] = [
	"standing", "walking", "running", "flying", "landed", "crashed", "tow"
]
## PilotPhase (без префикса) → фаза.
const PROTO_PHASES := {
	"stand": "standing",
	"walk": "walking",
	"run": "running",
	"fly": "flying",
	"landed": "landed",
	"crashed": "crashed",
	"tow": "tow",
}
const GROUND_PHASES: Array[String] = [
	"standing", "walking", "running", "landed", "failed", "crashed"
]


## Один чужой пилот.
class Pilot:
	extends RefCounted
	var id: String = ""
	var is_bot: bool = false
	var pilot_name: String = ""
	var wing: String = ""
	## wing как пришёл в состоянии (разбор — только при смене).
	var wing_raw: Variant = null
	var colors: Variant = null
	## Время пакета (t из состояния, время зоны), с.
	var t: float = 0.0
	var position := Vector3.ZERO
	var basis := Basis.IDENTITY
	var velocity := Vector3.ZERO
	var phase: String = "standing"
	## Сколько прошло с последнего состояния (upsert или set_pose), с.
	var silent_s: float = 0.0
	## Позу задаёт интерполяция снаружи (set_pose): upsert позу не трогает.
	var external_pose: bool = false
	## Возраст последнего состояния для продления по скорости, с.
	var age_s: float = 0.0
	## Вид: BotAgent без физики (телеметрию пишем сами) и BotGlider.
	var agent: BotAgent
	var glider: BotGlider


## Строить узлы вида (false — только данные: headless-тесты, подсчёт близости).
var visuals_enabled := true
## Нет состояний дольше — «пропал», с (0 — не убирать).
var lost_after_s := 5.0
## Продление последнего состояния по скорости без set_pose, не дольше, с.
var extrapolate_max_s := 0.5
## Высота рельефа (x, z) -> м: высота над землёй для поз, на земле — ставим на рельеф.
var ground_fn: Callable = Callable()

var _pilots: Dictionary = {}  # id (String) -> Pilot
var _vis_cfg: Dictionary = {}


func _ready() -> void:
	add_to_group(GROUP)
	# В сети пауза мир не останавливает: чужие пилоты летят и при открытом меню.
	process_mode = Node.PROCESS_MODE_ALWAYS
	Config.reloaded.connect(_on_config_reloaded)


## Высота рельефа из Terrain (height_at).
func setup_in_world(terrain: Node) -> void:
	if terrain != null and terrain.has_method("height_at"):
		ground_fn = Callable(terrain, "height_at")


## Новое состояние пилота (из сети). Нет такого — появляется.
func upsert(state: Dictionary) -> void:
	var id := str(state.get("pilot_id", state.get("pilotId", "")))
	if id == "":
		return
	var p: Pilot = _pilots.get(id)
	var fresh := p == null
	if fresh:
		p = Pilot.new()
		p.id = id
		_pilots[id] = p
	var rebuild := fresh
	if state.has("is_bot") or state.has("isBot"):
		p.is_bot = bool(state.get("is_bot", state.get("isBot")))
	if state.has("name"):
		p.pilot_name = String(state.name)
	if state.has("wing") and not _same(state.wing, p.wing_raw):
		p.wing_raw = state.wing
		var w := _wing_id(String(state.wing))
		rebuild = rebuild or w != p.wing
		p.wing = w
	if p.wing == "":
		p.wing = _wing_id("")
	if state.has("colors") and not _same(state.colors, p.colors):
		p.colors = state.colors
		rebuild = true
	if state.has("t"):
		p.t = float(state.t)
	if not p.external_pose:
		if state.has("pos"):
			p.position = to_vec3(state.pos)
		if state.has("rot"):
			p.basis = to_basis(state.rot)
		if state.has("vel"):
			p.velocity = to_vec3(state.vel)
		if state.has("phase"):
			p.phase = phase_name(state.phase)
		p.age_s = 0.0
	p.silent_s = 0.0
	if rebuild:
		_build(p)
	_apply(p, 0.0)
	if fresh:
		pilot_added.emit(id)


## Поза на этот кадр от интерполяции (NET-32): с этого момента upsert позу не меняет.
func set_pose(
	pilot_id: Variant, pos: Vector3, rot: Variant, vel: Vector3, phase: Variant = null
) -> void:
	var p: Pilot = _pilots.get(str(pilot_id))
	if p == null:
		return
	p.external_pose = true
	p.position = pos
	p.basis = to_basis(rot)
	p.velocity = vel
	if phase != null:
		p.phase = phase_name(phase)
	p.age_s = 0.0
	p.silent_s = 0.0


## Пилот ушёл из зоны.
func remove(pilot_id: Variant, reason: String = "left") -> void:
	var id := str(pilot_id)
	var p: Pilot = _pilots.get(id)
	if p == null:
		return
	_pilots.erase(id)
	if is_instance_valid(p.glider):
		p.glider.queue_free()
	pilot_removed.emit(id, reason)


## Убрать всех (выход из зоны).
func clear() -> void:
	for id: String in _pilots.keys():
		remove(id)


func has_pilot(pilot_id: Variant) -> bool:
	return _pilots.has(str(pilot_id))


func get_pilot(pilot_id: Variant) -> Pilot:
	return _pilots.get(str(pilot_id))


func count() -> int:
	return _pilots.size()


func pilot_ids() -> PackedStringArray:
	return PackedStringArray(_pilots.keys())


## Все чужие пилоты сейчас: [{pilot_id, name, is_bot, position, velocity, phase}].
func pilots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Pilot in _pilots.values():
		(
			out
			. append(
				{
					"pilot_id": p.id,
					"name": p.pilot_name,
					"is_bot": p.is_bot,
					"position": _shown_position(p),
					"velocity": p.velocity,
					"phase": p.phase,
				}
			)
		)
	return out


func _process(dt: float) -> void:
	tick(dt)


## Кадр: «пропавшие» уходят, остальные — на свою позу (зовёт _process; тесты — сами).
func tick(dt: float) -> void:
	for p: Pilot in _pilots.values():
		p.silent_s += dt
		p.age_s += dt
		if lost_after_s > 0.0 and p.silent_s > lost_after_s:
			remove(p.id, "lost")
			continue
		_apply(p, dt)


## Позиция для вида: своя поза или последнее состояние, продлённое по скорости.
func _shown_position(p: Pilot) -> Vector3:
	var pos := p.position
	if not p.external_pose:
		pos += p.velocity * minf(p.age_s, extrapolate_max_s)
	if GROUND_PHASES.has(p.phase) and ground_fn.is_valid():
		pos.y = float(ground_fn.call(pos.x, pos.z))
	return pos


## Поза → телеметрия BotAgent (физики нет) → BotGlider повторяет её, как у бота.
func _apply(p: Pilot, dt: float) -> void:
	if p.agent == null:
		return
	var a := p.agent
	var t := a.model.telemetry
	# Вид по фазе: буксир — поза полёта, авария — стоит (как после посадки).
	var ph := p.phase
	if ph == "tow":
		ph = "flying"
	elif ph == "crashed":
		ph = "landed"
	var pos := _shown_position(p)
	var vario := p.velocity.y
	t.position = pos
	t.basis = p.basis
	t.velocity = p.velocity
	t.vario = vario
	t.groundspeed = Vector2(p.velocity.x, p.velocity.z).length()
	t.airspeed = p.velocity.length()
	t.phase = ph
	t.on_ground = ph != "flying"
	t.altitude_msl = pos.y
	t.altitude_agl = pos.y - float(ground_fn.call(pos.x, pos.z)) if ground_fn.is_valid() else 1.0e3
	if not t.on_ground and t.altitude_agl > 1.0e3:
		t.altitude_agl = 1.0e3
	a.model.position = pos
	a.model.velocity = p.velocity
	match ph:
		"flying":
			a.model.mode = FlightModel.Mode.AIR
			a.state = BotAgent.State.FLY
		"walking":
			a.model.mode = FlightModel.Mode.GROUND
			a.state = BotAgent.State.WALK
		"running":
			a.model.mode = FlightModel.Mode.GROUND
			a.state = BotAgent.State.RUN
		"landed", "failed":
			a.model.mode = FlightModel.Mode.LANDED
			a.state = BotAgent.State.LANDED
		_:
			a.model.mode = FlightModel.Mode.GROUND
			a.state = BotAgent.State.WAIT
	a.pilot_name = p.pilot_name
	if p.glider != null:
		if dt <= 0.0:
			p.glider.snap()
		else:
			# Шаг «бота» длиной в кадр: BotGlider сразу ставит позу (без своей интерполяции).
			p.glider.on_step(dt)
			p.glider.advance(dt)
			p.glider.transform = Transform3D(p.basis, pos)


## (Пере)создать вид: новое крыло или расцветка.
func _build(p: Pilot) -> void:
	if is_instance_valid(p.glider):
		p.glider.queue_free()
	p.glider = null
	var a := BotAgent.new()
	a.id = absi(hash(p.id)) % 100000
	a.setup(
		Config.get_config("bots"),
		p.wing,
		80.0,
		func(_q: Vector3) -> Vector3: return Vector3.ZERO,
		ground_fn if ground_fn.is_valid() else func(_x: float, _z: float) -> float: return 0.0,
		a.id
	)
	a.scheme = _scheme(p)
	a.pilot_name = p.pilot_name
	a.model.reset_on_ground(p.position, 0.0)
	p.agent = a
	if not visuals_enabled:
		return
	if _vis_cfg.is_empty():
		_vis_cfg = Config.get_config("bots").get("visual", {})
	var g := BotGlider.new()
	g.name = "Remote_%s" % p.id.validate_node_name()
	g.add_to_group(GROUP)
	add_child(g)
	_apply(p, 0.0)
	g.setup(a, _vis_cfg)
	p.glider = g


## Расцветка паруса из colors (см. шапку); {} — родная текстура крыла.
func _scheme(p: Pilot) -> Dictionary:
	var schemes: Array = Config.get_config("bots").get("visual", {}).get("sail_schemes", [])
	var c: Variant = p.colors
	var out := {}
	if c is Dictionary:
		var d := c as Dictionary
		out = {
			"hue_deg": float(d.get("hue_deg", d.get("hueDeg", 0.0))),
			"sat": float(d.get("sat", 1.0)),
			"value": float(d.get("value", 1.0)),
		}
	elif c is Color:
		var col := c as Color
		out = {"hue_deg": col.h * 360.0, "sat": clampf(col.s, 0.0, 1.0), "value": col.v}
	elif (c is int or c is float) and not schemes.is_empty():
		out = schemes[posmod(int(c), schemes.size())]
	elif c is String:
		for s: Dictionary in schemes:
			if String(s.get("name", "")) == c:
				out = s
	return out


static func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


## Id крыла без "wings/"; неизвестное — первое из bots.json → wings (или любое).
static func _wing_id(w: String) -> String:
	w = w.trim_prefix("wings/")
	var all := Config.list_configs("wings")
	if w != "" and all.has("wings/" + w):
		return w
	var wings: Array = Config.get_config("bots").get("wings", [])
	if not wings.is_empty():
		return String(wings[0])
	return String(all[0]).get_file() if not all.is_empty() else "atlas"


## Фаза из имени PilotPhase ("PILOT_PHASE_FLY"), фазы Telemetry ("flying") или числа enum
## (0 и незнакомое — standing).
static func phase_name(v: Variant) -> String:
	if v is int or v is float:
		var i := int(v) - 1
		return PHASES[i] if i >= 0 and i < PHASES.size() else "standing"
	var s := String(v).to_lower().trim_prefix("pilot_phase_")
	if PROTO_PHASES.has(s):
		return PROTO_PHASES[s]
	return s if PHASES.has(s) or s == "failed" else "standing"


static func to_vec3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Dictionary:
		var d := v as Dictionary
		return Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))
	if v is Array or v is PackedFloat32Array or v is PackedFloat64Array:
		if v.size() >= 3:
			return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


static func to_basis(v: Variant) -> Basis:
	if v is Basis:
		return v
	if v is Quaternion:
		return Basis((v as Quaternion).normalized())
	var q := Quaternion.IDENTITY
	if v is Dictionary:
		var d := v as Dictionary
		q = Quaternion(
			float(d.get("x", 0.0)),
			float(d.get("y", 0.0)),
			float(d.get("z", 0.0)),
			float(d.get("w", 1.0))
		)
	elif (v is Array or v is PackedFloat32Array or v is PackedFloat64Array) and v.size() >= 4:
		q = Quaternion(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
	if q.length_squared() < 1.0e-8:
		return Basis.IDENTITY
	return Basis(q.normalized())


## Показ и вид имён — как у ботов (пункт «Имена пилотов» в настройках).
func _on_config_reloaded() -> void:
	var nc: Dictionary = Config.get_config("bots").get("names", {})
	for p: Pilot in _pilots.values():
		if is_instance_valid(p.glider):
			p.glider.set_name_config(nc)
