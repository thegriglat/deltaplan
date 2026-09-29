class_name EggProbe
extends EasterEgg
## Проба каркаса пасхалок (тесты и кадры): шарик летит по прямой lifetime_s. В игре выключена
## (configs/easter_eggs.json → eggs.probe.enabled = false); форсится по имени: --egg=probe.
## Точка появления привязана к игроку в момент begin (проба — не образец для «мировых» пасхалок).

var _p0 := Vector3.ZERO
var _vel := Vector3.ZERO


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	var a := rng.randf() * TAU
	var dist := float(cfg.get("distance_m", 90.0))
	var speed := float(cfg.get("speed_ms", 6.0))
	var up := float(cfg.get("height_m", 25.0))
	_p0 = ctx.pilot_pos + Vector3(cos(a) * dist, up, sin(a) * dist)
	var b := rng.randf() * TAU
	_vel = Vector3(cos(b), 0.0, sin(b)) * speed
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	var r := float(cfg.get("size_m", 3.0)) * 0.5
	mesh.radius = r
	mesh.height = r * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.35, 0.05)
	mesh.material = mat
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	if lifetime_s > 0.0 and age > lifetime_s:
		return false
	position = _p0 + _vel * age
	return true
