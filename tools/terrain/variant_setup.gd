extends Node
## Разовая правка user://configs для замера вариантов шейдера рельефа (SL-К6, tools/terrain/variant_bench.sh):
## пресет графики (GraphicsPresets.select — world-конфиги пресета) и вариант рельефа
## (world.terrain.variant / variant_far). Headless, сам выходит.
##   godot --headless --path . res://tools/terrain/variant_setup.tscn -- --preset=low --variant=_bench/no_sl_light
## --variant-far="" — без дальнего варианта (по умолчанию не трогается).


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var ok := true
	if args.has("preset"):
		ok = GraphicsPresets.select(String(args.preset)) and ok
	var patch := {}
	if args.has("variant"):
		patch["variant"] = String(args.variant)
	if args.has("variant-far"):
		patch["variant_far"] = String(args["variant-far"])
	if not patch.is_empty():
		ok = UserSettings.save_patch("world", {"terrain": patch}) and ok
		Config.reload()
	var t: Dictionary = Config.get_config("world").get("terrain", {})
	print(
		"variant_setup: preset=%s variant=%s variant_far=%s -> %s"
		% [GraphicsPresets.current(), t.get("variant", ""), t.get("variant_far", ""), "ok" if ok else "ОШИБКА"]
	)
	get_tree().quit(0 if ok else 1)
