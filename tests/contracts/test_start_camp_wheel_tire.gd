extends TestCase
## SC-10: шина колёс — один общий ресурс на все колёсные крылья и полусобранный аппарат
## (одинаковый resource_path, VRAM-сжатие, мипмапы).

const TIRE := "res://assets/textures/wheel/tire.png"
const KIT := "res://assets/models/world/glider_kit.glb"


func _tire_paths(res: String) -> Array:
	var out: Array = []
	var node: Node = (load(res) as PackedScene).instantiate()
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (m as MeshInstance3D).mesh
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i) as BaseMaterial3D
			if mat and mat.albedo_texture and "tire" in mat.albedo_texture.resource_path:
				out.append(mat.albedo_texture.resource_path)
	node.free()
	return out


func test_all_wheeled_models_share_one_tire_texture() -> void:
	var models: Array = [KIT]
	var d := DirAccess.open("res://assets/models")
	for f in d.get_files():
		if f.begins_with("glider_") and f.ends_with(".glb"):
			models.append("res://assets/models/" + f)
	var wheeled := 0
	for res in models:
		var paths := _tire_paths(res)
		if paths.is_empty():
			continue
		wheeled += 1
		for p in paths:
			check(p == TIRE, "%s: шина должна быть общим ресурсом, а не %s" % [res, p])
	check(wheeled >= 12, "колёсных моделей %d, ждём 11 крыльев + аппарат" % wheeled)


func test_tire_file_is_single_vram_with_mipmaps() -> void:
	var png: Array = []
	var stack: Array = ["res://assets"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			stack.append(dir + "/" + sub)
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".png") and "tire" in f:
				png.append(dir + "/" + f)
	check(png == [TIRE], "файл шины один, найдено %s" % [png])
	var cfg := ConfigFile.new()
	check(cfg.load(TIRE + ".import") == OK, "есть .import шины")
	check(cfg.get_value("params", "compress/mode") == 2, "VRAM-сжатие")
	check(cfg.get_value("params", "mipmaps/generate") == true, "мипмапы")
