extends TestCase
## Контракт SNW-К3 v3 (docs/contracts/snow-plume.md): отрисовка снежных флагов по списку источников.

const RENDER_PATH := "res://scripts/world/snow_plume/snow_plume_render.gd"


func _emitter(id: int, x: float) -> Dictionary:
	var path := PackedVector3Array()
	var vel := PackedVector3Array()
	for i in 6:
		path.append(Vector3(x + 120.0 * i, 3500.0 - 10.0 * i, 0.0))
		vel.append(Vector3(15.0, -1.2, 0.0))
	return {
		"id": id, "pos": Vector3(x, 3498.0, 0.0), "dir": Vector3(1.0, 0.0, 0.0), "u10": 15.0, "u_t": 9.0,
		"intensity": 0.75, "snow": 1.0, "width_m": 40.0, "path": path, "vel": vel, "path_dt": 1.0,
		"surf": PackedVector3Array([Vector3(x, 3498.0, -20.0), Vector3(x, 3498.0, 20.0), Vector3(x - 30.0, 3480.0, 0.0)]),
	}


func test_set_emitters_pool() -> void:
	var script: GDScript = load(RENDER_PATH)
	check(script != null, "нет " + RENDER_PATH)
	if script == null:
		return
	var r: Node3D = script.new({"max_emitters": 4})
	var list: Array = []
	for i in 6:
		list.append(_emitter(100 + i, 200.0 * i))
	r.set_emitters(list)
	check(r.active_count() == 4, "лишние источники отбрасываются (пул max_emitters)")
	r.set_emitters(list.slice(0, 2))
	check(r.active_count() == 2, "два источника — два излучателя")
	r.set_emitters([])
	check(r.active_count() == 0, "пустой список — ничего не видно")
	r.free()
