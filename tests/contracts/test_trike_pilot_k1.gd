extends TestCase
## Контракт TP-К1 v1 (docs/contracts/trike-pilot.md): configs/trike_pilot.json.

const CFG := "res://configs/trike_pilot.json"
const PARAMS := "res://tools/blender/trike_params.json"
const KEYS := {
	"fuel": ["tank_l", "start_l", "density_kg_l"],
	"starter": ["start_s", "stop_s"],
	"throttle": ["rate_per_s"],
	"tachometer": ["max_rpm", "red_rpm"],
}


func _json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	var v: Variant = JSON.parse_string(text)
	return v if v is Dictionary else {}


func test_keys_and_docs() -> void:
	var c := _json(CFG)
	check(not c.is_empty(), "конфиг читается")
	check(c.get("contract", "") == "TP-К1 v1", "contract = TP-К1 v1")
	check(str(c.get("_doc", "")).length() > 0, "_doc")
	for sec: String in KEYS:
		var d: Variant = c.get(sec, null)
		check(d is Dictionary, "секция %s" % sec)
		if not d is Dictionary:
			continue
		for k: String in KEYS[sec]:
			check(d.has(k) and (d[k] is float or d[k] is int), "%s.%s — число" % [sec, k])
			check(str(d.get(k + "_doc", "")).length() > 0, "%s.%s_doc" % [sec, k])
	var burn: Dictionary = c.get("fuel", {}).get("burn", {})
	for k in ["rpm_engine", "lph"]:
		check(burn.get(k) is Array and not (burn[k] as Array).is_empty(), "burn.%s — массив" % k)
		check(str(burn.get(k + "_doc", "")).length() > 0, "burn.%s_doc" % k)
	var g: Variant = c.get("tachometer", {}).get("green_rpm")
	check(g is Array and (g as Array).size() == 2, "green_rpm — [от, до]")
	check(str(c.get("tachometer", {}).get("green_rpm_doc", "")).length() > 0, "green_rpm_doc")


func test_invariants() -> void:
	var c := _json(CFG)
	var f: Dictionary = c.get("fuel", {})
	var burn: Dictionary = f.get("burn", {})
	var r: Array = burn.get("rpm_engine", [])
	var l: Array = burn.get("lph", [])
	check(r.size() == l.size() and r.size() >= 2, "burn одной длины: %d/%d" % [r.size(), l.size()])
	var ok := true
	for i in range(1, mini(r.size(), l.size())):
		ok = ok and float(r[i]) > float(r[i - 1]) and float(l[i]) >= float(l[i - 1])
	check(ok, "rpm_engine возрастает, lph не убывает")
	if not r.is_empty():
		check(float(r[0]) <= 2000.0 and float(r[-1]) >= 6800.0, "rpm_engine покрывает 2000..6800")
	check(not l.is_empty() and float(l[0]) >= 0.0, "lph ≥ 0")
	var tank := float(f.get("tank_l", 0))
	var start := float(f.get("start_l", 0))
	check(start > 0.0 and start <= tank, "start_l ∈ (0; tank_l]: %s/%s" % [start, tank])
	var p := _json(PARAMS)
	var pt := float(p.get("dims", {}).get("tank_volume_l", {}).get("value", -100))
	check(absf(tank - pt) <= 0.5, "tank_l = trike_params ± 0,5: %s/%s" % [tank, pt])
	var t: Dictionary = c.get("tachometer", {})
	check(float(t.get("red_rpm", 1e9)) < float(t.get("max_rpm", 0)), "red_rpm < max_rpm")
	check(float(c.get("throttle", {}).get("rate_per_s", 0)) > 0.0, "rate_per_s > 0")
