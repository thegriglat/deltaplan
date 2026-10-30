class_name Weather
extends RefCounted
## Погода: тонкая обёртка над DpWeather (W12 v3, docs/contracts/rust-wind/weather.md). Расчётов погоды
## здесь нет — каждый метод один вызов крейта и разбор JSON. Игра знает пути: читает конфиги секций
## и сетки климата ERA5 (data/climate/*.bin, brotli), распаковывает тело и отдаёт крейту байты.
## Остаётся в GD только то, что про меню и рельеф игры: config() (ui.*, sky.options), пробы высот
## рельефа для ground_context.
##
##   var tx := Weather.typical_max_c(7, 15, 51.9, 85.9)
##   var w := Weather.derive(settings.forecast(), ctx, hour)       # ключи пресета + _derived
##   var day := Weather.diurnal_state(t_max, hour, ctx)            # {temperature_c, sunset_h, …}
##
## ctx места — словарь {month, day, lat, lon, utc_offset_h, valley_msl_m, mean_msl_m, start_msl_m};
## нет ключа или NAN — «не задано» (month/day по умолчанию 7/15). Нет расширения — NAN / {} / "".

const HEADER := 64
const GRID_NAMES := ["hh1", "hh2", "hh5", "hh6"]

## Файлы сеток климата по имени сетки (HH7). Тесты подменяют через set_grid_paths.
const DEFAULT_PATHS := {
	"hh1": "res://data/climate/dew_point_1deg.bin",
	"hh2": "res://data/climate/upper_air_1deg.bin",
	"hh5": "res://data/climate/surface_t_1deg.bin",
	"hh6": "res://data/climate/upper_misc_1deg.bin",
}
## Секции конфигов, которые читает крейт (как у DpAir.configure), плюс weather/<пресет>.
const SECTIONS := ["atmosphere", "weather_model", "surface_heat", "world"]

static var paths := DEFAULT_PATHS.duplicate()
static var _dp: RefCounted = null
static var _missing := false
static var _hour_at_args := -1


## Подменить пути сеток (тесты) и пересоздать DpWeather; пустой словарь — пути по умолчанию.
static func set_grid_paths(over: Dictionary) -> void:
	paths = DEFAULT_PATHS.duplicate()
	paths.merge(over, true)
	_dp = null


## Пересоздать DpWeather при следующем обращении (после смены конфигов).
static func reset() -> void:
	_dp = null


## Есть ли расширение (DpWeather).
static func available() -> bool:
	return dp() != null


## Секция weather_model.json целиком — для меню (ui.*, sky.options) и ключей, которых крейт не отдаёт.
static func config() -> Dictionary:
	return Config.get_config("weather_model")


## Текст конфига для крейта «как есть»: единственный слой res://configs — файл целиком (числа не
## переписываются), пилотские слои поверх — слитый словарь.
static func config_text(config_name: String) -> String:
	var texts := PackedStringArray()
	for dir: String in Config.search_dirs():
		var path: String = dir.path_join(config_name + ".json")
		if FileAccess.file_exists(path):
			texts.append(FileAccess.get_file_as_string(path))
	if texts.size() == 1:
		return texts[0]
	return JSON.stringify(Config.get_config(config_name))


