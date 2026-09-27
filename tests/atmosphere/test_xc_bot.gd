extends TestCase
## Бот-маршрутник (FR-34a) на синтетике: плоская земля, статичные термики сеткой вдоль курса,
## без ветра и болтанки. Короткий маршрут 10 км (полный замер 30 км × 5 сидов —
## tools/atmosphere/xc_run.sh --synthetic, см. карточку docs/plan/atmosphere/01-xc-bot.md).

const XC_RUN := preload("res://tests/atmosphere/xc/xc_run.gd")


func test_xc_bot_synthetic_10km() -> void:
	var run: Node = XC_RUN.new()
	var res: Dictionary = (
		run
		. simulate(
			{
				"synthetic": "1",
				"seed": 1,
				"km": 10,
				"turbulence": 0,
				"lateral": 150,
				"start-agl": 700,
				"cloudbase-agl": 1000,
				"strength": 4,
			}
		)
	)
	run.free()
	check(res.get("end_reason", "") == "goal", "долетел до цели: %s" % res.get("end_reason", "?"))
	approx(float(res.distance_km), 10.0, 0.01, "дистанция, км")
	var syn: Dictionary = res.synthetic
	var near := int(syn.near_total)
	check(near >= 4, "термиков у линии курса: %d" % near)
	check(
		int(syn.near_found) >= ceili(0.9 * near),
		"найдено %d из %d термиков у линии курса (≥ 90 %%)" % [syn.near_found, near]
	)
	check(
		float(syn.climb_ratio) >= 0.65,
		(
			"средний набор %.2f м/с = %.0f %% от (ядро %.1f − снижение на вираже %.2f)"
			% [res.avg_climb_ms, float(syn.climb_ratio) * 100.0, syn.core_ms, syn.turn_sink_ms]
		)
	)
	check(int(res.thermals) >= 3, "набирал в термиках: %d" % res.thermals)
	check(float(res.glide_ratio_eff) > 8.0, "качество переходов %.1f" % res.glide_ratio_eff)


## «Идеальный пилот» (карточка 07, знает оси термиков) в болтанке: техника виража сама по себе
## набирает — набор ≥ 80 % от (ядро − снижение на вираже).
func test_xc_ideal_pilot_turbulence() -> void:
	var run: Node = XC_RUN.new()
	var res: Dictionary = (
		run
		. simulate(
			{
				"synthetic": "1",
				"seed": 1,
				"km": 10,
				"turbulence": 1,
				"ideal": "1",
				"start-agl": 700,
				"cloudbase-agl": 1000,
			}
		)
	)
	run.free()
	check(res.get("end_reason", "") == "goal", "долетел до цели: %s" % res.get("end_reason", "?"))
	var syn: Dictionary = res.synthetic
	check(
		float(syn.climb_ratio) >= 0.8,
		(
			"набор %.2f м/с = %.0f %% от (ядро %.1f − вираж %.2f)"
			% [res.avg_climb_ms, float(syn.climb_ratio) * 100.0, syn.core_ms, syn.turn_sink_ms]
		)
	)
