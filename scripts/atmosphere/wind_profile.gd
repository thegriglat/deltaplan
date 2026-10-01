class_name WindProfile
extends RefCounted
## Профиль ветра притока по высоте — одна функция для решателя (AirPlace.domain_case,
## AirWindowCase → AirCase.p.alpha, p.max_profile) и аналитического ветра WindModel (Atmosphere),
## контракт C2 v4.
## Эталон — tools/research/air3d/wind_prof.py (те же таблицы и правила).
##
## U(z) = U10·(z/10)^α до z_sat, выше — постоянный: max_profile = U(z_sat)/U10 = (z_sat/10)^α.
##
## α — по устойчивости: α = α_N·r(класс), класс Паскуилла–Тёрнера по скорости на 10 м и индексу
## радиации NRI (Turner 1964, «A worksheet for estimating the stability class»; таблица и правила
## NRI — EPA-454/R-99-005, табл. 6-4, 6-5; Pasquill 1961), r — отношение показателя степенного
## профиля класса к классу D по Irwin 1979 (Atmos. Environ. 13, «сельская местность»: A 0,07,
## B 0,07, C 0,10, D 0,15, E 0,35, F 0,55). α_N — atmosphere.json → wind.shear_exponent_neutral
## (0,24 — совместная калибровка Б1, Askervein; эффективный показатель до z_sat, а не лог-профиль).
## Не из местного z0: зависимость α от z0 (Counihan) с калибровкой не согласуется (решение К2).
##
## NRI: сплошная облачность (1,0) — 0; ночь (час до заката — час после восхода; здесь — солнце ниже
## NIGHT_SUN_DEG) — облачность ≤ 0,4 → −2, иначе −1; день — класс инсоляции по высоте солнца
## (> 60° — 4, 35–60° — 3, 15–35° — 2, ≤ 15° — 1), облачность > 0,5 — минус 2 (нижняя граница
## облаков ниже 7000 футов: кучевые и слоистые игры), не ниже 1.
##
## z_sat = wind.z_sat_frac·h, h = 0,3·u*/f — толщина нейтрального слоя решателя
## (AirCase.NEUTRAL_BL_K), u* = κ·U10/ln(10/z0) — то же правило, что tools/research/cases/rules.py
## (C10 v3), проверено данными притока Askervein и Perdigão (docs/plan/air_model_b1.md). Для
## устойчивых E, F h = min(0,3·u*/f, 0,4·√(u*·L/f)), L — Golder 1972 по классу и z0 (C2 v5).

const CLASSES := "ABCDEF"
## Нижний предел U10 для z_sat, м/с: порог трогания чашечного анемометра ≤ 0,5 м/с
## (EPA-454/R-99-005); в штиль профиль решателю не нужен, здесь — только без деления на ноль.
const U10_MIN := 0.5
## Высота солнца, ниже которой «ночь» Тёрнера (час после восхода / до заката): в июле на 50° с. ш.
## (Онгудай) — ≈ 9° и ≈ 7° (SunClock.solar_position).
const NIGHT_SUN_DEG := 8.0
## Показатели степенного профиля A–F, Irwin 1979 (сельская местность).
const IRWIN_RURAL := [0.07, 0.07, 0.10, 0.15, 0.35, 0.55]
## Тёрнер: строки — скорость на 10 м в узлах (0–1, 2–3, 4–5, 6, 7, 8–9, 10, 11, ≥ 12), столбцы —
## NRI 4, 3, 2, 1, 0, −1, −2; значения — класс 1 (A) … 7 (G); G считается F (у Irwin — A–F).
const TURNER := [
	[1, 1, 2, 3, 4, 6, 7],
	[1, 2, 2, 3, 4, 6, 7],
	[1, 2, 3, 4, 4, 5, 6],
	[2, 2, 3, 4, 4, 5, 6],
	[2, 2, 3, 4, 4, 4, 5],
	[2, 3, 3, 4, 4, 4, 5],
	[3, 3, 4, 4, 4, 4, 5],
	[3, 3, 4, 4, 4, 4, 4],
	[3, 4, 4, 4, 4, 4, 4],
]
## Границы строк таблицы, узлы (скорость округляется до целых узлов).
const KT_EDGES := [1.5, 3.5, 5.5, 6.5, 7.5, 9.5, 10.5, 11.5]
const MS_PER_KT := 0.514444
## Нейтральный класс.
const D := 3
## Golder 1972: (a, b) в 1/L = a + b·lg z0, 1/м, классы A–F (Myrup & Ranzieri 1976;
## Seinfeld & Pandis, «Atmospheric Chemistry and Physics», гл. 16) — длина Обухова для толщины
## устойчивого слоя.
const GOLDER := [
	[-0.096, 0.029],
	[-0.037, 0.029],
	[-0.002, 0.018],
	[0.0, 0.0],
	[0.004, -0.018],
	[0.035, -0.036],
]

