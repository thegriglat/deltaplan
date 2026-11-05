extends SceneTree
## CVW-3: Environment после apply при amount=1 (настоящий configs/game.json) -> amount1.json.

func _init() -> void:
	var w := CloudWhiteout.new()
	w.setup(JSON.parse_string(FileAccess.get_file_as_string("res://configs/game.json")).cloud_whiteout)
	var env := Environment.new()
	env.fog_enabled = false
	env.fog_sky_affect = 0.1
	w.amount = 1.0
	w.apply(env)
	var d := {"fog_density": env.fog_density, "fog_sky_affect": env.fog_sky_affect, "veil_v": (env.get_meta("whiteout_veil") as Dictionary).v}
	var f := FileAccess.open("res://tools/research/cloud_view/CVW-3/amount1.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	quit()
