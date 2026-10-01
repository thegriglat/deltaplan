extends TestCase
## Контрактные тесты модуля air-speed (docs/air_speed_contracts.md): S1 — сигнатуры подготовки входа
## решателя не меняются; S2 — блокирующая загрузка (AirRuntime.LOAD_BLOCK_MS, AirClipmap.run_blocking).
## Без GPU. S2 падает до SP-2 намеренно (контракт записан до исполнителя).

## Версии разделов — те же, что в заголовках docs/air_speed_contracts.md.
const CONTRACTS := {S1 = 1, S2 = 1}
const DOC := "res://docs/air_speed_contracts.md"
## S1: функция → (имена аргументов) как в коде a554502 (C2 v5, C7 v2).
const S1_SIGNATURES := {
	"AirPlace": {
		"domain_case":
		["detail", "water", "loc", "dx", "hour", "u10", "wdir", "t_max", "sky", "heat"],
		"block_mean": ["layer", "x0", "y0", "dx", "nx", "ny"],
		"water_fraction": ["img", "layer", "x0", "y0", "dx", "nx", "ny"],
		"solar_flux": ["hc", "dx", "nx", "ny", "d", "ctx", "cfg", "water"],
	},
	"AirCase": {"prepare": [], "without_heat": [], "gauss2d": ["a", "w", "h", "sigma"]},
	"AirWindowCase": {"prepare_pair": []},
}


static func _script_of(cls: String) -> Script:
	for g: Dictionary in ProjectSettings.get_global_class_list():
		if String(g["class"]) == cls:
			return load(String(g["path"]))
	return null


func test_contract_versions() -> void:
	var txt := FileAccess.get_file_as_string(DOC)
	for k: String in CONTRACTS:
		var head := "## %s v%d —" % [k, CONTRACTS[k]]
		check(txt.contains(head), "заголовок «%s» в %s" % [head, DOC])


func test_s1_prep_signatures() -> void:
	for cls: String in S1_SIGNATURES:
		var sc := _script_of(cls)
		check(sc != null, "класс " + cls)
		if sc == null:
			continue
		var methods := {}
		for m: Dictionary in sc.get_script_method_list():
			methods[String(m.name)] = m
		var want: Dictionary = S1_SIGNATURES[cls]
		for fn: String in want:
			check(methods.has(fn), "%s.%s есть" % [cls, fn])
			if not methods.has(fn):
				continue
			var names: Array = (methods[fn].args as Array).map(
				func(a: Dictionary) -> String: return String(a.name)
			)
			check(
				names == want[fn],
				"S1: %s.%s(%s), ожидалось (%s)" % [cls, fn, ", ".join(names), ", ".join(want[fn])]
			)


func test_s2_blocking_api() -> void:
	var rt := AirRuntime.new()
	var consts: Dictionary = (rt.get_script() as Script).get_script_constant_map()
	check(consts.has("LOAD_BLOCK_MS"), "S2: AirRuntime.LOAD_BLOCK_MS")
	if consts.has("LOAD_BLOCK_MS"):
		check(float(consts.LOAD_BLOCK_MS) > 0.0, "S2: LOAD_BLOCK_MS > 0 (INF — один проход)")
	for m in ["load_field", "busy", "stop"]:
		check(rt.has_method(m), "C9: метод " + m)
	rt.free()
	var cm := AirClipmap.new()
	check(cm.has_method("run_blocking"), "S2: AirClipmap.run_blocking")
	check(cm.has_method("poll_slice") and cm.has_method("poll"), "C7: poll, poll_slice остаются")
