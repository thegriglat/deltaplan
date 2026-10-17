class_name AirBakedField
extends RefCounted
## Запечённое поле ветра старта (TI-К3, docs/contracts/training-island.md): набор уровней среднего
## поля (AirFieldSet.levels: область 400 м + окна 100 и 50 м) в двух файлах рядом —
## <старт>.json (заголовок) и <старт>.bin (тело: массивы подряд, 3D-каналы float16, по столбцам
## float32, всё вместе — zstd). Поле считает tools/terrain/bake_air.gd; игра (AirRuntime.load_field)
## берёт файл при точном совпадении key вместо расчёта. Формат состояния модели воздуха (WindField,
## AirCase.meta) не меняется: уровень собирается тем же WindField.from_arrays.
##
## Что лежит в meta уровня: всё, что вернул решатель (AirCase.meta() + source, cond), кроме сетки
## (она в "grid"); упакованные массивы meta (heat, z0-карта, gam) — отдельными массивами тела
## ("heat", "meta.<ключ>", float32), прочее — JSON.

const FORMAT := "dp-air-baked"
const VERSION := 1
## Каналы по клеткам (float16) в порядке тела.
const CHANNELS_3D: Array[String] = ["u", "v", "w_mech", "w_conv", "theta"]
const GRID_KEYS: Array[String] = ["dx", "dz", "x0", "y0", "z_bot", "nx", "ny", "nz"]
## Служебные ключи meta, которые не пишутся (путь читаемого файла и таблица массивов).
const META_SKIP: Array[String] = ["arrays", "path"]
## Ширина картинки-носителя при переводе float32 ↔ float16 средствами движка.
const IMG_W := 1024
## Допуск сравнения чисел key (JSON хранит не все разряды double).
const KEY_TOL := 1.0e-6
## Шаг округления координат старта в key, м.
const START_ROUND_M := 0.01

## Корень данных мест: <корень>/<id места>/air/<старт>.json. Тесты подменяют на user://….
static var baked_root := "res://data/locations"

static var _hash_cache: Dictionary = {}


## Путь заголовка запечённого поля старта.
static func path_of(loc_id: String, site_id: String, root: String = "") -> String:
	var r := baked_root if root == "" else root
	return r.path_join(loc_id).path_join("air").path_join(site_id + ".json")


# ---------------------------------------------------------------- запись


## Записать набор: путь — к .json (рядом .bin). header: {location, site, key, model_hash} (остальное
## — формат добавляет сам). Тело пишется первым, заголовок — последним (есть заголовок — файл
## целый); оба — во временный файл и переименование. true — записано.
## lossless — без потерь (кеш поля, FL-К1 v2): 3D-каналы float32, числа meta — полной точности JSON;
## формат тот же (дтип — по массиву). По умолчанию — запечённое TI-К3: каналы float16.
static func save(fs: AirFieldSet, header: Dictionary, path: String, lossless := false) -> bool:
	var base := path.trim_suffix(".json").trim_suffix(".bin")
	var body := PackedByteArray()
	var levels: Array = []
	for f: WindField in fs.levels:
		var arrays := {}
		var meta := {}
		var packed := {}
		for key: String in f.meta:
			var v: Variant = f.meta[key]
			if key in GRID_KEYS or key in META_SKIP:
				continue
			if v is PackedFloat32Array or v is PackedFloat64Array:
				packed["heat" if key == "heat" else "meta." + key] = PackedFloat32Array(v)
			else:
				meta[key] = _json_safe(v)
		for name in CHANNELS_3D:
			_append(body, arrays, name, _channel(f, name), "f32" if lossless else "f16")
		_append(body, arrays, "hc", f._hc, "f32")
		for name: String in packed:
			_append(body, arrays, name, packed[name], "f32")
		var grid := {}
		for k in GRID_KEYS:
			grid[k] = f.meta.get(k)
		levels.append(
			{
				"name": "dx%d" % roundi(f.dx),
				"grid": grid,
				"meta": meta,
				"arrays": arrays,
			}
		)
	var out := header.duplicate(true)
	out["format"] = FORMAT
	out["version"] = VERSION
	out["levels"] = levels
	out["compression"] = "zstd"
	out["raw_bytes"] = body.size()
	var packed_body := body.compress(FileAccess.COMPRESSION_ZSTD)
	DirAccess.make_dir_recursive_absolute(base.get_base_dir())
	if not _write_atomic(base + ".bin", packed_body):
		return false
	return _write_atomic(base + ".json", JSON.stringify(out, "\t", true, lossless).to_utf8_buffer())


