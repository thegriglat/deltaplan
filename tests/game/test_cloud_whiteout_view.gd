extends TestCase
## CloudWhiteout v2 (CVW-К2): непрерывность по amount, возврат исходного, метаданные для облаков.

const CFG := {"density_gain": 1.5, "rise_time_s": 0.3, "fog_density": 0.06, "color": [0.86, 0.88, 0.9]}


func _env(fog_on: bool) -> Environment:
	var env := Environment.new()
	env.fog_enabled = fog_on
	env.fog_density = 5e-5 if fog_on else 0.0
	env.fog_sky_affect = 0.1
	env.fog_light_color = Color(0.55, 0.67, 0.86)
	env.fog_height_density = 0.01
	return env


## Вклад тумана в небо: доля fog_sky_affect, если туман включён и плотный (> 0), иначе 0.
func _sky(env: Environment) -> float:
	return env.fog_sky_affect if env.fog_enabled and env.fog_density > 0.0 else 0.0


func _at(env: Environment, amount: float) -> CloudWhiteout:
	var w := CloudWhiteout.new()
	w.setup(CFG)
	w.amount = amount
	w.apply(env)
	return w


func test_zero_is_original_and_no_meta() -> void:
	for fog_on in [true, false]:
		var env := _env(fog_on)
		var w := _at(env, 0.5)
		check(env.has_meta("fog_base") and env.has_meta("whiteout_veil"), "в мгле метаданные есть")
		w.amount = 0.0
		w.apply(env)
		var ref := _env(fog_on)
		check(env.fog_enabled == ref.fog_enabled, "fog_enabled исходный (%s)" % fog_on)
		check(env.fog_density == ref.fog_density, "fog_density побитно")
		check(env.fog_sky_affect == ref.fog_sky_affect, "fog_sky_affect побитно")
		check(env.fog_light_color == ref.fog_light_color, "цвет побитно")
		check(env.fog_height_density == ref.fog_height_density, "высотный туман побитно")
		check(not env.has_meta("fog_base"), "fog_base убран")
		check(not env.has_meta("whiteout_veil"), "whiteout_veil убран")


func test_continuity_small_amount() -> void:
	for fog_on in [true, false]:
		var e0 := _env(fog_on)
		_at(e0, 0.0)
		var e1 := _env(fog_on)
		_at(e1, 0.01)
		check(absf(_sky(e1) - _sky(e0)) <= 0.01, "небо amount 0 -> 0,01 (%s)" % fog_on)
		check(absf(e1.fog_density - e0.fog_density) <= 0.001, "плотность непрерывна")
		var dc := Vector3(e1.fog_light_color.r - e0.fog_light_color.r, e1.fog_light_color.g - e0.fog_light_color.g, e1.fog_light_color.b - e0.fog_light_color.b)
		check(dc.length() <= 0.01, "цвет непрерывен")
		# Вклад неба = fog_sky_affect × (цвет тумана − небо): тоже ≤ 0,01 по доле.
		var veil: Dictionary = e1.get_meta("whiteout_veil")
		check(float(veil.v) <= 0.01 + 1e-6, "вуаль v(0,01) ≤ 0,01")


func test_full_whiteout_visible() -> void:
	for fog_on in [true, false]:
		var env := _env(fog_on)
		_at(env, 1.0)
		check(env.fog_enabled and env.fog_density >= 0.05, "густой туман при amount=1")
		check(env.fog_sky_affect >= 0.95, "небо в мгле")
		check(float((env.get_meta("whiteout_veil") as Dictionary).v) >= 0.95, "вуаль облаков")
		var fb: Dictionary = env.get_meta("fog_base")
		check(bool(fb.enabled) == fog_on, "fog_base.enabled")
		approx(float(fb.sky_affect), 0.1, 1e-6, "fog_base.sky_affect")
		approx(float(fb.density), 5e-5 if fog_on else 0.0, 1e-9, "fog_base.density")


func test_fog_density_geometric() -> void:
	# Дальний рельеф: при слабой мгле видимость остаётся километрами (ступеньки на кромке нет).
	var e := _env(false)
	_at(e, 0.05)
	check(e.fog_density < 1e-5, "amount 0,05: fog_density %.2e мала" % e.fog_density)
	var prev := 0.0
	for i in 21:
		var e2 := _env(false)
		_at(e2, i / 20.0)
		check(e2.fog_density >= prev - 1e-12, "плотность монотонна")
		prev = e2.fog_density
	approx(prev, 0.06, 1e-6, "amount 1 — плотность мглы")


func test_sky_share_monotonic() -> void:
	var prev := -1.0
	for i in 21:
		var env := _env(false)
		_at(env, i / 20.0)
		check(_sky(env) >= prev - 1e-9, "небо монотонно")
		prev = _sky(env)
