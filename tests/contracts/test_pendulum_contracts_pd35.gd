extends TestCase
## Ключи PD-35 (configs/pendulum.json) и оценка касания «Маятника» (PendulumTouchdown): поля result —
## как у LandingJudge.evaluate (PD-К1) плюс touchdown, runout_m, steps; пороги — по горизонтальной
## «встал / пробежал / жёстко», остальное — LandingJudge. Контракт правит координатор (PD-К1, PD-К2).


func test_config_keys() -> void:
	var c: Dictionary = Config.get_config("pendulum")
	var st: Dictionary = c.strips
	for k in ["stall_cd90_sweep_norm", "sweep_alpha_exact"]:
		check(st.get(k) is bool, "strips.%s — bool" % k)
		check(st.has(k + "_doc"), "strips.%s_doc есть" % k)
	check(c.get("stall_cp_reverse") is bool, "stall_cp_reverse — bool")
	check(c.has("stall_cp_reverse_doc"), "stall_cp_reverse_doc есть")
	check(not c.arms.has("flare_shift_x_push_m"), "arms.flare_shift_x_push_m убран: ход у земли — по досягаемости")
	check(bool(c.arms.flare_reach.enabled), "arms.flare_reach.enabled")
	var td: Dictionary = c.get("touchdown", {})
	for k in ["run_max_ms", "stand_max_ms", "step_period_s"]:
		check(td.has(k) and float(td[k]) > 0.0, "touchdown.%s > 0" % k)
		check(td.has(k + "_doc"), "touchdown.%s_doc есть" % k)
	check(float(td.stand_max_ms) < float(td.run_max_ms), "stand_max_ms < run_max_ms")


func test_touchdown_grades() -> void:
	var lc: Dictionary = Config.get_config("flight").landing
	var t := PendulumTouchdown.new()
	t.setup(Config.get_config("pendulum").touchdown)
	var up := Vector3.UP
	# горизонтальная вдоль −Z (север), вертикальная вниз
	var cases := [
		# [гор., верт., крен, касание, оценка, touchdown]
		[1.0, 1.0, 0.0, "feet", "soft", "stood"],
		[t.stand_max + 0.5, 1.0, 0.0, "feet", "soft", "ran"],
		[t.run_max + 0.3, 1.0, 0.0, "feet", "hard", "hard"],
		[1.0, float(lc.hard_vertical_ms) + 0.1, 0.0, "feet", "hard", "hard"],
		[1.0, 1.0, float(lc.soft_bank_deg) + 1.0, "feet", "hard", "hard"],
		[1.0, 1.0, 0.0, "bar", "hard", "hard"],
		[1.0, 1.0, 0.0, "nose", "crash", "crash"],
		[float(lc.crash_horizontal_ms) + 1.0, 1.0, 0.0, "feet", "crash", "crash"],
	]
	for cs: Array in cases:
		var v := Vector3(0.0, -float(cs[1]), -float(cs[0]))
		var r := t.evaluate(v, up, float(cs[2]), String(cs[3]), lc)
		for k in ["grade", "vertical_speed_ms", "horizontal_speed_ms", "bank_deg", "contact", "touchdown", "runout_m", "steps"]:
			check(r.has(k), "result.%s есть (%s)" % [k, cs])
		check(r.grade == cs[4], "%s → %s (%s)" % [cs, cs[4], r.grade])
		check(r.touchdown == cs[5], "%s → %s (%s)" % [cs, cs[5], r.touchdown])
	var r2 := t.evaluate(Vector3(0.0, -1.0, -4.0), up, 0.0, "feet", lc)
	var a := float(lc.runout_decel_ms2)
	approx(float(r2.runout_m), 16.0 / (2.0 * a), 1.0e-6, "пробег v²/2a")
	check(int(r2.steps) == roundi(4.0 / a / t.step_period), "шаги = v/a / период шага (%d)" % r2.steps)
