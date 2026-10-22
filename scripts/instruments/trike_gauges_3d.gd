class_name TrikeGauges3D
extends Node3D
## Приборы дельталёта на панели тележки (TP-К4): тахометр слева, указатель топлива справа, лицом +Z корня.
## Циферблаты — GaugeDial в SubViewport (текстура на квадах), стрелки RpmNeedle/FuelNeedle — узлы,
## поворот вокруг Z (= GaugeDial.needle_angle_deg). TP-8 ставит корень в маркер InstrumentPanel.

var _sc: Dictionary = {}

var rpm_needle: Node3D
var fuel_needle: Node3D


## Угол стрелки (градусы вокруг Z); см. GaugeDial.needle_angle_deg.
static func needle_angle_deg(val: float, vmin: float, vmax: float, amin: float, amax: float) -> float:
	return GaugeDial.needle_angle_deg(val, vmin, vmax, amin, amax)


func _ready() -> void:
	setup()


## Собрать циферблаты и материалы (один раз; вызывается из _ready, работает и вне дерева).
func setup() -> void:
	if not _sc.is_empty():
		return
	rpm_needle = $RpmNeedle
	fuel_needle = $FuelNeedle
	_sc = GaugeDial.scales()
	var p: Dictionary = _sc["panel_3d"]
	var d := float(p.get("dial_diameter_m", 0.11))
	var x := float(p.get("dial_spacing_m", 0.14)) * 0.5
	var px := int(p.get("texture_px", 256))
	_build_face($RpmFace as MeshInstance3D, true, px, d, -x)
	_build_face($FuelFace as MeshInstance3D, false, px, d, x)
	rpm_needle.position.x = -x
	fuel_needle.position.x = x
	var nm := StandardMaterial3D.new()
	nm.albedo_color = Color(String((_sc["face"] as Dictionary).get("needle_color", "#ffb020")))
	for n: Node3D in [rpm_needle, fuel_needle]:
		(n.get_child(0) as MeshInstance3D).material_override = nm
	update_readout(0.0, float(_sc["tank_l"]), float(_sc["tank_l"]), false)


func _build_face(mi: MeshInstance3D, is_rpm: bool, px: int, d: float, x: float) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(px, px)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var dial := GaugeDial.new()
	dial.show_needle = false
	dial.size = Vector2(px, px)
	if is_rpm:
		dial.setup_rpm(_sc)
	else:
		dial.setup_fuel(_sc)
	vp.add_child(dial)
	add_child(vp)
	var q := QuadMesh.new()
	q.size = Vector2(d, d)
	mi.mesh = q
	mi.position = Vector3(x, 0.0, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_texture = vp.get_texture()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.roughness = 0.6
	mi.material_override = m


## Общий вход приборов (TP-К4). Тахометр показывает фактические обороты (running только для информации:
## у заглушённого двигателя engine_rpm = 0 и стрелка в нуле).
func update_readout(engine_rpm: float, fuel_l: float, tank_l: float, _running: bool) -> void:
	setup()
	var r: Dictionary = _sc["rpm"]
	var f: Dictionary = _sc["fuel"]
	rpm_needle.rotation_degrees.z = GaugeDial.needle_angle_deg(
		engine_rpm, 0.0, float(r.get("max_rpm", 8000)),
		float(r.get("angle_min_deg", 135.0)), float(r.get("angle_max_deg", -135.0)))
	fuel_needle.rotation_degrees.z = GaugeDial.needle_angle_deg(
		fuel_l, 0.0, tank_l, float(f.get("angle_min_deg", 60.0)), float(f.get("angle_max_deg", -60.0)))
