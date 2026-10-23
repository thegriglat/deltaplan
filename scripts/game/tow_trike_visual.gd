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
var player_sound := false  ## звук - игрока (update_engine зовёт владелец), а не буксировщика
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
	update_parts(tug.hang_pos, tug.cart_basis, tug.wing_basis, tug.prop_rpm, tug.throttle)


## TP-К8: то же по отдельным величинам (дельталёт игрока: TrikeRig + TrikeEngine). Координаты - в системе этого узла.
## Звук буксировщика (sound) идёт от throttle; звук игрока (player_sound) обновляет владелец по состоянию двигателя.
func update_parts(hang_pos: Vector3, cart_basis: Basis, wing_basis: Basis, prop_rpm: float, throttle: float) -> void:
	if cart != null:
		cart.transform = Transform3D(cart_basis, hang_pos)
	if wing != null:
		wing.transform = Transform3D(wing_basis, hang_pos - wing_basis * _wing_hang)
	if prop_anim != null:
		prop_anim.speed_scale = prop_rpm * PROP_SPIN_PERIOD_S / 60.0
	if sound != null and not player_sound:
		sound.update(prop_rpm, throttle)


## TP-К9: звук двигателя игрока (TowTrikeSound.setup_player) у винта; ставится после setup(engine_cfg, false).
func setup_player_sound(engine_cfg: Dictionary, sound_cfg: Dictionary) -> void:
	if cart == null:
		return
	sound = TowTrikeSound.new()
	sound.name = "EngineSound"
	cart.add_child(sound)
	var prop := cart.find_child("Propeller", true, false) as Node3D
	sound.position = prop.position if prop != null else Vector3(0.0, -1.2, 1.2)
	sound.setup_player(engine_cfg, sound_cfg)
	player_sound = true


## Маркеры вида: "PilotHead" - нода Head сидящего пилота (pilot.glb), "InstrumentPanel" - маркер trike.glb;
## остальные (маркеры крыла дельтаплана) - null.
func get_marker(marker_name: String) -> Node3D:
	match marker_name:
		"PilotHead":
			return pilot.find_child("Head", true, false) as Node3D if pilot != null else null
		"InstrumentPanel":
			return cart.find_child("InstrumentPanel", true, false) as Node3D if cart != null else null
	return null


## Тело пилота - на слой layer_bit (камера кабины его не рисует, внешние - рисуют).
func set_pilot_layers(layer_bit: int) -> void:
	if pilot == null:
		return
	for n in pilot.find_children("*", "VisualInstance3D", true, false):
		(n as VisualInstance3D).layers = layer_bit


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
