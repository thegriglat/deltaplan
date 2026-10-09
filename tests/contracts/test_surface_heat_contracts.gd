extends TestCase
## Контрактные тесты surface-heat (docs/contracts/surface-heat.md): SH1 конфиг, SH2 ядро SurfaceHeat.
## SH3…SH5 пока проверяются только версией (дополняют SH-4/SH-5). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/surface-heat.md"
const CSV := "res://docs/research/surface_params.csv"
const VERSIONS := {"SH1": 1, "SH2": 2, "SH3": 1, "SH4": 1, "SH5": 1}
const ROWS := {
	"none": "grassland", "forest": "trees", "grass": "grassland", "crop": "cropland",
	"shrub": "shrubland", "bare": "bare_rock", "water": "water", "built": "built_up", "snow": "snow_ice",
}
const SIGS := {
	"config": 0, "shortwave": 5, "bowen": 3, "land_flux": 5, "water_temp_c": 5, "air_temp_c": 5,
	"water_flux": 5, "mix_flux": 8,
}


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


func test_config_keys() -> void:
	var cfg := SurfaceHeat.config()
	for k: String in ["classes", "radiation", "moisture", "water", "thermal"]:
		check(cfg.get(k) is Dictionary, "SH1: секция %s" % k)
	check(cfg.get("_doc") is String, "SH1: _doc")
	var cl: Dictionary = cfg.classes
	check(cl.size() == SurfaceLayer.CLASS_COUNT, "SH1: ровно 9 классов")
	for n in SurfaceLayer.CLASS_NAMES:
		check(cl.has(n), "SH1: класс %s" % n)
		var c: Dictionary = cl.get(n, {})
		check(c.get("p4_row") is String, "%s: p4_row" % n)
		for k: String in ["albedo", "bowen", "bowen_min", "bowen_max", "g_frac", "z0_m"]:
			check(c.get(k) is float, "%s: %s float" % [n, k])
		if c.size() < 7:
			continue
		check(c.p4_row == ROWS[n], "%s: соответствие П4" % n)
		check(c.bowen_min <= c.bowen and c.bowen <= c.bowen_max, "%s: bowen_min ≤ bowen ≤ bowen_max" % n)
		check(c.albedo > 0.0 and c.albedo < 1.0, "%s: albedo" % n)
		check(c.g_frac >= 0.0 and c.g_frac <= 1.0, "%s: g_frac" % n)
		check(c.z0_m > 0.0, "%s: z0_m" % n)
	var r: Dictionary = cfg.radiation
	for k: String in ["s0_wm2", "tk_a", "tk_b", "cloud_sw_k", "diffuse_frac", "l_star_wm2", "l_cloud_k"]:
		check(r.get(k) is float, "radiation.%s" % k)
	var m: Dictionary = cfg.moisture
	for k: String in ["m_dry", "m_norm", "m_wet"]:
		check(m.get(k) is float, "moisture.%s" % k)
	if m.size() >= 3:
		check(0.0 <= m.m_dry and m.m_dry < m.m_norm and m.m_norm < m.m_wet and m.m_wet <= 1.0, "moisture: порядок")
	var w: Dictionary = cfg.water
	for k: String in ["c_h", "rho_cp", "u_min_ms", "lag_days", "ice_c", "lapse_k_per_km"]:
		check(w.get(k) is float, "water.%s" % k)
	check(cfg.thermal.get("h_ref_wm2") is float, "thermal.h_ref_wm2")


func test_classes_match_csv() -> void:
	var lines := _read(CSV).split("\n", false)
	check(lines.size() > 2, "CSV читается")
	var head := lines[0].split(",")
	var rows := {}
	for i in range(1, lines.size()):
		var f := lines[i].split(",")
		if f.size() == head.size():
			rows[f[1]] = f
	var cl: Dictionary = SurfaceHeat.config().classes
	for n in SurfaceLayer.CLASS_NAMES:
		var c: Dictionary = cl[n]
		check(rows.has(c.p4_row), "%s: строка П4 %s есть" % [n, c.p4_row])
		if not rows.has(c.p4_row):
			continue
		var f: PackedStringArray = rows[c.p4_row]
		for k: String in ["albedo", "bowen", "bowen_min", "bowen_max", "g_frac"]:
			approx(float(c[k]), f[head.find(k)].to_float(), 1e-9, "%s.%s = CSV" % [n, k])
		approx(float(c.z0_m), f[head.find("z0_m")].to_float(), 1e-9, "%s.z0_m = CSV" % n)


func test_signatures() -> void:
	var scr: Script = load("res://scripts/atmosphere/surface_heat.gd")
	check(scr != null, "SH2: скрипт загружается")
	if scr == null:
		return
	var ms := {}
	for m in scr.get_script_method_list():
		ms[m.name] = m
	for n: String in SIGS:
		check(ms.has(n), "SH2: функция %s" % n)
		if ms.has(n):
			check(ms[n].args.size() == SIGS[n], "SH2: %s — %d аргументов" % [n, SIGS[n]])
	var order := {
		"shortwave": ["cos_inc", "sin_el", "cover", "sky_heat", "cfg"],
		"bowen": ["cls", "m", "cfg"],
		"land_flux": ["cls", "k_down", "cover", "m", "cfg"],
		"water_temp_c": ["month", "day", "z_m", "ctx", "wcfg"],
		"air_temp_c": ["hour", "t_max", "z_m", "ctx", "wcfg"],
		"water_flux": ["t_water_c", "t_air_c", "u_ms", "cfg", "z_m"],
		"mix_flux": ["fracs", "off", "normal", "class_sun", "m", "sky", "water", "cfg"],
	}
	for n: String in order:
		if not ms.has(n):
			continue
		var names: Array = []
		for a in ms[n].args:
			names.append(a.name)
		check(names == order[n], "SH2: %s порядок аргументов %s" % [n, names])