## Конфиги крейта парами «имя, текст» (W5): atmosphere, weather_model, surface_heat, world, weather/*.
## override — подмена текста секции (тесты, сид/детерминизм атмосферы).
static func config_pairs(override: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	for n: String in SECTIONS:
		out.append(n)
		out.append(String(override[n]) if override.has(n) else config_text(n))
	for n: String in Config.list_configs("weather"):
		out.append(n)
		out.append(config_text(n))
	return out


## Единственный DpWeather игры, настроенный лениво; null — нет расширения или конфиги не приняты.
static func dp() -> RefCounted:
	if _dp != null or _missing:
		return _dp
	if not ClassDB.class_exists("DpWeather"):
		_missing = true
		print("Weather: нет расширения DpWeather — погода недоступна")
		return null
	var w: RefCounted = ClassDB.instantiate("DpWeather")
	var names := PackedStringArray()
	var bodies: Array[PackedByteArray] = []
	for n: String in GRID_NAMES:
		var raw := _grid_bytes(String(paths[n]))
		if not raw.is_empty():
			names.append(n)
			bodies.append(raw)
	var code: int = w.configure(config_pairs(), names, bodies)
	if code != 0:
		push_error("Weather: DpWeather.configure вернул %d" % code)
		_missing = true
		return null
	for m: Dictionary in w.get_method_list():
		if m.name == "hour_at":
			_hour_at_args = (m.args as Array).size()
	_dp = w
	return _dp


## Сетка как её ждёт крейт: 64 байта заголовка файла + распакованное тело int16 (W12 v2). Нет файла
## или битый заголовок — пусто (крейт возьмёт запасные значения конфига).
static func _grid_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		push_error("Weather: нет файла %s — значения из конфига" % path)
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < HEADER:
		push_error("Weather: %s — короче заголовка" % path)
		return PackedByteArray()
	var raw_size := int(bytes.decode_u32(48))
	var comp_size := int(bytes.decode_u32(52))
	if bytes.size() != HEADER + comp_size:
		push_error("Weather: %s — неверный размер (comp %d)" % [path, comp_size])
		return PackedByteArray()
	var body := bytes.slice(HEADER).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
	if body.size() != raw_size:
		push_error("Weather: %s — не распаковалась" % path)
		return PackedByteArray()
	var out := bytes.slice(0, HEADER)
	out.append_array(body)
	return out


# --- вызовы крейта ----------------------------------------------------------------------------


## Обычный дневной максимум месяца/дня, °C (ячейка ERA5 места с поправкой на высоту долины; NAN lat/lon —
## таблица конфига), в физическом диапазоне модели.
static func typical_max_c(
	month: int, day: int = 15, lat: float = NAN, lon: float = NAN, valley_msl_m: float = NAN
) -> float:
	var w := dp()
	return NAN if w == null else float(w.typical_max_c(month, day, lat, lon, valley_msl_m))


## Суточный ход по дневному максимуму и часу места: {temperature_c, cap_agl_m (INF — инверсия пробита),
## break, heat, soft, mech_k, sunrise_h, sunset_h, peak_h}. Нет расширения — {}.
static func diurnal_state(t_max: float, hour: float, ctx: Dictionary) -> Dictionary:
	var w := dp()
	if w == null:
		return {}
	var d := _dict(w.diurnal_state(t_max, hour, JSON.stringify(ctx)))
	if d.is_empty():
		return d
	d["break"] = d.get("brk", NAN)
	d.erase("brk")
	for k: String in d:
		if d[k] == null:
			d[k] = INF if k == "cap_agl_m" else NAN
	return d


static func sunrise_h(t_max: float, ctx: Dictionary) -> float:
	var w := dp()
	return NAN if w == null else float(w.sunrise_h(t_max, JSON.stringify(ctx)))


static func sunset_h(t_max: float, ctx: Dictionary) -> float:
	var w := dp()
	return NAN if w == null else float(w.sunset_h(t_max, JSON.stringify(ctx)))


## Поправки облачности ("clear" | "partly" | "overcast"): {cover, sky_heat}; нет расширения — {}.
static func sky_params(sky: String) -> Dictionary:
	var w := dp()
	if w == null:
		return {}
	var a: PackedFloat32Array = w.sky_params(sky)
	if a.size() < 2:
		return {}
	return {"cover": a[0], "sky_heat": a[1]}


## Прогноз {temperature_c, wind_speed_kmh, wind_from_deg, sky} в месте ctx → словарь погоды (ключи
## пресета + _derived). hour = NAN — «разгар дня», иначе суточный ход на этот час. {} — нет расширения.
static func derive(forecast: Dictionary, ctx: Dictionary, hour: float = NAN) -> Dictionary:
	var w := dp()
	if w == null:
		return {}
	var out := _dict(w.derive(JSON.stringify(forecast), JSON.stringify(ctx), hour))
	var dv: Variant = out.get("_derived")
	if dv is Dictionary and (dv as Dictionary).has("cap_agl_m") and dv["cap_agl_m"] == null:
		dv["cap_agl_m"] = INF  # инверсия пробита: JSON не знает бесконечности
	return out


## Температура воздуха на высоте z (м MSL) по суточному ходу, °C.
static func air_temp_c(hour: float, t_max: float, z: float, ctx: Dictionary) -> float:
	var w := dp()
	return NAN if w == null else float(w.air_temp_c(hour, t_max, z, JSON.stringify(ctx)))


## Температура воды на высоте z (м MSL) для даты (климат месяца назад), °C.
static func water_temp_c(month: int, day: int, z: float, ctx: Dictionary) -> float:
	var w := dp()
	return NAN if w == null else float(w.water_temp_c(month, day, z, JSON.stringify(ctx)))


## Температура на высоте alt_msl по погоде воздуха (словарь derive) и дате, °C.
static func temp_at_altitude(weather: Dictionary, alt_msl: float, month: int, day: int) -> float:
	var w := dp()
	return NAN if w == null else float(w.temp_at_altitude(JSON.stringify(weather), alt_msl, month, day))


## Сырая ячейка климата ERA5 без поправки на высоту: {td_c, td_sd_k, z_cell_m, t700_c, z700_m, tx_c,
## dtr_k, wr, trop_m, hcc, src:{hh1,hh2,hh5,hh6}}.
static func climate_cell(lat: float, lon: float, month: int, day: int = 15) -> Dictionary:
	var w := dp()
	return {} if w == null else _dict(w.climate_cell(lat, lon, month, day))


## Опорное место конфига без рельефа (тесты, меню): {month, day, lat, lon, utc_offset_h, valley_msl_m, mean_msl_m}.
static func reference_context() -> Dictionary:
	var w := dp()
	return {} if w == null else _dict(w.reference_context())


## Шаг пересчёта погоды по часу, ч.
static func quantum_h() -> float:
	var w := dp()
	return NAN if w == null else float(w.quantum_h())


## Час места через t секунд после start_hour при скорости времени speed, в границах world.time.
static func hour_at(start_hour: float, speed: float, t: float) -> float:
	var w := dp()
	if w == null:
		return start_hour
	if _hour_at_args == 4:
		return float(w.hour_at(start_hour, speed, t, 0.0))
	return float(w.hour_at(start_hour, speed, t))


## Перцентиль нижней доли проб высот рельефа (долина), м.
static func valley_of(samples: PackedFloat32Array, percentile: float) -> float:
	var w := dp()
	return NAN if w == null else float(w.valley_of(samples, percentile))


## Высоты рельефа вокруг (0, 0): долина (нижняя доля low_percentile) и средняя, м над морем. Пробы —
## сетка samples² в круге radius_m; пробы берёт игра (height_fn), долину считает крейт.
static func ground_context(
	height_fn: Callable, radius_m: float, samples: int, low_percentile: float
) -> Dictionary:
	var hs := PackedFloat32Array()
	var n := maxi(samples, 2)
	for j in n:
		for i in n:
			var u := float(i) / (n - 1) * 2.0 - 1.0
			var v := float(j) / (n - 1) * 2.0 - 1.0
			if u * u + v * v > 1.0:
				continue
			hs.append(float(height_fn.call(u * radius_m, v * radius_m)))
	if hs.is_empty():
		return {"valley_msl_m": 0.0, "mean_msl_m": 0.0}
	var sum := 0.0
	for h in hs:
		sum += h
	return {"valley_msl_m": valley_of(hs, low_percentile), "mean_msl_m": sum / hs.size()}


static func _dict(text: String) -> Dictionary:
	var v: Variant = JSON.parse_string(text)
	return v if v is Dictionary else {}
