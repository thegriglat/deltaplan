extends Node
## Запуск: godot --headless --path . res://tests/run_tests.tscn [-- --filter=подстрока] [--gpu]
## Ищет tests/**/test_*.gd, вызывает методы test_*. Код выхода 1, если есть падения.
## --gpu — не пропускать тесты, которым нужен настоящий RenderingDevice (TestCase.needs_gpu() ==
## true): под headless RD недоступен, поэтому по умолчанию (tools/check.sh) такие тесты
## пропускаются, не падают; запускать их — tools/gpu_tests.sh (окно, не headless, флаг --gpu).

func _ready() -> void:
	var filter := ""
	var gpu := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr(9)
		elif a == "--gpu":
			gpu = true
	var files: PackedStringArray = []
	_find("res://tests", files)
	var total := 0
	var failed := 0
	var skipped := 0
	for f in files:
		if filter != "" and not f.contains(filter):
			continue
		var script: Script = load(f)
		if script == null or not script.can_instantiate():
			total += 1
			failed += 1
			print("  FAIL %s::не загрузился" % f.get_file())
			continue
		for m in script.get_script_method_list():
			if not String(m.name).begins_with("test_"):
				continue
			var inst: Object = script.new()
			if inst.has_method("needs_gpu") and inst.needs_gpu() and not gpu:
				skipped += 1
				print("  skip %s::%s (нужен GPU — tools/gpu_tests.sh)" % [f.get_file(), m.name])
				continue
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
	print("\n%d тестов, %d упало, %d пропущено" % [total, failed, skipped])
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
