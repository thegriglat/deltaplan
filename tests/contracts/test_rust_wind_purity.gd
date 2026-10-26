extends TestCase
## Храповик чистоты границы ветра (rust-wind W10, T7): вне файлов реализации запрещены обращения к
## внутренностям воздуха (список ниже = W10). Нынешние обращения зафиксированы в
## rust_wind_purity_baseline.txt (строка «файл:шаблон<TAB>число»); новое или выросшее — FAIL,
## исчезнувшее — подсказка обновить базу. RW-3 доведёт базу до пустой — тогда тест = W10 целиком.
## Обновить базу: godot --headless --path . res://tests/run_tests.tscn -- --filter=rust_wind_purity
## с переменной среды DP_PURITY_WRITE=1.

const BASELINE := "res://tests/contracts/rust_wind_purity_baseline.txt"
const ROOT := "res://scripts"
## Получатель-узел воздуха: air / atmo / atmosphere, с подчёркиванием и продолжением имени
## (_air, atmo_cfg, air_runtime…). Шаблоны «на узле воздуха» (W10) ловят обращение к члену только
## у такого получателя — иначе d.field(…) прибора, model.step(…) или terrain.ground (не воздух) —
## ложные срабатывания.
const AIR := "\\b_?(?:air|atmo|atmosphere)\\w*"
## Запрещённые вне реализации обращения (W10 v1), регулярные выражения.
const PATTERNS: Array[String] = [
	# члены внутренностей — только у узла воздуха
	AIR + "\\.(?:field|wind|ground|cloud_phys|wave|storm)\\b", AIR + "\\.air_field",
	# то же строкой: air.get("field"), air.call("step", …), air.set("time_s", …)
	AIR + "\\.(?:get|set|call)\\(\"(?:field|wind|ground|cloud_phys|wave|storm|air_field|time_s|step|set_ground|set_day|set_wind|set_weather|set_air_field)\"",
	# внутренние имена и типы реализации — где бы ни стояли
	"_ground_ref", "_rmin", "_last_sigma", "\\bAirRuntime\\b", "\\bThermalField\\b",
	"\\bWindField\\b", "\\bWindModel\\b", "\\bGroundField\\b", "\\bCloudPhysics\\b",
	"\\bCloudField\\b", "\\bAtmoThermal\\b", "\\bAirFieldSet\\b",
	# переходные входы и шаг — только у узла воздуха
	AIR + "\\.step\\(", AIR + "\\.time_s\\s*=[^=]",
	AIR + "\\.(?:set_air_field|set_ground|set_day|set_wind|set_weather)\\b",
]
## Потребители внутри scripts/atmosphere/ — под запретом (W10), где бы ни лежали.
const CONSUMERS: Array[String] = [
	"cloud_layer.gd", "cloud_shadow_map.gd", "cirrus_layer.gd", "gust_dust.gd", "dust_devils.gd",
	"bird_flock.gd", "thermal_signs.gd", "atmo_fingerprint.gd", "atmosphere_preview.gd",
	"wind_field_debug.gd", "debug_overlays.gd", "atmo_fingerprint_cli.gd", "atmo_fingerprint_main.gd",
]
## Файлы реализации (явный список): scripts/atmosphere/*.gd, не потребители. Новый файл — правка
## этого списка и W10 через координатора. scripts/atmosphere/air_model/** — реализация целиком.
const IMPL_FILES: Array[String] = [
	"res://scripts/atmosphere/air_field_cache.gd",
	"res://scripts/atmosphere/air_place_data.gd",
	"res://scripts/atmosphere/atmo_day.gd",
	"res://scripts/atmosphere/atmo_thermal.gd",
	"res://scripts/atmosphere/atmosphere.gd",
	"res://scripts/atmosphere/climate_grid.gd",
	"res://scripts/atmosphere/cloud_compositor_effect.gd",
	"res://scripts/atmosphere/cloud_field.gd",
	"res://scripts/atmosphere/cloud_field_codec.gd",
	"res://scripts/atmosphere/cloud_field_sources.gd",
	"res://scripts/atmosphere/cloud_model.gd",
	"res://scripts/atmosphere/cloud_physics.gd",
	"res://scripts/atmosphere/dust_model.gd",
	"res://scripts/atmosphere/field_turbulence.gd",
	"res://scripts/atmosphere/ground_field.gd",
	"res://scripts/atmosphere/gust_dust_model.gd",
	"res://scripts/atmosphere/gust_spectrum.gd",
	"res://scripts/atmosphere/storm_field.gd",
	"res://scripts/atmosphere/sun_transmission.gd",
	"res://scripts/atmosphere/surface_heat.gd",
	"res://scripts/atmosphere/surface_heating.gd",
	"res://scripts/atmosphere/thermal_field.gd",
	"res://scripts/atmosphere/wave_field.gd",
	"res://scripts/atmosphere/weather_model.gd",
	"res://scripts/atmosphere/wind_model.gd",
	"res://scripts/atmosphere/wind_profile.gd",
]
const IMPL_DIR := "res://scripts/atmosphere/air_model/"
const ATMO_DIR := "res://scripts/atmosphere/"


