extends Node3D
## Модели OSM (OL-2, L5): опора ЛЭП, столб, мачта, телебашня, труба — крупно и издали (мипы решётки).
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1280x960 \
##   res://tools/shots/osm_models_shot.tscn -- --out=<каталог> [--only=power_tower]

const MODELS := {
	"power_tower": {"label": "опора_лэп", "h": 28.0},
	"power_pole": {"label": "столб", "h": 9.15},
	"mast_lattice": {"label": "решётчатая_мачта", "h": 60.0},
	"tv_tower": {"label": "телебашня", "h": 200.0},
	"chimney": {"label": "труба", "h": 100.0},
}


func _ready() -> void:
	var out := "/tmp"
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--only="):
			only = a.substr(7)
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.75, 0.92)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.58, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(6000, 6000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.5, 0.3)
	pm.material = gm
	ground.mesh = pm
	add_child(ground)
	var cam := Camera3D.new()
	cam.far = 8000.0
	cam.fov = 45.0
	add_child(cam)
	cam.current = true
	var i := 0
	for name: String in MODELS:
		if only != "" and only != name:
			continue
		i += 1
		var h: float = MODELS[name].h
		var node := (load("res://assets/models/osm/%s.glb" % name) as PackedScene).instantiate()
		add_child(node)
		# крупно: сбоку-сверху на 2/3 высоты; вблизи основания; издали
		var views := {
			"крупно": [Vector3(h * 0.9, h * 0.55, h * 1.25), Vector3(0, h * 0.5, 0)],
			"вблизи": [Vector3(h * 0.35, h * 0.2, h * 0.5), Vector3(0, h * 0.25, 0)],
			"издали": [Vector3(1500, 120, 1500) if h >= 50.0 else Vector3(300, 30, 300), Vector3(0, h * 0.5, 0)],
		}
		for v: String in views:
			cam.position = views[v][0]
			cam.look_at(views[v][1], Vector3.UP)
			for k in 4:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var path := "%s/%s_%s.png" % [out, MODELS[name].label, v]
			get_viewport().get_texture().get_image().save_png(path)
			print("osm_models_shot: ", path)
		node.free()
	get_tree().quit(0)
