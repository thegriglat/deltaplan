extends RefCounted
## Фикстура TI-К2: копия конфига altai с ключом weather у старта sinyukha_east (ongudai-подобный набор:
## ветер 6 м/с с 270°, 12:00, 15 июля, переменная облачность, 24 °C). Подмена — в кеше Config, файлы
## configs/locations/ не трогаются; restore() возвращает исходный конфиг.

const LOC := "altai"
const SITE := "sinyukha_east"
const WEATHER := {
	"wind_from_deg": 270, "wind_speed_ms": 6.0, "start_hour": 12.0, "month": 7, "day": 15,
	"sky": "partly", "temperature_c": 24.0,
}

var _orig: Dictionary


func install(weather: Variant = WEATHER) -> void:
	_orig = Config.get_config("locations/" + LOC)
	var cfg: Dictionary = _orig.duplicate(true)
	for st: Dictionary in cfg.start_sites:
		if String(st.id) == SITE:
			if weather == null:
				st.erase("weather")
			else:
				st["weather"] = weather
	Config._cache["locations/" + LOC] = cfg


func restore() -> void:
	Config._cache["locations/" + LOC] = _orig


## Настройки, у которых погода отличается от набора; старт — с набором или без (site).
static func settings(site: String = SITE) -> FlightSettings:
	var s := FlightSettings.defaults()
	s.location_id = LOC
	s.site_id = site
	s.temperature_c = 5.0
	s.wind_speed_kmh = 30.0
	s.wind_into_launch = true
	s.wind_from_deg = 90.0
	s.sky = "overcast"
	s.start_hour = 20.0
	s.month = 3
	s.day = 2
	return s
