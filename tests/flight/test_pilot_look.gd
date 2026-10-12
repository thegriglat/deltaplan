extends TestCase
## PilotLook: целевые поверхности получили шейдер, Glove/GlovePanel/Skin не тронуты, enabled:false — как в glb.


func _load() -> Node:
	var ps := load("res://assets/models/pilot.glb") as PackedScene
	return ps.instantiate()


func _mats(n: Node) -> Dictionary:
	var out := {}
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			out[m.resource_name] = m
	return out


func test_pilot_look() -> void:
	var cfg: Dictionary = Config.get_config("flight").visual.pilot_look
	var off := cfg.duplicate(true)
	off["enabled"] = false
	var n := _load()
	check(PilotLook.apply(n, off) == 0, "enabled=false ничего не меняет")
	for k in _mats(n):
		check(_mats(n)[k] is BaseMaterial3D, "%s остался как в glb" % k)
	var cnt := PilotLook.apply(n, cfg)
	check(cnt >= 9, "заменено поверхностей: %d" % cnt)
	var m := _mats(n)
	for k: String in PilotLook.KINDS:
		check(m[k] is ShaderMaterial, "%s получил шейдер" % k)
		check((m[k] as ShaderMaterial).shader.code.length() > 100, "%s: код шейдера" % k)
	for k: String in ["Glove", "GlovePanel", "Skin"]:
		check(m[k] is BaseMaterial3D, "%s не тронут" % k)
	check(PilotLook.apply(n, cfg) == 0, "повторно не заменяет")
	n.free()
