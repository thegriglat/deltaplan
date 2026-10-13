extends Node
## GPU-сверка SL-К4 (tools/gpu_tests.sh --filter=lod_k): sl_lod_hash/sl_lod_swap_t из scene_look.gdshaderinc
## против CPU-зеркала TreePlacer.lod_k_at / swap_t.

var failures: PackedStringArray = []

const PROBE := """
shader_type spatial;
render_mode unshaded, cull_disabled;
#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc"
uniform vec4 args = vec4(0.0);
uniform bool second = false;
void fragment() {
	// r — хеш (sl_lod_k без масштаба), g — доля импостера при db = 500, dither = 40
	float h = (sl_lod_k(args.xy) - sl_lod_k_range.x) / (sl_lod_k_range.y - sl_lod_k_range.x);
	float t = sl_lod_swap_t(args.z, 500.0 * sl_lod_k(args.xy), 40.0);
	ALBEDO = second ? vec3(t) : vec3(h);
}
"""


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_lod_k_mirror() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(400, 200)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 40.0
	vp.add_child(cam)
	var sh := Shader.new()
	sh.code = PROBE
	var cases: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	for i in 20:
		cases.append(Vector3(rng.randf_range(-20000.0, 20000.0), rng.randf_range(-20000.0, 20000.0), rng.randf_range(250.0, 900.0)))
	for i in cases.size():
		for s in 2:
			var mi := MeshInstance3D.new()
			var q := QuadMesh.new()
			q.size = Vector2(0.25, 0.12)
			mi.mesh = q
			var m := ShaderMaterial.new()
			m.shader = sh
			m.set_shader_parameter("args", Vector4(cases[i].x, cases[i].y, cases[i].z, 0.0))
			m.set_shader_parameter("second", s == 1)
			m.set_shader_parameter("sl_lod_k_range", Vector2(0.6, 1.6))
			mi.material_override = m
			mi.position = Vector3(-0.9 + 0.3 * (i % 5) + 0.0, 0.6 - 0.35 * (i / 5) - 0.16 * s, -3.0)
			vp.add_child(mi)
	for i in 12:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	var bad := 0
	for i in cases.size():
		var c := cases[i]
		var k := TreePlacer.lod_k_at(c.x, c.y, 0.6, 1.6)
		var t := TreePlacer.swap_t(c.z, 500.0 * k, 40.0)
		for s in 2:
			var pos := cam.unproject_position(Vector3(-0.9 + 0.3 * (i % 5), 0.6 - 0.35 * (i / 5) - 0.16 * s, -3.0))
			var px := img.get_pixelv(Vector2i(pos)).srgb_to_linear()
			var want := (k - 0.6) / 1.0 if s == 0 else t
			if absf(px.r - want) > 0.02:
				bad += 1
				check(false, "case %d %s: gpu %.3f cpu %.3f" % [i, "k" if s == 0 else "t", px.r, want])
	print("SL-17 GPU: хеш и доля смены, расхождений %d из %d" % [bad, cases.size() * 2])
