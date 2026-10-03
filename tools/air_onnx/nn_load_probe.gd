extends Node
## ON-5: загрузка встроенного места (Онгудай, 12:00, 3 м/с с 150°) с engine = nn, headless, без GPU.
## Модель — --air-nn-model=<путь> (после «--»). Печатает строку журнала air_model и время этапа
## «Рассчитываем ветер» с разбивкой (вход места, карты, сеть, сборка поля, термики). Код 0 — строка
## журнала напечатана (поле или аналитика), 1 — расчёт не завершился.
##   tools/air_onnx/nn_load_probe.sh <model.onnx> [место] [час] [ветер м/с] [откуда °]


## Атмосфера-заглушка: принимает поле, как Atmosphere.set_air_field.
class StubAtmo:
	extends RefCounted
	var field: Variant = null

	func set_air_field(f: Variant, _blend: float) -> void:
		field = f


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var loc_id := "ongudai"
	var hour := 12.0
	var u10 := 3.0
	var wdir := 150.0
	var pos: Array[String] = []
	for a in args:
		if not a.begins_with("--"):
			pos.append(a)
	if pos.size() > 0:
		loc_id = pos[0]
	if pos.size() > 1:
		hour = float(pos[1])
	if pos.size() > 2:
		u10 = float(pos[2])
	if pos.size() > 3:
		wdir = float(pos[3])
	Config.get_config("atmosphere").air_model.engine = "nn"
	var t_all := Time.get_ticks_usec()
	var place := _place(loc_id)
	print("nn_load_probe: место %s, %.1f ч, %.1f м/с с %.0f°, подготовка слоя %.2f с" % [
		loc_id, hour, u10, wdir, (Time.get_ticks_usec() - t_all) / 1e6])
	var atmo := StubAtmo.new()
	var rt := AirRuntime.new()
	add_child(rt)
	rt.focus_fn = func() -> Vector3: return Vector3.ZERO
	rt.setup(atmo, place, func() -> Dictionary:
		return {hour = hour, u10 = u10, wdir = wdir, t_max = NAN, sky = "clear"})
	var t0 := Time.get_ticks_usec()
	var ok: bool = await rt.load_field()
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	print("nn_load_probe: этап «Рассчитываем ветер» %.2f с (поле %s, ошибка «%s»)" % [
		wall, "есть" if ok else "нет", rt.last_error])
	var code := 0
	if ok:
		var info := rt.last_info
		var st: Dictionary = info.get("nn_stages", {})
		var f: WindField = atmo.field[0] if atmo.field is Array and not (atmo.field as Array).is_empty() else null
		print("nn_load_probe: разбивка последнего прохода, мс: вход места %.0f, карты и числа %.0f, сеть %.0f, сборка поля %.0f; загрузка модели %.0f" % [
			st.get("input", 0.0), st.get("prep", 0.0), st.get("net", 0.0), st.get("build", 0.0),
			info.get("nn_load_ms", 0.0)])
		for e: Dictionary in info.get("pass_log", []):
			print("nn_load_probe: проход k %.3f → U %.2f м/с, %.2f с" % [e.k, e.u, e.pass_s])
		if f != null:
			var has := AirThermals.has_inputs(f)
			var t1 := Time.get_ticks_usec()
			var src := AirThermals.new()
			var cfg: Dictionary = Config.get_config("atmosphere").thermal.duplicate()
			cfg["duty"] = float(Config.get_config("weather/medium").thermal_duty)
			cfg["cloudbase_msl"] = 1.0e9
			var built := has and src.build(f, cfg)
			var th_ms := (Time.get_ticks_usec() - t1) / 1000.0
			print("nn_load_probe: поле %s, сетка %d×%d×%d; термики: входы поля %s, источников %d, сборка %.0f мс" % [
				f.meta.get("source", "?"), f.nx, f.ny, f.nz, "есть" if has else "нет",
				src.count() if built else 0, th_ms])
	get_tree().quit(code)


## Слой detail встроенного места и его маска воды (как tests/atmosphere/test_air_place.gd).
func _place(loc_id: String) -> Dictionary:
	var dir := "res://data/terrain/%s" % loc_id
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	var detail: HeightLayer = null
	var water: Image = null
	for info: Dictionary in meta.layers:
		if String(info.id) == "detail":
			detail = HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
			if info.has("water_file"):
				var tex := load(dir.path_join(String(info.water_file))) as Texture2D
				water = tex.get_image() if tex != null else null
	var loc: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://configs/locations/%s.json" % loc_id))
	loc.id = loc_id
	return {detail = detail, water = water, loc = loc}
