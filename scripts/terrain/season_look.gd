class_name SeasonLook
extends RefCounted
## Сезон по дате полёта, широте и высоте — CPU-зеркало `sl_season_x` из scene_look.gdshaderinc
## (контракт scene-look SL-К2; формулы правятся вместе). Тесты сверяют инварианты и числа.
##
## Фенология — закон Хопкинса (A.D. Hopkins, 1918, «Periodical events and natural law as guides to
## agricultural research and practice»): ≈ 4 дня на 1° широты к полюсу и на 400 футов (122 м) высоты;
## весна позже, осень раньше. Опорные даты на 50° с. ш., 0 м (configs/world.json → scene_look.season_*):
## начало вегетации/распускание берёзы ≈ 10 апреля (Киев ≈ 12–15 апреля, Екатеринбург ≈ 7–10 мая),
## середина окраски берёзы ≈ 7 октября (Киев ≈ 5–15 октября, Москва ≈ 20–25 сентября).
## Осень слабее зависит от высоты, чем весна (season_autumn_alt_k = 0,5 — допущение).
## Южное полушарие — дата сдвинута на полгода; |φ| < ~23° — сезона нет (всё 0).
## Свежий снег (SL-10, К2 v2): сезонная снеговая линия по широте и дате (snow_line), snow_fresh —
## плавный переход выше неё; зеркало sl_snow_line/sl_snow_fresh в scene_look.gdshaderinc.

const DEFAULTS := {
	"season_enabled": true,
	"season_hopkins": [4.0, 122.0],
	"season_autumn_alt_k": 0.5,
	"season_lat_ref": 50.0,
	"season_dates": [100.0, 280.0],
	"season_fresh": [12.0, 40.0, 90.0],
	"season_dry_days": [75.0, 135.0],
	"season_dry_amount": 0.35,
	"season_winter_dry": 0.4,
	"season_leaf_days": [-15.0, 10.0, 18.0, 38.0],
	"season_leafout_days": [2.0, 16.0],
	"season_larch_lag": 8.0,
	"snow_enabled": true,
	"snow_lats": [10.0, 46.0, 60.0, 70.0],
	"snow_line_summer": [4900.0, 3000.0, 1500.0, 500.0],
	"snow_line_winter_drop": [0.0, 600.0, 800.0, 400.0],
	"snow_min_day": 75.0,
	"snow_fresh_band_m": 300.0,
}


## {green, dry, autumn, bare, rel}: свежесть весенней травы, добавка к сухости луга, окраска листвы
## (нарастает к осени и держится до листопада), листва опала — все 0…1; rel — дней от начала
## вегетации (для полей). look — секция scene_look (нет ключа — значение по умолчанию).
static func state(doy: float, lat_deg: float, alt_m: float, look: Dictionary = {}) -> Dictionary:
	var line := snow_line(doy, lat_deg, look)
	var snow := 0.0
	if bool(_p(look, "snow_enabled")):
		snow = smoothstep(line, line + float(_p(look, "snow_fresh_band_m")), alt_m)
	if not bool(_p(look, "season_enabled")):
		return {
			"green": 0.0, "dry": 0.0, "autumn": 0.0, "bare": 0.0, "rel": 0.0,
			"snow_fresh": snow, "snow_line_m": line,
		}
	var hop: Array = _p(look, "season_hopkins")
	var dates: Array = _p(look, "season_dates")
	var fresh: Array = _p(look, "season_fresh")
	var dd: Array = _p(look, "season_dry_days")
	var lf: Array = _p(look, "season_leaf_days")
	var lo: Array = _p(look, "season_leafout_days")
	var al := absf(lat_deg)
	var d := doy + (182.5 if lat_deg < 0.0 else 0.0)
	d -= 365.0 * floorf(d / 365.0)
	var sh_lat := float(hop[0]) * clampf(al - float(_p(look, "season_lat_ref")), -15.0, 20.0)
	var sh_alt := float(hop[0]) * maxf(alt_m, 0.0) / float(hop[1])
	var spring := float(dates[0]) + clampf(sh_lat + sh_alt, -60.0, 90.0)
	var fall := clampf(
		float(dates[1]) - sh_lat - float(_p(look, "season_autumn_alt_k")) * sh_alt, 200.0, 330.0
	)
	var green := (
		smoothstep(spring, spring + float(fresh[0]), d)
		* (1.0 - smoothstep(spring + float(fresh[1]), spring + float(fresh[2]), d))
	)
	var dsum := smoothstep(spring + float(dd[0]), spring + float(dd[1]), d)
	var autumn := smoothstep(fall + float(lf[0]), fall + float(lf[1]), d)
	var bare := maxf(
		smoothstep(fall + float(lf[2]), fall + float(lf[3]), d),
		1.0 - smoothstep(spring + float(lo[0]), spring + float(lo[1]), d)
	)
	var dorm := 1.0 - smoothstep(spring - 10.0, spring + 10.0, d)
	var dry := maxf(
		float(_p(look, "season_dry_amount")) * dsum,
		float(_p(look, "season_winter_dry")) * maxf(dorm, bare)
	)
	var trop := smoothstep(20.0, 26.0, al)
	return {
		"green": trop * green,
		"dry": trop * dry,
		"autumn": trop * autumn,
		"bare": trop * bare,
		"rel": d - spring,
		"snow_fresh": snow,
		"snow_line_m": line,
	}


