extends Node
## Запуск: godot --headless --path . res://tests/run_tests.tscn [-- --filter=подстрока]
## Ищет tests/**/test_*.gd, вызывает методы test_*. Код выхода 1, если есть падения.

func _ready() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr(9)
	var files: PackedStringArray = []
	_find("res://tests", files)
	var total := 0
	var failed := 0
	for f in files:
		if filter != "" and not f.contains(filter):
			continue
		var script: Script = load(f)
		for m in script.get_script_method_list():
			if not String(m.name).begins_with("test_"):
				continue
			var inst: Object = script.new()
			if inst is Node:
				add_child(inst)
			total += 1
			var ret: Variant = inst.call(m.name)
			if ret is Object and ret.get_class() == "GDScriptFunctionState":
				await ret.completed
			if inst.failures.is_empty():
				print("  ok   %s::%s" % [f.get_file(), m.name])
			else:
				failed += 1
				print("  FAIL %s::%s" % [f.get_file(), m.name])
				for msg in inst.failures:
					print("         " + msg)
			if inst is Node:
				inst.queue_free()
	print("\n%d тестов, %d упало" % [total, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _find(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_find(dir.path_join(sub), out)
	for f in d.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir.path_join(f))
