extends SceneTree
# Выгрузка API расширения (методы, сигналы, константы) без инициализации Steam.
# Использование: godot --headless -s dump_api.gd -- out=/путь/api.json
func _init() -> void:
	var out := "user://api.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			out = a.substr(4)
	if not Engine.has_singleton("Steam"):
		print("DUMP_API loaded=false")
		quit(1)
		return
	var s: Object = Engine.get_singleton("Steam")
	var methods := {}
	for m in s.get_method_list():
		var args := []
		for p in m.args:
			args.append("%s:%d" % [p.name, p.type])
		methods[m.name] = {"args": args, "default_args": m.default_args.size()}
	var signals := {}
	for sg in s.get_signal_list():
		var args2 := []
		for p in sg.args:
			args2.append("%s:%d" % [p.name, p.type])
		signals[sg.name] = args2
	var consts := {}
	for c in ClassDB.class_get_integer_constant_list("Steam", true):
		consts[c] = ClassDB.class_get_integer_constant("Steam", c)
	var d := {"class": s.get_class(), "version": s.call("get_godotsteam_version"), "methods": methods, "signals": signals, "constants": consts}
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", true))
	f.close()
	print("DUMP_API loaded=true class=%s methods=%d signals=%d constants=%d out=%s" % [s.get_class(), methods.size(), signals.size(), consts.size(), out])
	quit(0)
