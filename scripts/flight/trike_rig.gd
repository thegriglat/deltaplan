class_name TrikeRig
extends RefCounted
## Тележка дельталёта на подвеске (TP-К6 v1, docs/contracts/trike-pilot.md): общая часть буксировщика (TowTug) и
## дельталёта игрока (Glider). Вынесена из TowTug без изменения чисел: параметры модели «Маятник» из TT-К1,
## ходы штанги, внешняя сила (тяга винта вдоль оси тележки с наклоном engine.thrust_tilt_deg + сила владельца),
## оси и ориентация тележки (TT-К4 v2), высота колёс над землёй.
##
## ГРАНИЦЫ МОДЕЛИ: тележка - точечная масса; тяга приложена к ЦМ тележки (момента от смещения линии тяги нет);
## винт не обдувает крыло и пилота, реактивного момента и гироскопики нет.
##
## Мир игры: X восток, Y вверх, -Z север. Вход: thrust_n (Н, >= 0), extra_pilot_force / extra_hang_force (Н, мир),
## terrain(x, z) -> высота земли (для нормали на колёсах и agl_m). Чтение после refresh(): hang_pos, wing_basis,
## cart_basis, pilot_pos, agl_m.

## ЦМ тележки в осях trike.glb от HangPoint (Godot: -Z вперёд): 0,13 м вперёд, 1,70 м вниз (docs/research/tow/trike-tug.md).
const CART_CM_MODEL := Vector3(0.0, -1.70, -0.13)
const CART_TURN_DEG_S := 20.0  ## предел скорости смены ориентации модели (колёса <-> воздух), град/с
const WING_DEFAULT := "trike_ixess15"

var thrust_n := 0.0  ## тяга винта, Н (>= 0), ставит владелец каждый шаг
var extra_pilot_force := Vector3.ZERO  ## добавка к силе на тележку (трос буксировщика), Н, мир
var extra_hang_force := Vector3.ZERO  ## добавка к силе на подвеску, Н, мир
var terrain: Callable  ## (x, z) -> высота земли; пусто - 0

var hang_pos := Vector3.ZERO
var wing_basis := Basis.IDENTITY
var cart_basis := Basis.IDENTITY  ## +Y - от ЦМ тележки к подвеске, -Z - продольная ось вперёд
var pilot_pos := Vector3.ZERO
var agl_m := 0.0  ## низ колёс над землёй

var model: PendulumModel
var _cfg: Dictionary = {}


## Параметры PendulumModel.setup: {wing, pilot, apparatus}. cart_mass_kg - масса тележки (с пилотом, топливом) в
## массе «пилота», без ограничения pilot_mass_min/max крыла.
static func model_params(cfg: Dictionary, cart_mass_kg: float) -> Dictionary:
	var cart: Dictionary = cfg.cart
	var wing: Dictionary = Config.get_config("wings/" + String(cfg.get("wing", WING_DEFAULT))).duplicate(true)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = cart_mass_kg
	var app := {
		"hang_length_m": float(cart.cg_below_hang_m),
		"pilot_cda_m2": float(cart.cda_m2),
		"arms_force_max_n": float(cart.arms_force_max_n),
	}
	return {"wing": wing, "pilot": pilot, "apparatus": app}


## Ход штанги в треугольнике тележки (TT-8, trapeze.json): штатные 0,3 / 0,45 м не помещаются.
static func apply_arms(model_: PendulumModel, cfg: Dictionary) -> void:
	var cart: Dictionary = cfg.cart
	model_.arms.shift_x_push = float(cart.arms_shift_push_m)
	model_.arms.shift_x_pull = float(cart.arms_shift_pull_m)
	model_.arms.shift_x_pull_full = float(cart.arms_shift_pull_m)


## model уже настроен (setup с model_params); rig ставит ходы штанги. Внешнюю силу модели вешает владелец
## (model.set_external_force(rig.ext_force)) - после reset_on_wheels, как в TowTug.
func setup(model_: PendulumModel, cfg: Dictionary) -> void:
	model = model_
	_cfg = cfg
	apply_arms(model, cfg)
	thrust_n = 0.0
	extra_pilot_force = Vector3.ZERO
	extra_hang_force = Vector3.ZERO


## Внешняя сила модели (подшаг 480 Гц): тяга на тележку вдоль продольной оси, плюс силы владельца.
func ext_force(s: Dictionary) -> Dictionary:
	var cb := cart_axes(s.pilot_pos, s.hang_pos, s.wing_basis)
	var tilt := deg_to_rad(float(_cfg.engine.thrust_tilt_deg))
	var dir := -cb.z * cos(tilt) + cb.y * sin(tilt)
	return {"pilot": dir * thrust_n + extra_pilot_force, "hang": extra_hang_force}


## После шага модели (и после reset: dt = 0 - без ограничения поворота).
func refresh(dt: float) -> void:
	hang_pos = model.hang_position
	pilot_pos = model.pilot_position
	wing_basis = model.wing_basis()
	var target := _cart_model_basis(pilot_pos, hang_pos, wing_basis, model.on_wheels)
	if dt <= 0.0:
		cart_basis = target
	else:
		cart_basis = _turn_toward(cart_basis, target, deg_to_rad(CART_TURN_DEG_S) * dt)
	agl_m = maxf(pilot_pos.y - float(_cfg.ground.wheel_base_agl_m) - _ground(pilot_pos.x, pilot_pos.z), 0.0)


func _ground(x: float, z: float) -> float:
	return float(terrain.call(x, z)) if terrain.is_valid() else 0.0


## Оси тележки: +Y от ЦМ тележки к подвеске, -Z - курс крыла, ортогонализованный к мачте.
static func cart_axes(pilot_p: Vector3, hang_p: Vector3, wb: Basis) -> Basis:
	var y := (hang_p - pilot_p).normalized()
	var f: Vector3 = -wb.z
	f = (f - y * f.dot(y)).normalized()
	var z := -f
	return Basis(y.cross(z), y, z)


## Ориентация модели trike.glb (TT-К4 v2). На колёсах: +Y по нормали земли, -Z по курсу крыла. В воздухе: вектор
## «подвеска -> ЦМ тележки» в осях trike.glb (CART_CM_MODEL, tools/research/tow-trike/cart.py) совпадает с направлением
## подвеска -> ЦМ тележки в модели полёта (pilot_position), -Z - по курсу.
func _cart_model_basis(pilot_p: Vector3, hang_p: Vector3, wb: Basis, wheels: bool) -> Basis:
	if wheels:
		var d := 2.0
		var gx := _ground(pilot_p.x + d, pilot_p.z) - _ground(pilot_p.x - d, pilot_p.z)
		var gz := _ground(pilot_p.x, pilot_p.z + d) - _ground(pilot_p.x, pilot_p.z - d)
		var n := Vector3(-gx, 2.0 * d, -gz).normalized()
		var f: Vector3 = -wb.z
		f = (f - n * f.dot(n)).normalized()
		var z := -f
		return Basis(n.cross(z), n, z)
	var b0 := cart_axes(pilot_p, hang_p, wb)
	var rm := Basis(Quaternion(CART_CM_MODEL.normalized(), Vector3.DOWN))
	return b0 * rm


## Поворот a к b не быстрее max_rad (ортонормированные базисы).
static func _turn_toward(a: Basis, b: Basis, max_rad: float) -> Basis:
	var qa := a.get_rotation_quaternion()
	var qb := b.get_rotation_quaternion()
	var ang := qa.angle_to(qb)
	if ang <= max_rad:
		return Basis(qb)
	return Basis(qa.slerp(qb, max_rad / ang))