static var _alpha_n := NAN
static var _z_sat_frac := NAN


## α_N — показатель нейтрального класса D (wind.shear_exponent_neutral).
static func alpha_n() -> float:
	if is_nan(_alpha_n):
		_alpha_n = float(Config.value("atmosphere", "wind.shear_exponent_neutral", 0.24))
	return _alpha_n


static func z_sat_frac() -> float:
	if is_nan(_z_sat_frac):
		_z_sat_frac = float(Config.value("atmosphere", "wind.z_sat_frac", 0.3))
	return _z_sat_frac


## Индекс радиации Тёрнера: высота солнца (°) и облачность 0..1 → −2..4.
static func net_radiation_index(sun_elev_deg: float, cover: float) -> int:
	if cover >= 1.0:
		return 0
	if sun_elev_deg < NIGHT_SUN_DEG:
		return -2 if cover <= 0.4 else -1
	var ic := 1
	if sun_elev_deg > 60.0:
		ic = 4
	elif sun_elev_deg > 35.0:
		ic = 3
	elif sun_elev_deg > 15.0:
		ic = 2
	if cover > 0.5:
		ic = maxi(ic - 2, 1)
	return ic


## Класс устойчивости 0..5 (A..F) по ветру на 10 м (м/с), высоте солнца (°) и облачности 0..1.
static func stability_class(u10: float, sun_elev_deg: float, cover: float) -> int:
	var kt := maxf(u10, 0.0) / MS_PER_KT
	var row := 0
	for e: float in KT_EDGES:
		if kt >= e:
			row += 1
	var nri := net_radiation_index(sun_elev_deg, cover)
	return mini(int(TURNER[row][4 - nri]), 6) - 1


## Показатель степенного профиля по устойчивости.
static func alpha(u10: float, sun_elev_deg: float, cover: float) -> float:
	var r := float(IRWIN_RURAL[stability_class(u10, sun_elev_deg, cover)]) / float(IRWIN_RURAL[3])
	return alpha_n() * r


## 1/L (длина Обухова) по классу 0..5 и z0 — Golder 1972: 1/L = a + b·lg z0.
static func obukhov_inv(cls: int, z0: float) -> float:
	var ab: Array = GOLDER[cls]
	return float(ab[0]) + float(ab[1]) * log(z0) / log(10.0)


## Толщина слоя для насыщения, м: 0,3·u*/f; для устойчивых E, F — не больше 0,4·√(u*·L/f)
## (Зилитинкевич; как AirCase._closure и air._bl_depth), L — Golder 1972 по классу и z0 (C2 v5).
static func bl_depth(u10: float, z0: float, f_cor: float, cls := D) -> float:
	var us := AirCase.KAPPA * maxf(u10, U10_MIN) / log(10.0 / z0)
	var h := AirCase.NEUTRAL_BL_K * us / f_cor
	if cls > D:
		h = minf(h, 0.4 * sqrt(us / obukhov_inv(cls, z0) / f_cor))
	return h


## Высота насыщения профиля, м: z_sat_frac·h.
static func z_sat(u10: float, z0: float, f_cor: float, cls := D) -> float:
	return z_sat_frac() * bl_depth(u10, z0, f_cor, cls)


## U(z_sat)/U10 = (z_sat/10)^α; cls — класс устойчивости (stability_class), по умолчанию D.
static func max_profile(alpha_v: float, u10: float, z0: float, f_cor: float, cls := D) -> float:
	return pow(z_sat(u10, z0, f_cor, cls) / 10.0, alpha_v)


## Высота солнца (°) в час hour места ctx {month, day, lat, lon, utc_offset_h} (SunClock, без
## запаздывания прогрева: инсоляция в момент).
static func sun_elevation(ctx: Dictionary, hour: float) -> float:
	var doy := SunClock.day_of_year(int(ctx.month), int(ctx.day))
	var sp := SunClock.solar_position(
		float(ctx.lat), float(ctx.lon), doy, hour, float(ctx.get("utc_offset_h", NAN))
	)
	return sp.y


## α и max_profile случая решателя на час (AirPlace.domain_case, AirWindowCase): ветер случая,
## солнце места, облачность cover (WeatherModel.sky_params(sky).cover); z0 и f — из c.p.
static func apply_to_case(c: AirCase, ctx: Dictionary, hour: float, cover: float) -> void:
	var sun := sun_elevation(ctx, hour)
	var k := stability_class(c.u10, sun, cover)
	var a := alpha(c.u10, sun, cover)
	c.p.alpha = a
	c.p.max_profile = max_profile(a, c.u10, float(c.p.z0), float(c.p.f_cor), k)
