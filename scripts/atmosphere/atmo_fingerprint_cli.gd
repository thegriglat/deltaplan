extends Node
## Отпечаток эталонного мира в файл — сравнить Linux и Windows (NET-00, AtmoFingerprint).
## Из исходников:  godot --headless --path . res://scenes/atmosphere/atmo_fingerprint.tscn
##                     -- --out=<файл> [--key=<ключ мира>] [--times=0,600,3600] [--dt=0.5]
## Из сборки:      deltaplan.exe --headless res://scenes/atmosphere/atmo_fingerprint.tscn -- --out=…
## Для каждого момента — прыжок (start_at) и прогон от 0 шагом dt; в файл — оба отпечатка и
## строка «match»/«MISMATCH» (совпадают ли они между собой до 1e-3). Файлы двух ОС — сравнить diff.

var _out := "user://atmo_fingerprint.txt"
var _key := AtmoFingerprint.DEFAULT_KEY
var _times: PackedFloat64Array = [0.0, 600.0, 3600.0]
var _dt := 0.5


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() < 2:
			continue
		match kv[0]:
			"out":
				_out = kv[1]
			"key":
				_key = kv[1]
			"dt":
				_dt = float(kv[1])
			"times":
				_times.clear()
				for s in kv[1].split(","):
					_times.append(float(s))
	var text := "deltaplan atmo fingerprint os=%s\n%s\n" % [OS.get_name(), _key]
	var ok := true
	var run := AtmoFingerprint.make_world(_key)
	for t in _times:
		var jump := AtmoFingerprint.make_world(_key)
		jump.start_at(t)
		var fj := AtmoFingerprint.capture(jump)
		jump.free()
		AtmoFingerprint.run_to(run, t, _dt)
		var fr := AtmoFingerprint.capture(run)
		var d := AtmoFingerprint.diff(fj, fr)
		ok = ok and d == ""
		text += "== jump %.0f\n%s== run %.0f\n%s== %s\n" % [
			t, AtmoFingerprint.to_text(fj), t, AtmoFingerprint.to_text(fr),
			"match" if d == "" else "MISMATCH\n" + d
		]
	run.free()
	var f := FileAccess.open(_out, FileAccess.WRITE)
	if f == null:
		printerr("atmo_fingerprint: не открыть %s" % _out)
		get_tree().quit(2)
		return
	f.store_string(text)
	f.close()
	var verdict := "match" if ok else "MISMATCH"
	print("atmo_fingerprint: %s → %s" % [verdict, ProjectSettings.globalize_path(_out)])
	get_tree().quit(0 if ok else 1)
