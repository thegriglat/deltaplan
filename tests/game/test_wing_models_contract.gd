extends TestCase
## Контракт «конфиг крыла ↔ 3D-модель ↔ параметры формы ↔ перевод» (docs/wings_models3d_contracts.md,
## К2, версия 1): у каждого configs/wings/<id>.json есть запись tools/blender/glider_params.json →
## wings.<id>, модель glider_<id>.glb, площадь паруса в плане сходится с конфигом, тип конструкции и
## двойная обшивка согласованы, название — ключ locale/ui.csv с ru и en.

const PARAMS := "res://tools/blender/glider_params.json"
const LOCALE := "res://locale/ui.csv"
const AREA_TOL := 0.02          # ±2 % площади в плане от area_m2 конфига (ТЗ, «Как делать и проверять»)
const LOWER_COVER_TOL := 0.1    # lower_cover ≈ double_surface_pct/100 ± 0,1 (ТЗ, «Двойная поверхность»)


static func _params() -> Dictionary:
	var f := FileAccess.open(PARAMS, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d.get("wings", {}) if d is Dictionary else {}


## Ключи locale/ui.csv → [ru, en].
static func _locale() -> Dictionary:
	var out := {}
	var f := FileAccess.open(LOCALE, FileAccess.READ)
	if f == null:
		return out
	f.get_csv_line()  # шапка keys,ru,en
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() >= 3 and row[0] != "":
			out[row[0]] = [row[1], row[2]]
	return out


## Площадь паруса в плане по формуле WingShape.chord (build_gliders.py; то же — wings3d_geometry.py):
## c(a) = tip + (root − tip)(1 − a^0,85), скругление законцовки при a > 0,9.
static func planform_area(p: Dictionary, span: float) -> float:
	var root := float(p.root_chord_m)
	var tip := float(p.tip_chord_m)
	var round_tip := bool(p.get("tip_round", true))
	var n := 2000
	var s := 0.0
	for i in n:
		var a := (i + 0.5) / n
		var c := tip + (root - tip) * (1.0 - pow(a, 0.85))
		if round_tip and a > 0.9:
			c *= 1.0 - 0.35 * pow((a - 0.9) / 0.1, 2.0)
		s += c / n
	return span * s


static func _ids() -> Array[String]:
	var ids: Array[String] = []
	for c in Config.list_configs("wings"):
		ids.append(c.get_file())
	return ids


func test_every_config_has_params_and_model() -> void:
	var params := _params()
	check(not params.is_empty(), "glider_params.json читается")
	for id in _ids():
		var cfg := Config.get_config("wings/" + id)
		check(params.has(id), "%s: есть wings.%s в glider_params.json" % [id, id])
		if not params.has(id):
			continue
		var p: Dictionary = params[id]
		check(String(p.get("config", "")) == id, "%s: config = id" % id)
		check(String(p.get("out", "")) == "glider_" + id, "%s: out = glider_<id>" % id)
		var vis := String(cfg.visual.visual_model)
		check(vis == "res://assets/models/glider_%s.glb" % id, "%s: visual_model %s" % [id, vis])
		check(ResourceLoader.exists(vis), "%s: файл модели есть" % id)
		if p.has("span_m"):
			approx(float(p.span_m), float(cfg.span_m), 0.01, "%s: span_m записи = конфигу" % id)


func test_planform_area_matches_config() -> void:
	var params := _params()
	for id in _ids():
		if not params.has(id):
			continue
		var cfg := Config.get_config("wings/" + id)
		var area := float(cfg.area_m2)
		var a3d := planform_area(params[id], float(cfg.span_m))
		check(absf(a3d / area - 1.0) <= AREA_TOL,
			"%s: площадь в плане %.2f м² против конфига %.2f (±%d %%)" % [id, a3d, area, AREA_TOL * 100])


func test_construction_consistent() -> void:
	var params := _params()
	for id in _ids():
		if not params.has(id):
			continue
		var cfg := Config.get_config("wings/" + id)
		var p: Dictionary = params[id]
		var kp := float(p.get("kingpost_m", 0.0))
		check(bool(cfg.kingpost) == (kp > 0.0), "%s: kingpost %s ⇔ kingpost_m %.2f" % [id, cfg.kingpost, kp])
		var ds := float(cfg.double_surface_pct)
		if ds >= 50.0:
			check(bool(p.get("double_surface", false)), "%s: двойная обшивка %d %% ⇒ double_surface" % [id, ds])
			approx(float(p.get("lower_cover", 0.0)), ds / 100.0, LOWER_COVER_TOL,
				"%s: lower_cover ≈ double_surface_pct/100" % id)
		var nb := int(p.get("battens_per_side", 0))
		check(nb >= 5 and nb <= 20, "%s: лат на сторону %d" % [id, nb])


func test_name_translated() -> void:
	var loc := _locale()
	for id in _ids():
		var key := String(Config.get_config("wings/" + id).get("name", ""))
		check(loc.has(key), "%s: ключ названия %s в locale/ui.csv" % [id, key])
		if loc.has(key):
			check(String(loc[key][0]) != "" and String(loc[key][1]) != "", "%s: есть ru и en" % id)
