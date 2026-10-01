extends TestCase
## Установившееся планирование совпадает с полярой крыла (FR-1, FR-2).

const Sim := preload("res://tests/flight/flight_sim.gd")
## Качество крыльев группы по docs/plan/wings_lineup.md §2 (с запасом ±0,3).
const GROUP_GLIDE := {
	"soviet": Vector2(6.0, 8.5),
	"trainer": Vector2(7.0, 9.0),
	"kingpost": Vector2(10.5, 13.0),
	"topless": Vector2(15.0, 16.0),
}
## Крылья, чья поляра (К4: подобием от базы, качество = базе) взята из другой группы, чем группа меню:
## Icaro MastR — по сути безмачтовый Laminar с небольшой мачтой; в меню — группа kingpost (решение
## пользователя, шлюз 1), поляра — от combat, поэтому класс качества — как у topless.
const GLIDE_CLASS_OVERRIDE := {"icaro_mastr": "topless"}


## Все крылья из configs/wings: id ("training" …).
static func wings() -> Array[String]:
	var out: Array[String] = []
	for p in Config.list_configs("wings"):
		out.append(String(p).get_file())
	return out


## Снижение по точкам поляры из конфига (линейно по скорости), м/с.
static func polar_sink(wing: Dictionary, v_kmh: float) -> float:
	var pts: Array = wing.polar.points_kmh_ms
	for i in range(1, pts.size()):
		if v_kmh <= float(pts[i][0]):
			var t := (v_kmh - float(pts[i - 1][0])) / (float(pts[i][0]) - float(pts[i - 1][0]))
			return lerpf(float(pts[i - 1][1]), float(pts[i][1]), t)
	return float(pts[pts.size() - 1][1])


## Перебор скоростей от сваливания: {min_sink, min_sink_v, best_ld, best_ld_v} (км/ч).
static func sweep(m: FlightModel) -> Dictionary:
	var r := {"min_sink": 99.0, "min_sink_v": 0.0, "best_ld": 0.0, "best_ld_v": 0.0}
	var v := m.stall_speed()
	while v < Units.kmh(100.0):
		var g := m.steady_glide(v)
		if g.y < r.min_sink:
			r.min_sink = g.y
			r.min_sink_v = Units.to_kmh(v)
		if v / g.y > r.best_ld:
			r.best_ld = v / g.y
			r.best_ld_v = Units.to_kmh(v)
		v += 0.05
	return r


func test_simulated_glide_matches_polar() -> void:
	for w in wings():
		var wing: Dictionary = Config.get_config("wings/" + w)
		var m := Sim.make(w)
		for p in [0.25, 0.0, -0.2, -0.45, -0.8]:
			var r: Vector2 = Sim.settle(m, p)
			var vk := Units.to_kmh(r.x)
			var expect := polar_sink(wing, vk)
			approx(
				r.y,
				expect,
				maxf(0.05, expect * 0.04),
				"%s трапеция %.2f, V=%.1f км/ч: снижение" % [w, p, vk]
			)
			approx(
				r.y,
				m.steady_glide(r.x).y,
				0.02,
				"%s трапеция %.2f: сходимость к steady_glide" % [w, p]
			)


func test_trim_speed() -> void:
	for w in wings():
		var wing: Dictionary = Config.get_config("wings/" + w)
		var r: Vector2 = Sim.settle(Sim.make(w), 0.0)
		approx(Units.to_kmh(r.x), float(wing.trim_speed_kmh), 0.7, w + ": скорость трима, км/ч")


func test_reference_points() -> void:
	for w in wings():
		var wing: Dictionary = Config.get_config("wings/" + w)
		var ref: Dictionary = wing.reference
		var m := Sim.make(w)
		var s := sweep(m)
		approx(
			Units.to_kmh(m.stall_speed()), float(ref.stall_speed_kmh), 0.5, w + ": сваливание, км/ч"
		)
		approx(s.min_sink, float(ref.min_sink_ms), 0.03, w + ": мин. снижение, м/с")
		approx(
			s.min_sink_v, float(ref.min_sink_speed_kmh), 3.0, w + ": скорость мин. снижения, км/ч"
		)
		approx(s.best_ld, float(ref.best_glide), 0.3, w + ": макс. качество")
		approx(
			s.best_ld_v, float(ref.best_glide_speed_kmh), 3.0, w + ": скорость макс. качества, км/ч"
		)
		if ref.has("sink_at_80_kmh_ms"):
			approx(
				m.steady_glide(Units.kmh(80.0)).y,
				float(ref.sink_at_80_kmh_ms),
				0.1,
				w + ": снижение на 80 км/ч"
			)


func test_fr1_sport_anchors() -> void:
	# FR-1: сваливание ~27, мин. снижение ~0,9 @32 (принято 0,82 @33–36, см. questions.md),
	# качество ~15 @42, ~3 м/с @80
	var m := Sim.make("sport")
	var s := sweep(m)
	approx(Units.to_kmh(m.stall_speed()), 27.0, 1.0, "сваливание")
	check(s.min_sink >= 0.75 and s.min_sink <= 0.95, "мин. снижение ~0,9: %.2f" % s.min_sink)
	approx(s.min_sink_v, 33.0, 4.0, "скорость мин. снижения")
	approx(s.best_ld, 15.0, 0.5, "макс. качество")
	approx(s.best_ld_v, 43.0, 4.0, "скорость макс. качества")
	approx(m.steady_glide(Units.kmh(80.0)).y, 3.0, 0.15, "снижение на 80 км/ч")


func test_wing_classes_glide() -> void:
	for w in wings():
		var r: Vector2 = GROUP_GLIDE[GLIDE_CLASS_OVERRIDE.get(w, Config.value("wings/" + w, "group"))]
		var ld: float = sweep(Sim.make(w)).best_ld
		check(
			ld >= r.x - 0.3 and ld <= r.y + 0.3,
			"%s: качество класса (FR-2) %.1f в %.1f–%.1f" % [w, ld, r.x, r.y]
		)


func test_density_altitude() -> void:
	# на высоте воздух реже: те же углы атаки → скорости выше как √(ρ0/ρ)
	var m := Sim.make("sport", 0.0, {"air_density": {"altitude_dependent": true}})
	m.reset_in_air(Vector3(0, 2000, 0), 0.0)
	var ratio := sqrt(m.air_density(0.0) / m.air_density(2000.0))
	approx(m.trim_speed() / Units.kmh(36.0), ratio, 0.01, "трим на 2000 м")
	check(ratio > 1.08 and ratio < 1.12, "плотность на 2000 м ≈ 0,82 от уровня моря")
