extends TestCase
## Крылья соответствуют паспортам (WPC-4, docs/plan/wing-physics-check.md; паспорт — эталон).
## Установившийся полёт FlightModel при эталонной массе крыла, ρ = 1,225 (как flight_sim.gd):
## сваливание — FlightModel.stall_speed() (CL_max первой точки поляры, как WPC-1); трим и «на себя» —
## установившийся полёт с трапецией 0 и −1; мин. снижение, его скорость, качество и его скорость —
## перебор FlightModel.steady_glide (то, к чему сходится полёт; совпадение с установившимся полётом
## проверяет test_polar.gd). Цели — tests/flight/fixtures/wing_passport_targets.json (генерирует
## tools/research/data/wing_passports/fit_passports.py из паспортов, приведение к массе как в WPC-1).
## Допуски: сваливание, трим, «на себя» ±7 %; мин. снижение и его скорость, качество и его скорость ±10 %.
## Исключения — поле exception у цели в фикстуре (с причиной); сейчас их нет.

const Sim := preload("res://tests/flight/flight_sim.gd")
const TP := preload("res://tests/flight/test_polar.gd")
const FIXTURE := "res://tests/flight/fixtures/wing_passport_targets.json"
## Ветер у старта, против которого мягкое крыло на триме должно идти вперёд (WPC-1, решение шлюза 1).
const HEADWIND_MS := 6.0


static func fixture() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))


func test_fixture_covers_passport_wings() -> void:
	var fx := fixture()
	check(fx != null and fx.has("wings"), "фикстура читается: " + FIXTURE)
	var ws: Dictionary = fx.wings
	check(ws.size() >= 40, "крыльев с паспортными числами: %d" % ws.size())
	for w: String in ws:
		check(TP.wings().has(w), "%s: есть configs/wings/%s.json" % [w, w])
		var m := Sim.make(w)
		approx(m.mass, float(ws[w].mass_kg), 0.05, w + ": эталонная масса фикстуры = конфигу")


func test_model_matches_passport() -> void:
	var fx := fixture()
	var exceptions: PackedStringArray = []
	for w: String in fx.wings:
		var tg: Dictionary = fx.wings[w].targets
		var m := Sim.make(w)
		var got := {"stall": Units.to_kmh(m.stall_speed())}
		if tg.has("trim"):
			got.trim = Units.to_kmh(Sim.settle(m, 0.0).x)
		if tg.has("full_pull"):
			got.full_pull = Units.to_kmh(Sim.settle(m, -1.0).x)
		if tg.has("min_sink") or tg.has("min_sink_speed") or tg.has("best_glide") \
				or tg.has("best_glide_speed"):
			var s := TP.sweep(m)
			got.min_sink = s.min_sink
			got.min_sink_speed = s.min_sink_v
			got.best_glide = s.best_ld
			got.best_glide_speed = s.best_ld_v
		for q: String in tg:
			var t: Dictionary = tg[q]
			var d := (float(got[q]) / float(t.value) - 1.0) * 100.0
			if t.has("exception"):
				exceptions.append("%s.%s %+.1f %%: %s" % [w, q, d, t.exception])
				continue
			check(
				absf(d) <= float(t.tol_pct),
				"%s: %s модель %.3f, паспорт %.3f (%+.1f %%, допуск ±%.0f %%; %s)"
				% [w, q, got[q], t.value, d, t.tol_pct, t.src]
			)
	for e in exceptions:
		print("         исключение: " + e)


## Против 6 м/с у старта на триме каждое крыло идёт вперёд относительно земли (V·cosγ − 6 > 0).
func test_trim_penetrates_6ms() -> void:
	for w in TP.wings():
		var r: Vector2 = Sim.settle(Sim.make(w), 0.0)
		var gs := r.x * sqrt(maxf(1.0 - pow(r.y / r.x, 2.0), 0.0)) - HEADWIND_MS
		check(gs > 0.0, "%s: путевая на триме против %.0f м/с = %.2f м/с" % [w, HEADWIND_MS, gs])


## Инварианты К1 v1 у крыльев с паспортом: сваливание < трим < на себя, от себя < трим.
func test_speed_order() -> void:
	var fx := fixture()
	for w: String in fx.wings:
		var cfg := Config.get_config("wings/" + w)
		var stall := float(cfg.polar.points_kmh_ms[0][0])
		var trim := float(cfg.trim_speed_kmh)
		check(stall < trim and trim < float(cfg.full_pull_speed_kmh), w + ": сваливание < трим < на себя")
		check(float(cfg.full_push_speed_kmh) < trim, w + ": от себя < трим")