## Высота сезонной снеговой линии, м (зеркало sl_snow_line): летняя по широте (кусочно-линейно по
## snow_lats) минус зимнее опускание × сезонный косинус с минимумом в snow_min_day.
static func snow_line(doy: float, lat_deg: float, look: Dictionary = {}) -> float:
	var d := doy + (182.5 if lat_deg < 0.0 else 0.0)
	d -= 365.0 * floorf(d / 365.0)
	var w := 0.5 * (1.0 + cos(TAU * (d - float(_p(look, "snow_min_day"))) / 365.0))
	var al := absf(lat_deg)
	return (
		_snow_interp(_p(look, "snow_line_summer"), al, look)
		- _snow_interp(_p(look, "snow_line_winter_drop"), al, look) * w
	)


static func _snow_interp(v: Array, al: float, look: Dictionary) -> float:
	var lats: Array = _p(look, "snow_lats")
	var t := clampf(al, float(lats[0]), float(lats[3]))
	for i in 3:
		if t < float(lats[i + 1]) or i == 2:
			var k := clampf((t - float(lats[i])) / (float(lats[i + 1]) - float(lats[i])), 0.0, 1.0)
			return lerpf(float(v[i]), float(v[i + 1]), k)
	return float(v[3])


## Сезон породы: 1 — берёза/осина, 2 — лиственница (позже на season_larch_lag дней), как sl_season_sp.
static func state_species(
	kind: int, doy: float, lat_deg: float, alt_m: float, look: Dictionary = {}
) -> Dictionary:
	var lag := float(_p(look, "season_larch_lag")) if kind == 2 else 0.0
	return state(doy - lag, lat_deg, alt_m, look)


## Подготовка для шейдера (uniform sl_season_pre): всё, что зависит только от даты и широты —
## Vector4(день берёзы, день лиственницы, сдвиг Хопкинса по широте, множитель тропиков); в пикселе
## остаётся сдвиг по высоте. Дни — как в state(): южное полушарие +182,5, приведены в 0…365.
static func pre(doy: float, lat_deg: float, look: Dictionary = {}) -> Vector4:
	var al := absf(lat_deg)
	var shift := 182.5 if lat_deg < 0.0 else 0.0
	var hop: Array = _p(look, "season_hopkins")
	var days: Array[float] = []
	for lag in [0.0, float(_p(look, "season_larch_lag"))]:
		var d: float = doy - lag + shift
		d -= 365.0 * floorf(d / 365.0)
		days.append(d)
	return Vector4(
		days[0],
		days[1],
		float(hop[0]) * clampf(al - float(_p(look, "season_lat_ref")), -15.0, 20.0),
		smoothstep(20.0, 26.0, al)
	)


## Подготовка снега для шейдера (uniform sl_snow_pre): Vector4(высота снеговой линии, м, 0, 0, 0).
static func snow_pre(doy: float, lat_deg: float, look: Dictionary = {}) -> Vector4:
	return Vector4(snow_line(doy, lat_deg, look), 0.0, 0.0, 0.0)


## Пересчитать sl_season_pre и sl_snow_pre материала по его текущим sl_doy, sl_lat_deg и параметрам сезона.
static func apply_pre(m: ShaderMaterial) -> void:
	var look := {}
	for k in [
		"season_hopkins", "season_lat_ref", "season_larch_lag", "snow_lats", "snow_line_summer",
		"snow_line_winter_drop", "snow_min_day",
	]:
		var v: Variant = m.get_shader_parameter("sl_" + k)
		if v is Vector2:
			v = [v.x, v.y]
		elif v is Vector4:
			v = [v.x, v.y, v.z, v.w]
		if v != null:
			look[k] = v
	var doy: Variant = m.get_shader_parameter("sl_doy")
	var lat: Variant = m.get_shader_parameter("sl_lat_deg")
	var d0 := 196.0 if doy == null else float(doy)
	var l0 := 0.0 if lat == null else float(lat)
	m.set_shader_parameter("sl_season_pre", pre(d0, l0, look))
	m.set_shader_parameter("sl_snow_pre", snow_pre(d0, l0, look))


static func _p(look: Dictionary, key: String) -> Variant:
	return look.get(key, DEFAULTS[key])
