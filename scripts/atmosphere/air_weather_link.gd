class_name AirWeatherLink
extends RefCounted
## Погода крейта для воздуха (W12 п. 3, W4 v10): один DpWeather на конфиги атмосферы, сетки климата
## HH1/HH2/HH5/HH6 из data/climate (распаковка brotli — здесь, крейт принимает заголовок 64 байта +
## тело int16 без сжатия). Климат места (поле воздуха, ветер прогноза) крейт берёт у attach_weather;
## без неё — запасные таблицы weather_model.json, поэтому Atmosphere присоединяет погоду до load_place.
## Файла сетки нет или он битый — сетка не передаётся (запасные значения, как у прежнего ClimateGrid).

const HEADER := 64
const NAMES := ["hh1", "hh2", "hh5", "hh6"]

## Сетки, распакованные один раз на процесс: имя -> заголовок + тело (пусто — сетки нет).
static var _grid_bytes := {}


## DpWeather с конфигами (формат DpAir.configure: имя, текст, …) и сетками; null — нет класса или
## configure отказал.
static func make(configs: PackedStringArray) -> RefCounted:
	if not ClassDB.class_exists("DpWeather"):
		return null
	var w: RefCounted = ClassDB.instantiate("DpWeather")
	var names := PackedStringArray()
	var blobs: Array[PackedByteArray] = []
	for n: String in NAMES:
		var b := _grid(n)
		if not b.is_empty():
			names.append(n)
			blobs.append(b)
	var code: int = w.configure(configs, names, blobs)
	if code != 0:
		push_error("AirWeatherLink: DpWeather.configure = %d" % code)
		return null
	return w


static func _grid(grid_name: String) -> PackedByteArray:
	if _grid_bytes.has(grid_name):
		return _grid_bytes[grid_name]
	var out := PackedByteArray()
	var path: String = String(ClimateGrid.paths[grid_name])
	if FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.size() >= HEADER:
			var raw_size := int(bytes.decode_u32(48))
			var raw := bytes.slice(HEADER).decompress(raw_size, FileAccess.COMPRESSION_BROTLI)
			if raw.size() == raw_size:
				out = bytes.slice(0, HEADER)
				out.append_array(raw)
	if out.is_empty():
		push_error("AirWeatherLink: сетка %s (%s) не прочитана — запасные значения" % [grid_name, path])
	_grid_bytes[grid_name] = out
	return out
