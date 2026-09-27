extends Node
## Серия кадров: облако уходит из отрисовки и тает, а не пропадает за кадр.
## Стенд — atmosphere_preview.tscn (плоская земля); облако ближе к центру кадра «убирается»:
## термик удаляется из поля (как при выходе за радиус вокруг пилота), и больше не родится.
## Атмосфера шагает на --step_s за кадр серии.
## Запуск:
##   godot --path . res://tools/shots/cloud_fade_shot.tscn -- --out=/tmp/cf \
##     [--view=side] [--weather=medium] [--step_s=4] [--count=20]
## Пишет <out>/fade_NN.png и печатает видимость облака на каждом кадре. Код выхода 0/1.

const PREVIEW := preload("res://scenes/atmosphere/atmosphere_preview.tscn")

var _args: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not _args.has("view"):
		push_error("cloud_fade_shot: задай --view=side (превью читает те же аргументы)")
	if String(_args.get("out", "")) == "":
		push_error("cloud_fade_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(String(_args.out))
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 720)
	_run()


func _run() -> void:
	var out := String(_args.out)
	var step_s := float(_args.get("step_s", "4"))
	var count := int(_args.get("count", "20"))
	var preview: Node = PREVIEW.instantiate()
	add_child(preview)
	var atmo: Atmosphere = preview.get_node("Atmosphere")
	atmo.set_physics_process(false)
	var layer := atmo.get_node_or_null("Clouds") as CloudLayer
	if layer == null:
		push_error("cloud_fade_shot: нет облаков")
		get_tree().quit(1)
		return
	for i in 600:
		if layer.textures_ready():
			break
		await get_tree().process_frame
	await _frames(10)
	var th := _cloud_in_view(layer)
	if th == null:
		push_error("cloud_fade_shot: нет облака в кадре")
		get_tree().quit(1)
		return
	await _frames(40)
	_save(out, 0, layer, th)
	# Убрать термик из поля навсегда: облако выбывает из выбора и должно растаять. Соседей
	# (с которыми оно слито в одно) — тоже, иначе они проявляются на его месте (перетекание).
	var c0 := layer.model.center(th, atmo.time_s)
	for id in atmo.field.thermals.keys():
		var o: AtmoThermal = atmo.field.thermals[id]
		if id == th.id or layer.model.center(o, atmo.time_s).distance_to(c0) < 3000.0:
			atmo.field.thermals.erase(id)
			atmo.field._empty_cycles[id] = 1.0e18
	for k in range(1, count + 1):
		atmo.step(step_s)
		layer._acc = 1.0e9
		await _frames(8)
		_save(out, k, layer, th)
	get_tree().quit(0)


## Облако ближе всех к центру кадра (из нарисованных полностью, до 12 км от камеры).
func _cloud_in_view(layer: CloudLayer) -> AtmoThermal:
	var cam := get_viewport().get_camera_3d()
	var mid := get_viewport().get_visible_rect().size * 0.5
	var best: AtmoThermal = null
	var best_d := 1.0e9
	for i in layer._slot_th.size():
		var o: AtmoThermal = layer._slot_th[i]
		if o == null or layer._rec[i].is_empty() or layer._rec[i][20] < 0.999:
			continue
		var p := Vector3(
			layer._rec[i][0], layer._rec[i][8] + layer._rec[i][9] * 0.5, layer._rec[i][2]
		)
		if cam.is_position_behind(p) or cam.global_position.distance_to(p) > 12000.0:
			continue
		var d := cam.unproject_position(p).distance_to(mid)
		if d < best_d:
			best_d = d
			best = o
	return best


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


func _save(out: String, k: int, layer: CloudLayer, th: AtmoThermal) -> void:
	var slot: int = layer._slot_of.get(th.id, -1)
	var vis := float(layer._rec[slot][20]) if slot >= 0 else 0.0
	var path := out.path_join("fade_%02d.png" % k)
	get_viewport().get_texture().get_image().save_png(path)
	print("кадр %02d  t=%.0f с  видимость облака %.2f  %s" % [k, layer.atmo.time_s, vis, path])
