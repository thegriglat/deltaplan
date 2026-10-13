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
}


## {green, dry, autumn, bare, rel}: свежесть весенней травы, добавка к сухости луга, окраска листвы
## (нарастает к осени и держится до листопада), листва опала — все 0…1; rel — дней от начала
## вегетации (для полей). look — секция scene_look (нет ключа — значение по умолчанию).
static func state(doy: float, lat_deg: float, alt_m: float, look: Dictionary = {}) -> Dictionary:
	if not bool(_p(look, "season_enabled")):
		return {"green": 0.0, "dry": 0.0, "autumn": 0.0, "bare": 0.0, "rel": 0.0}
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
	}


## Сезон породы: 1 — берёза/осина, 2 — лиственница (позже на season_larch_lag дней), как sl_season_sp.
static func state_species(
	kind: int, doy: float, lat_deg: float, alt_m: float, look: Dictionary = {}
) -> Dictionary:
	var lag := float(_p(look, "season_larch_lag")) if kind == 2 else 0.0
	return state(doy - lag, lat_deg, alt_m, look)


static func _p(look: Dictionary, key: String) -> Variant:
	return look.get(key, DEFAULTS[key])
