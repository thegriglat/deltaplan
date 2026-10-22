class_name TowTrikeVisual
extends Node3D
## Вид буксировщика-дельталёта (TT-К5): trike.glb (начало = HangPoint → tug.hang_pos, поворот tug.cart_basis), крыло
## glider_trike_ixess15.glb точкой HangPoint в точке подвески с tug.wing_basis (как GliderVisual ставит крыло игрока),
## pilot.glb в начале тележки, анимация sit (TK-К3). AnimationPlayer тележки: prop_spin всегда,
## speed_scale = prop_rpm · prop_spin_period_s / 60 (TK-К1). Звук — TowTrikeSound на тележке у двигателя.
## Модель границ: скорость анимации винта при высоких оборотах (до 33 об/с) на кадре 60 Гц стробоскопична.

const CART := "res://assets/models/trike/trike.glb"
const WING := "res://assets/models/glider_trike_ixess15.glb"
const PILOT := "res://assets/models/pilot.glb"
const PROP_SPIN_PERIOD_S := 1.0  ## длина клипа prop_spin (trike_params.json dims.prop_spin_period_s)

var cart: Node3D
var wing: Node3D
var pilot: Node3D
var prop_anim: AnimationPlayer
var sound: TowTrikeSound
var _wing_hang := Vector3.ZERO  ## HangPoint крыла в осях корня модели крыла


func setup(engine_cfg: Dictionary, with_sound := true) -> void:
	# TP-16: металл труб/тросов/фитингов — те же процедурные шейдеры, что у крыльев игры (flight.json → visual.metal)
	var metal_cfg: Dictionary = Config.value("flight", "visual.metal", {})
	cart = _load(CART)
	if cart != null:
		cart.name = "Cart"
		add_child(cart)
		FrameMetal.apply(cart, metal_cfg)
		for ap: AnimationPlayer in cart.find_children("*", "AnimationPlayer", true, false):
			if ap.has_animation("prop_spin"):
				prop_anim = ap
		if prop_anim != null:
			var a := prop_anim.get_animation("prop_spin")
			if a != null:
				a.loop_mode = Animation.LOOP_LINEAR
			prop_anim.play("prop_spin")
		pilot = _load(PILOT)
		if pilot != null:
			pilot.name = "Pilot"
			cart.add_child(pilot)
			for ap: AnimationPlayer in pilot.find_children("*", "AnimationPlayer", true, false):
				if ap.has_animation("sit"):
					ap.play("sit")
		if with_sound:
			sound = TowTrikeSound.new()
			sound.name = "EngineSound"
			cart.add_child(sound)
			var prop := cart.find_child("Propeller", true, false) as Node3D
			sound.position = prop.position if prop != null else Vector3(0.0, -1.2, 1.2)
			sound.setup(engine_cfg)
	wing = _load(WING)
	if wing != null:
		wing.name = "Wing"
		add_child(wing)
		FrameMetal.apply(wing, metal_cfg)
		var hp := wing.find_child("HangPoint", true, false) as Node3D
		if hp != null:
			_wing_hang = _relative(wing, hp)


## Ставит узлы по состоянию буксировщика: tug — TowTug (hang_pos, cart_basis, wing_basis, prop_rpm, throttle).
func update(tug: TowTug) -> void:
	if cart != null:
		cart.transform = Transform3D(tug.cart_basis, tug.hang_pos)
	if wing != null:
		wing.transform = Transform3D(tug.wing_basis, tug.hang_pos - tug.wing_basis * _wing_hang)
	if prop_anim != null:
		prop_anim.speed_scale = tug.prop_rpm * PROP_SPIN_PERIOD_S / 60.0
	if sound != null:
		sound.update(tug.prop_rpm, tug.throttle)


func stop_sound() -> void:
	if sound != null:
		sound.stop()


func play_sound() -> void:
	if sound != null and sound.is_inside_tree():
		sound.play()


static func _load(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("TowTrikeVisual: нет модели " + path)
		return null
	var ps := load(path) as PackedScene
	return ps.instantiate() as Node3D if ps != null else null


static func _relative(root: Node, node: Node3D) -> Vector3:
	var x := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x.origin