static func _gd_files(dir: String, out: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_gd_files(dir.path_join(d), out)


static func _is_impl(path: String) -> bool:
	return path.begins_with(IMPL_DIR) or IMPL_FILES.has(path)


## Снимок: «файл:шаблон» → число вхождений, по всем .gd в scripts/ вне реализации.
static func scan() -> Dictionary:
	var files := PackedStringArray()
	_gd_files(ROOT, files)
	files.sort()
	var regs: Array[RegEx] = []
	for p in PATTERNS:
		var re := RegEx.new()
		re.compile(p)
		regs.append(re)
	var out := {}
	for f in files:
		if _is_impl(f):
			continue
		var text := FileAccess.get_file_as_string(f)
		for i in PATTERNS.size():
			var n := regs[i].search_all(text).size()
			if n > 0:
				out["%s:%s" % [f.trim_prefix("res://"), PATTERNS[i]]] = n
	return out


static func _read_baseline() -> Dictionary:
	var out := {}
	for line in FileAccess.get_file_as_string(BASELINE).split("\n", false):
		if line.begins_with("#"):
			continue
		var tab := line.rfind("\t")
		if tab < 0:
			continue
		out[line.substr(0, tab)] = int(line.substr(tab + 1))
	return out


static func _baseline_text(snap: Dictionary) -> String:
	var keys: Array = snap.keys()
	keys.sort()
	var s := "# Храповик чистоты W10: файл:шаблон<TAB>число вхождений. Только вниз; обновление — см. test_rust_wind_purity.gd\n"
	for k: String in keys:
		s += "%s\t%d\n" % [k, snap[k]]
	return s


func test_atmosphere_files_classified() -> void:
	var files := PackedStringArray()
	_gd_files(ATMO_DIR, files)
	for f in files:
		if f.begins_with(IMPL_DIR):
			continue
		var name := f.get_file()
		var known := IMPL_FILES.has(f) or CONSUMERS.has(name)
		check(known, "%s: не отнесён ни к реализации, ни к потребителям (список в тесте и W10 — через координатора)" % f)
	for f in IMPL_FILES:
		check(FileAccess.file_exists(f), "%s: файл реализации из списка существует" % f)
		check(not CONSUMERS.has(f.get_file()), "%s: не может быть и реализацией, и потребителем" % f)


func test_no_new_internal_access() -> void:
	var snap := scan()
	if OS.get_environment("DP_PURITY_WRITE") == "1":
		var fa := FileAccess.open(ProjectSettings.globalize_path(BASELINE), FileAccess.WRITE)
		fa.store_string(_baseline_text(snap))
		fa.close()
		return
	var base := _read_baseline()
	var worse := 0
	var better := 0
	for k: String in snap:
		var was := int(base.get(k, 0))
		if int(snap[k]) > was:
			worse += 1
			check(false, "новое обращение во внутренности воздуха (W10): %s — %d, было %d. Используйте фасад Atmosphere (W2)" % [k, snap[k], was])
	for k: String in base:
		if int(snap.get(k, 0)) < int(base[k]):
			better += 1
	if better > 0 and worse == 0:
		print("rust_wind_purity: обращений стало меньше (%d записей) — обновите базу: DP_PURITY_WRITE=1" % better)