static func _write_atomic(path: String, data: PackedByteArray) -> bool:
	var tmp := path + ".tmp"
	var fa := FileAccess.open(tmp, FileAccess.WRITE)
	if fa == null:
		push_error("AirBakedField: не открыть %s на запись (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	fa.store_buffer(data)
	fa.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_error("AirBakedField: не переименовать %s (%s)" % [tmp, error_string(err)])
		return false
	return true


## Канал 3D-поля уровня по клеткам (раскладка WindField: u, v, w_mech подряд на клетку).
static func _channel(f: WindField, name: String) -> PackedFloat32Array:
	var n := f.nx * f.ny * f.nz
	var out := PackedFloat32Array()
	match name:
		"w_conv":
			return f._wconv.duplicate()
		"theta":
			return f._theta.duplicate()
	var ch := 0 if name == "u" else (1 if name == "v" else 2)
	out.resize(n)
	var vel := f._vel
	for c in n:
		out[c] = vel[c * 3 + ch]
	return out


static func _append(
	body: PackedByteArray, arrays: Dictionary, name: String, a: PackedFloat32Array, kind: String
) -> void:
	var bytes := _to_half(a) if kind == "f16" else a.to_byte_array()
	arrays[name] = [body.size(), bytes.size(), kind]
	body.append_array(bytes)


## Образ для JSON: нечисловые значения (NaN, ∞) → null, векторы и прочее — пропуск.
static func _json_safe(v: Variant) -> Variant:
	if v is float:
		return v if is_finite(v) else null
	if v is Dictionary:
		var d := {}
		for k: Variant in v:
			d[str(k)] = _json_safe(v[k])
		return d
	if v is Array:
		var a := []
		for x: Variant in v:
			a.append(_json_safe(x))
		return a
	if v is int or v is bool or v is String or v == null:
		return v
	return null


# ---------------------------------------------------------------- чтение


## Заголовок (.json) или {} — нет файла, не читается, не тот формат/версия.
static func read_header(path: String) -> Dictionary:
	var base := path.trim_suffix(".json").trim_suffix(".bin")
	if not FileAccess.file_exists(base + ".json"):
		return {}
	var js: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
	if not js is Dictionary:
		return {}
	var h: Dictionary = js
	if String(h.get("format", "")) != FORMAT or int(h.get("version", -1)) != VERSION:
		return {}
	return h


## Набор уровней из файла. key — ожидаемый key (null — не проверять): не совпал → null (причина
## в push_warning). Рабочий поток допустим (сцену не трогает).
static func load_file(path: String, key: Variant = null) -> AirFieldSet:
	var base := path.trim_suffix(".json").trim_suffix(".bin")
	var h := read_header(base)
	if h.is_empty():
		push_warning("AirBakedField: %s.json — нет, не читается или чужая версия формата" % base)
		return null
	if key != null:
		var why := key_diff(h.get("key"), key)
		if why != "":
			push_warning("AirBakedField: %s — key не совпал (%s), поле не берётся" % [base, why])
			return null
		if not model_hash_ok(h):
			push_warning("AirBakedField: %s — собрано другой версией модели воздуха, поле не берётся" % base)
			return null
	var comp := FileAccess.get_file_as_bytes(base + ".bin")
	if comp.is_empty():
		push_warning("AirBakedField: нет %s.bin" % base)
		return null
	var raw_n := int(h.get("raw_bytes", 0))
	var body := comp.decompress(raw_n, FileAccess.COMPRESSION_ZSTD)
	if body.size() != raw_n or raw_n <= 0:
		push_warning("AirBakedField: %s.bin не распаковался" % base)
		return null
	# уровни собираются параллельно (WindField.from_arrays — столбцы и пограничный слой, сотни мс на
	# уровень): чтение из кеша/файла за ~1 с, а не за сумму уровней (FL-2)
	var lvs: Array = h.get("levels", [])
	var built: Array = []
	built.resize(lvs.size())
	if lvs.size() > 1:
		PoolFor.run(func(i: int) -> void: built[i] = _level(lvs[i], body), lvs.size(), "AirBakedField.levels")
	elif lvs.size() == 1:
		built[0] = _level(lvs[0], body)
	var levels: Array[WindField] = []
	for i in lvs.size():
		var f: WindField = built[i]
		if f == null:
			push_warning("AirBakedField: %s — уровень %s не собрался" % [base, lvs[i].get("name", "?")])
			return null
		f.meta["path_baked"] = base
		levels.append(f)
	if levels.is_empty():
		return null
	var fs := AirFieldSet.new()
	fs.set_field(levels, 0.0)
	return fs


static func _level(lv: Dictionary, body: PackedByteArray) -> WindField:
	var arrays: Dictionary = lv.get("arrays", {})
	for name in CHANNELS_3D + ["hc"]:
		if not arrays.has(name):
			return null
	var m: Dictionary = (lv.get("meta", {}) as Dictionary).duplicate(true)
	m.merge(lv.get("grid", {}), true)
	var ch := {}
	for name in CHANNELS_3D:
		ch[name] = _array(body, arrays[name])
	for name: String in arrays:
		if name == "heat":
			m["heat"] = _array(body, arrays[name])
		elif name.begins_with("meta."):
			m[name.substr(5)] = _array(body, arrays[name])
	return WindField.from_arrays(
		m, ch.u, ch.v, ch.w_mech, ch.w_conv, ch.theta, _array(body, arrays["hc"])
	)


static func _array(body: PackedByteArray, ent: Array) -> PackedFloat32Array:
	var seg := body.slice(int(ent[0]), int(ent[0]) + int(ent[1]))
	if String(ent[2]) == "f16":
		return _from_half(seg)
	return seg.to_float32_array()


## float32 → float16 (байты) средствами движка: картинка RF → RH.
static func _to_half(a: PackedFloat32Array) -> PackedByteArray:
	var n := a.size()
	if n == 0:
		return PackedByteArray()
	var rows := ceili(float(n) / IMG_W)
	var bytes := a.to_byte_array()
	bytes.resize(IMG_W * rows * 4)
	var img := Image.create_from_data(IMG_W, rows, false, Image.FORMAT_RF, bytes)
	img.convert(Image.FORMAT_RH)
	var out := img.get_data()
	out.resize(n * 2)
	return out


static func _from_half(h: PackedByteArray) -> PackedFloat32Array:
	var n := h.size() / 2
	if n == 0:
		return PackedFloat32Array()
	var rows := ceili(float(n) / IMG_W)
	var bytes := h.duplicate()
	bytes.resize(IMG_W * rows * 2)
	var img := Image.create_from_data(IMG_W, rows, false, Image.FORMAT_RH, bytes)
	img.convert(Image.FORMAT_RF)
	var out := img.get_data().to_float32_array()
	out.resize(n)
	return out


# ---------------------------------------------------------------- key и хеши


## key (TI-К3): всё, от чего зависит поле старта и что известно до расчёта. weather — как в конфиге
## места (TI-К2); start — точка старта (мир, x и z); центры окон — старт, области — место (по данным
## места, их хеш — data_hash).
static func make_key(
	loc_id: String,
	center_lat: float,
	center_lon: float,
	site_id: String,
	weather: Dictionary,
	start: Vector3,
	data_hash: String,
	window_dx: Array = []
) -> Dictionary:
	return {
		"location": loc_id,
		"site": site_id,
		"weather": weather.duplicate(true),
		"center": [snappedf(center_lat, 1.0e-6), snappedf(center_lon, 1.0e-6)],
		"start": [snappedf(start.x, START_ROUND_M), snappedf(start.z, START_ROUND_M)],
		"domain_dx": AirRuntime.DX,
		"window_dx": window_dx,
		"data_hash": data_hash,
		"format": VERSION,
	}


## Первое расхождение a и b ("" — равны): числа с допуском KEY_TOL, словари — по ключам a и b.
static func key_diff(a: Variant, b: Variant, path: String = "key") -> String:
	if a == null or b == null:
		return "" if a == null and b == null else "%s: нет значения" % path
	if (a is float or a is int) and (b is float or b is int):
		return "" if absf(float(a) - float(b)) <= KEY_TOL else "%s: %s ≠ %s" % [path, a, b]
	if a is Dictionary and b is Dictionary:
		for k: Variant in a:
			if not (b as Dictionary).has(k):
				return "%s.%s: нет в ожидаемом" % [path, k]
			var d := key_diff(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		for k: Variant in b:
			if not (a as Dictionary).has(k):
				return "%s.%s: нет в файле" % [path, k]
		return ""
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: длина %d ≠ %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := key_diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	return "" if typeof(a) == typeof(b) and a == b else "%s: %s ≠ %s" % [path, a, b]


## Хеш данных места: meta.json, surface.json и файлы слоя detail (detail*, без служебных .import) папки места. "" — места
## нет (нет meta.json). Кеш по папке — сведения места в игре не меняются.
static func place_hash(dir: String) -> String:
	if _hash_cache.has(dir):
		return _hash_cache[dir]
	var out := ""
	if FileAccess.file_exists(dir.path_join("meta.json")):
		var lines := PackedStringArray()
		var names := Array(DirAccess.get_files_at(dir))
		names.sort()
		for n: String in names:
			# .import — служебные файлы редактора: в экспорте их нет, хеш был бы другим
			if n.ends_with(".import") or n.ends_with(".remap"):
				continue
			if n == "meta.json" or n == "surface.json" or n.begins_with("detail"):
				lines.append("%s:%s" % [n, FileAccess.get_sha256(dir.path_join(n))])
		out = "\n".join(lines).sha256_text().substr(0, 16)
	_hash_cache[dir] = out
	return out


## Файл с хешем кода модели в экспорте (.gd токенизированы, .glsl импортированы — исходники из pck
## не прочитать); пишет tools/terrain/air_model_hash.gd перед экспортом (tools/build.sh).
const CODE_HASH_FILE := "res://data/air_model_hash.txt"

static var _code_hash_cache := ""


## Хеш кода модели по исходникам: *.gd и *.glsl каталога модели (кроме этого файла). "" — исходники
## не читаются (экспорт).
static func code_hash_of_sources() -> String:
	var dir := "res://scripts/atmosphere/air_model"
	var names := Array(DirAccess.get_files_at(dir))
	names.sort()
	var lines := PackedStringArray()
	for n: String in names:
		if (n.ends_with(".gd") or n.ends_with(".glsl")) and n != "air_baked_field.gd":
			lines.append("%s:%s" % [n, FileAccess.get_sha256(dir.path_join(n))])
	if lines.is_empty():
		return ""
	return "\n".join(lines).sha256_text()


## Хеш кода модели: по исходникам, а если они не читаются (экспорт) — из CODE_HASH_FILE. "" — нет ни
## того, ни другого.
static func code_hash() -> String:
	if _code_hash_cache != "":
		return _code_hash_cache
	var h := code_hash_of_sources()
	if h == "" and FileAccess.file_exists(CODE_HASH_FILE):
		h = FileAccess.get_file_as_string(CODE_HASH_FILE).strip_edges()
	_code_hash_cache = h
	return h


## Конфиг без слоёв профиля пилота (user://configs, user://local/configs): те — настройки машины и
## пилота (в т. ч. весь atmosphere.air_model как машинный ключ S7), на модель не влияют, а хеш от
## профиля делал запечённое поле «устаревшим» в другом профиле. Берутся res://configs и правки
## рядом с игрой (их пилот правит осознанно: изменённая модель — запечённое не берётся).
static func _model_config(config_name: String) -> Dictionary:
	var dirs := PackedStringArray(["res://configs"])
	if not OS.has_feature("editor"):
		dirs.append(OS.get_executable_path().get_base_dir().path_join("configs"))
	var out := {}
	for d in dirs:
		var path := d.path_join(config_name + ".json")
		if not FileAccess.file_exists(path):
			continue
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			out = _merge(out, data)
	return out


static func _merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k: Variant in over:
		if out.has(k) and out[k] is Dictionary and over[k] is Dictionary:
			out[k] = _merge(out[k], over[k])
		else:
			out[k] = over[k]
	return out


## Хеш модели воздуха (TI-К3 v3): код (code_hash) и секции air_model и air_phase configs/atmosphere.json,
## weather_model.json, surface_heat.json (слои конфигов — _model_config, без профиля пилота).
## "" — кода не узнать: запечённое не брать.
static func model_hash() -> String:
	var lines := PackedStringArray()
	var code := code_hash()
	if code == "":
		return ""
	lines.append("code:" + code)
	var atm := _model_config("atmosphere")
	for part: Array in [
		["air_model", atm.get("air_model", {})],
		["air_phase", atm.get("air_phase", {})],
		["weather_model", _model_config("weather_model")],
		["surface_heat", _model_config("surface_heat")],
	]:
		lines.append("%s:%s" % [part[0], JSON.stringify(part[1], "", true).sha256_text()])
	return "\n".join(lines).sha256_text().substr(0, 16)


## Хеш модели в заголовке совпадает с текущим. Текущий не узнать — не совпал.
static func model_hash_ok(header: Dictionary) -> bool:
	var now := model_hash()
	return now != "" and String(header.get("model_hash", "")) == now


# ---------------------------------------------------------------- условия (TI-К2)


## Условия расчёта AirRuntime ({hour, u10, wdir, t_max, sky, wind_ref}) по набору погоды TI-К2 — ключ
## weather конфига старта. Единственное место разбора набора на стороне поля: те же числа, что
## FlightSettings получает из набора (wind_speed_ms·3,6 км/ч → u10 = wind_speed_ms).
static func conditions_of(weather: Dictionary) -> Dictionary:
	return {
		hour = float(weather.start_hour),
		u10 = float(weather.wind_speed_ms),
		wdir = float(weather.wind_from_deg),
		t_max = float(weather.temperature_c),
		sky = String(weather.sky),
		wind_ref = String(weather.get("wind_ref", "start")),
	}


## Условия игры c против набора погоды старта и даты места: "" — те же, иначе что отличается.
static func conditions_diff(weather: Dictionary, c: Dictionary, month: int, day: int) -> String:
	var w := conditions_of(weather)
	if absf(float(c.hour) - float(w.hour)) > 1.0 / 60.0:
		return "час %.3f ≠ %.3f" % [float(c.hour), float(w.hour)]
	if absf(float(c.u10) - float(w.u10)) > AirRuntime.WIND_TOL_MS:
		return "ветер %.2f ≠ %.2f м/с" % [float(c.u10), float(w.u10)]
	var dd := angle_difference(deg_to_rad(float(c.wdir)), deg_to_rad(float(w.wdir)))
	if absf(dd) > deg_to_rad(AirRuntime.DIR_TOL_DEG):
		return "направление %.1f ≠ %.1f°" % [float(c.wdir), float(w.wdir)]
	if String(c.get("wind_ref", "start")) != String(w.wind_ref):
		return "опора ветра %s ≠ %s" % [c.get("wind_ref", "start"), w.wind_ref]
	if absf(float(c.get("t_max", NAN)) - float(w.t_max)) > AirRuntime.TMAX_TOL_C:
		return "температура %s ≠ %s" % [c.get("t_max"), w.t_max]
	if String(c.get("sky", "")) != String(w.sky):
		return "небо %s ≠ %s" % [c.get("sky"), w.sky]
	if month != int(weather.month) or day != int(weather.day):
		return "дата %d.%d ≠ %d.%d" % [day, month, int(weather.day), int(weather.month)]
	return ""
