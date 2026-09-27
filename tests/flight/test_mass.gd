extends TestCase
## Масса пилота (FR-3): скорости ∝ √(M/M_эталон), качество то же, реакция медленнее.

const Sim := preload("res://tests/flight/flight_sim.gd")


func test_speeds_scale_with_sqrt_mass() -> void:
	for w in ["training", "kingpost", "sport"]:
		var wing: Dictionary = Config.get_config("wings/" + w)
		var light := Sim.make(w, float(wing.pilot_mass_min_kg))
		var heavy := Sim.make(w, float(wing.pilot_mass_max_kg))
		var k := sqrt(heavy.mass / light.mass)
		var rl: Vector2 = Sim.settle(light, 0.0)
		var rh: Vector2 = Sim.settle(heavy, 0.0)
		approx(rh.x / rl.x, k, 0.01, w + ": трим ∝ √M")
		approx(rh.y / rl.y, k, 0.02, w + ": снижение ∝ √M")
		approx(heavy.stall_speed() / light.stall_speed(), k, 0.001, w + ": сваливание ∝ √M")


func test_best_glide_unchanged_by_mass() -> void:
	var TP := preload("res://tests/flight/test_polar.gd")
	var wing: Dictionary = Config.get_config("wings/sport")
	var sl: Dictionary = TP.sweep(Sim.make("sport", float(wing.pilot_mass_min_kg)))
	var sh: Dictionary = TP.sweep(Sim.make("sport", float(wing.pilot_mass_max_kg)))
	approx(sh.best_ld, sl.best_ld, 0.05, "качество не зависит от массы")
	check(sh.best_ld_v > sl.best_ld_v + 3.0, "у тяжёлого пилота скорость лучшего качества выше")


func test_heavier_pilot_rolls_slower() -> void:
	var TR := preload("res://tests/flight/test_roll.gd")
	var wing: Dictionary = Config.get_config("wings/sport")
	var tl: float = TR.reversal_time(Sim.make("sport", float(wing.pilot_mass_min_kg)))
	var th: float = TR.reversal_time(Sim.make("sport", float(wing.pilot_mass_max_kg)))
	check(th > tl, "тяжёлый перекладывается дольше (инерция): %.2f vs %.2f" % [th, tl])
	check(th - tl < 0.5, "но в разумных пределах")


func test_clamp_to_wing_range() -> void:
	var wing: Dictionary = Config.get_config("wings/sport")
	approx(FlightModel.clamp_pilot_mass(wing, 40.0), float(wing.pilot_mass_min_kg), 0.0, "мин")
	approx(FlightModel.clamp_pilot_mass(wing, 200.0), float(wing.pilot_mass_max_kg), 0.0, "макс")
