class_name LaunchOptions
extends RefCounted
## Аргументы командной строки главной сцены (после «--»):
##   --smoke               проверка сборки: автостарт + автопилот, 300 шагов физики, выход (код 0/1)
##   --autostart           сразу в полёт, без меню
##   --autopilot           синтетический пилот (разбег, полёт по курсу) — тесты и скриншоты
##   --screenshot=<путь>   снять кадр и выйти
##   --time=<с>            когда снимать: время симуляции полёта (в меню — реальное), с
##   --camera=<режим>      cockpit | chase | free
##   --pause | --settings | --about | --controls | --setup   открыть экран перед снимком
##   --wing=<id> --mass=<кг> --location=<id> --site=<id>
##   --temp=<°C>           прогноз: температура днём (FR-16)
##   --wind=<м/с>          прогноз: ветер у земли (старое into_site|preset — как --from)
##   --from=<град>|launch  откуда ветер: градусы (270 — с запада) или launch — в лоб старту
##   --sky=clear|partly|overcast  прогноз: облачность
##   --weather=<id>        бывший пресет → опорный прогноз (weather_model.json → legacy_presets)
##   --hour=<ч>            время старта по часам места (7.5 = 7:30), для кадров утро/вечер
##   --latlon=<lat>,<lon>  старт с точки на карте (рельеф грузится из сети)
##   --look=<рыскание>,<тангаж>   повернуть голову в кабине, ° (для скриншотов)
##   --glance              держать клавишу «взгляд на прибор»
##   --helmet=<вид>        каска в кабине: none | open | visor | visor_dark (поверх настройки;
##                         применяет SunGlare, configs/helmet.json)
##   --no-overlay          скрыть прибор в углу (InstrumentOverlay) перед скриншотом
##                         (чистый кадр мира — для фоновых картинок меню)
##   --autopilot-circle=<с>[,<крен>]  автопилот через <с> после отрыва кружит с креном (15°,
##                         + вправо) — кадры «оглянуться на старт» недалеко от склона
##   --look-at=<цель>      в кабине смотреть на цель (как «взгляд на прибор»): start — старт,
##                         bots — боты (в воздухе, а если никто не взлетел — все), bot<N> — бот N
##   --bots=<N>            другие пилоты в небе: сколько ботов (поверх настройки, 0 — никого)
##   --air-start[=<д>[,<h>]]  старт в воздухе: в <д> м от старта по его курсу, на <h> м над
##                         рельефом (по умолчанию 1000 и 300), на скорости трима, сразу в полёте;
##                         взлёта нет — касание будет посадкой, не «взлёт сорван». «Ещё раз» (R)
##                         — снова в воздухе. Для проверки полёта вдали от старта

var smoke := false
var autostart := false
var autopilot := false
var screenshot := ""
var time_s := 0.0
var camera := ""
var open_screen := ""  ## "pause", "settings", "about", "controls", "setup" или ""
var look := Vector2.ZERO
var glance := false  ## держать «взгляд на прибор» (скриншоты)
var no_overlay := false  ## скрыть InstrumentOverlay перед скриншотом (чистый кадр мира)
var helmet := ""  ## каска в кабине (--helmet=…), "" — из настроек (helmet.json → mode)
var overrides: Dictionary = {}
## Старт в воздухе (--air-start): дальность от старта по его курсу, м; < 0 — обычный старт.
var air_start_m := -1.0
## Старт в воздухе: высота над рельефом, м.
var air_start_agl_m := 300.0
## Другие пилоты в небе (--bots=N); < 0 — из настроек (bots.json → count).
var bots := -1
## Автопилот: кружить через столько секунд после отрыва (< 0 — держать курс) и с каким креном.
## Куда смотреть в кабине (--look-at): "start", "bots", "bot<N>" или "".
var look_at := ""
var autopilot_circle_s := -1.0
var autopilot_circle_bank := 15.0


static func parse(args: PackedStringArray) -> LaunchOptions:
	var o := LaunchOptions.new()
	for a in args:
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		var key := kv[0]
		var val := kv[1] if kv.size() > 1 else ""
		match key:
			"smoke":
				o.smoke = true
				o.autostart = true
				o.autopilot = true
			"autostart":
				o.autostart = true
			"autopilot":
				o.autopilot = true
			"glance":
				o.glance = true
			"no-overlay":
				o.no_overlay = true
			"screenshot":
				o.screenshot = val
			"time":
				o.time_s = float(val)
			"camera":
				o.camera = val
			"helmet":
				o.helmet = val
			"pause", "settings", "about", "controls", "setup":
				o.open_screen = key
			"look":
				var p := val.split(",")
				if p.size() == 2:
					o.look = Vector2(float(p[0]), float(p[1]))
			"bots":
				o.bots = int(val)
			"look-at":
				o.look_at = val
			"autopilot-circle":
				var c := val.split(",")
				o.autopilot_circle_s = float(c[0])
				if c.size() > 1:
					o.autopilot_circle_bank = float(c[1])
			"air-start":
				var p := val.split(",")
				o.air_start_m = float(p[0]) if val != "" else 1000.0
				if p.size() > 1:
					o.air_start_agl_m = float(p[1])
			"wing", "mass", "weather", "site", "wind", "latlon", "location", "hour", "temp", "from", "sky":
				o.overrides[key] = val
	if o.open_screen == "pause":
		o.autostart = true
	return o


## Наложить --wing/--mass/... на выбор меню.
func apply_to(s: FlightSettings) -> FlightSettings:
	var r := s.duplicate()
	if overrides.has("wing"):
		r.wing = "wings/" + String(overrides.wing)
	if overrides.has("mass"):
		r.pilot_mass_kg = float(overrides.mass)
	if overrides.has("weather"):
		r.set_legacy_weather(String(overrides.weather))
	if overrides.has("temp"):
		r.temperature_c = float(overrides.temp)
	if overrides.has("sky"):
		r.sky = String(overrides.sky)
	if overrides.has("site"):
		r.site_id = String(overrides.site)
		r.pick_lat = NAN
		r.pick_lon = NAN
	if overrides.has("location"):
		r.location_id = String(overrides.location)
		if not overrides.has("site"):
			r.site_id = ""
	if overrides.has("wind"):
		var wv := String(overrides.wind)
		if wv == "into_site" or wv == "preset":
			r.wind_into_launch = wv == "into_site"
		else:
			r.wind_speed_kmh = float(wv) * 3.6
	if overrides.has("from"):
		var fv := String(overrides.from)
		r.wind_into_launch = fv == "launch"
		if not r.wind_into_launch:
			r.wind_from_deg = fposmod(float(fv), 360.0)
	if overrides.has("hour"):
		r.start_hour = float(overrides.hour)
	if overrides.has("latlon"):
		var p := String(overrides.latlon).split(",")
		if p.size() == 2:
			r.pick_lat = float(p[0])
			r.pick_lon = float(p[1])
	return r
