extends TestCase
## Логика реплик пилота (PV-К1/PV-К4): срабатывание каждой ситуации и не-срабатывание у порога,
## паузы, приоритеты, ожидание, антиповтор, chance, «раз за полёт». Без нод и звука.

const DT := 0.1


## Логика на боевом конфиге; over: id -> {ключ: значение} поверх ситуации (chance, cooldown_s…).
func _logic(over := {}, seed_value := 7) -> PilotVoiceLogic:
	var cfg: Dictionary = (Config.get_config("pilot_voice") as Dictionary).duplicate(true)
	for id: String in cfg.situations:
		cfg.situations[id].chance = 1.0  # детерминизм условий; chance проверяется отдельно
	for id: String in over:
		for k: String in over[id]:
			cfg.situations[id][k] = over[id][k]
	var l := PilotVoiceLogic.new()
	l.setup(cfg, seed_value)
	return l


func _s(over := {}) -> Dictionary:
	var s := {
		"phase": "flying", "vario_ms": 0.0, "airspeed_ms": 12.0, "load_factor": 1.0, "bank_deg": 0.0,
		"altitude_agl": 100.0, "altitude_msl": 1000.0, "stalled": false, "cloud": 0.0,
	}
	s.merge(over, true)
	return s


## Идти secs секунд; реплики сразу «доигрываются». Возвращает все начатые line_id.
func _run(l: PilotVoiceLogic, secs: float, s: Dictionary) -> Array:
	var out := []
	for i in int(round(secs / DT)):
		var id := l.update(DT, s)
		if id != "":
			out.append(id)
			l.line_finished()
	return out




func _has(ids: Array, sit: String) -> bool:
	for id: String in ids:
		if id.begins_with(sit + "_") and id.trim_prefix(sit + "_").is_valid_int():
			return true
	return false


func _flying(l: PilotVoiceLogic, v := 0.0) -> PilotVoiceLogic:
	l.event("took_off", {"altitude_msl": 1000.0})
	_run(l, 25.0, _s({"vario_ms": v}))  # takeoff, quiet_after_takeoff_s и gap_s позади
	return l


# --- ситуации ---------------------------------------------------------------------------------------


func test_takeoff_after_delay_once() -> void:
	var l := _logic()
	l.event("took_off", {"altitude_msl": 1000.0})
	check(_run(l, 0.9, _s()).is_empty(), "takeoff: раньше delay_s 1,0 тихо")
	check(_has(_run(l, 0.5, _s()), "takeoff"), "takeoff: после delay_s")
	_run(l, 6.0, _s())  # пауза gap_s приоритета 2
	l.event("took_off", {"altitude_msl": 1000.0})  # новый отрыв = новый полёт
	check(_has(_run(l, 2.0, _s()), "takeoff"), "takeoff: на новом отрыве снова")


func test_sink() -> void:
	var l := _flying(_logic())
	check(_run(l, 6.0, _s({"vario_ms": -2.9})).is_empty(), "sink: -2.9 ещё нет")
	check(_run(l, 6.0, _s({"vario_ms": -3.5, "airspeed_ms": 16.0})).is_empty(), "sink: V > max_airspeed_ms (пикирование)")
	check(_run(l, 2.5, _s({"vario_ms": -3.5})).is_empty(), "sink: меньше hold_s нет")
	check(_has(_run(l, 1.0, _s({"vario_ms": -3.5})), "sink"), "sink: v <= -3 на hold_s 3")
	var l2 := _flying(_logic())
	check(not _has(_run(l2, 6.0, _s({"vario_ms": -3.5, "stalled": true})), "sink"), "sink: при сваливании нет")


func test_thermal_found_needs_quiet() -> void:
	var l := _flying(_logic(), 0.7)  # ни «тихо», ни «подъём»
	# 5 с «тихо» меньше quiet_s 20: подъём — не «нашёл»
	_run(l, 5.0, _s({"vario_ms": 0.0}))
	check(_run(l, 6.0, _s({"vario_ms": 1.5})).is_empty(), "thermal_found: без quiet_s не срабатывает")
	var l2 := _flying(_logic())
	_run(l2, 21.0, _s({"vario_ms": -0.2}))
	check(_run(l2, 2.5, _s({"vario_ms": 1.5})).is_empty(), "thermal_found: меньше hold_s")
	check(_has(_run(l2, 1.0, _s({"vario_ms": 1.5})), "thermal_found"), "thermal_found: тихо 20 с, затем v >= 1 на 3 с")
	var l3 := _flying(_logic())
	_run(l3, 21.0, _s({"vario_ms": -0.2}))
	check(_run(l3, 6.0, _s({"vario_ms": 0.9})).is_empty(), "thermal_found: 0,9 < v_ms")


func test_thermal_strong() -> void:
	var l := _flying(_logic(), 0.7)
	check(_run(l, 6.0, _s({"vario_ms": 2.9})).filter(func(x: String) -> bool: return x.begins_with("thermal_strong")).is_empty(), "strong: 2,9 нет")
	check(_run(l, 3.0, _s({"vario_ms": 3.2})).is_empty(), "strong: меньше hold_s 4")
	check(_has(_run(l, 1.5, _s({"vario_ms": 3.2})), "thermal_strong"), "strong: v >= 3 на 4 с")


func test_thermal_lost() -> void:
	var l := _flying(_logic())
	_run(l, 31.0, _s({"vario_ms": 1.2}))
	check(_run(l, 4.0, _s({"vario_ms": -1.5})).filter(func(x: String) -> bool: return x.begins_with("thermal_lost")).is_empty(), "lost: 4 с < hold_s 5")
	check(_has(_run(l, 1.5, _s({"vario_ms": -1.5})), "thermal_lost"), "lost: после 30 с подъёма v <= -1 на 5 с")
	var l2 := _flying(_logic())
	_run(l2, 31.0, _s({"vario_ms": 0.5}))  # среднее ниже 0,8
	check(not _has(_run(l2, 8.0, _s({"vario_ms": -1.5})), "thermal_lost"), "lost: не было подъёма — не теряли")
	var l3 := _flying(_logic())
	_run(l3, 31.0, _s({"vario_ms": 1.2}))
	check(not _has(_run(l3, 8.0, _s({"vario_ms": -0.9})), "thermal_lost"), "lost: -0,9 выше порога")


func test_turbulence() -> void:
	var l := _flying(_logic())
	var calm_turn := _s({"bank_deg": 45.0, "load_factor": 1.0 / cos(deg_to_rad(45.0))})
	check(_run(l, 20.0, calm_turn).is_empty(), "turbulence: ровный вираж n = 1/cos(bank) — тихо")
	var ids := []
	for k in 3:
		ids += _run(l, 0.3, _s({"load_factor": 1.6}))  # выброс 0,6 >= 0,4
		ids += _run(l, 0.5, _s({"load_factor": 1.0}))
	check(_has(ids, "turbulence"), "turbulence: 3 выброса за 8 с")
	var l2 := _flying(_logic())
	var ids2 := []
	for k in 3:
		ids2 += _run(l2, 0.3, _s({"load_factor": 1.3}))  # 0,3 < 0,4
		ids2 += _run(l2, 0.5, _s())
	check(ids2.is_empty(), "turbulence: выбросы 0,3 не считаются")
	var l3 := _flying(_logic())
	var ids3 := []
	for k in 3:  # у земли (agl <= 10) не считаем
		ids3 += _run(l3, 0.3, _s({"load_factor": 1.6, "altitude_agl": 8.0}))
		ids3 += _run(l3, 0.5, _s({"altitude_agl": 8.0}))
	check(ids3.is_empty(), "turbulence: ниже 10 м нет")
	var l4 := _flying(_logic())
	var ids4 := []
	for k in 3:  # выбросы реже окна 8 с
		ids4 += _run(l4, 0.3, _s({"load_factor": 1.6}))
		ids4 += _run(l4, 4.7, _s())
	check(ids4.is_empty(), "turbulence: 2 выброса в окне — мало")


func test_stall() -> void:
	var l := _flying(_logic())
	check(_run(l, 3.0, _s({"stalled": true, "altitude_agl": 4.0})).is_empty(), "stall: agl <= 5 нет")
	check(_run(l, 0.4, _s({"stalled": true})).is_empty(), "stall: меньше hold_s 0,5")
	check(_has(_run(l, 0.4, _s({"stalled": true})), "stall"), "stall: stalled 0,5 с")


func test_fast_and_cloud() -> void:
	var l := _flying(_logic())
	check(_run(l, 6.0, _s({"airspeed_ms": 21.5})).is_empty(), "fast: 21,5 < 22")
	check(_has(_run(l, 3.5, _s({"airspeed_ms": 22.5})), "fast"), "fast: V >= 22 на 3 с")
	var l2 := _flying(_logic())
	check(_run(l2, 4.0, _s({"cloud": 0.5})).is_empty(), "cloud: 0,5 < 0,6")
	check(_run(l2, 0.8, _s({"cloud": 0.7})).is_empty(), "cloud: меньше hold_s 1")
	check(_has(_run(l2, 0.4, _s({"cloud": 0.7})), "cloud"), "cloud: >= 0,6 на 1 с")


func test_low_needs_rearm() -> void:
	var l := _flying(_logic())
	check(_run(l, 5.0, _s({"altitude_agl": 50.0, "vario_ms": -1.0})).is_empty(), "low: не взведено (не было 200 м)")
	_run(l, 1.0, _s({"altitude_agl": 250.0}))
	check(_run(l, 2.0, _s({"altitude_agl": 50.0, "vario_ms": 0.5})).is_empty(), "low: при подъёме (v >= 0) нет")
	check(_has(_run(l, 1.0, _s({"altitude_agl": 50.0, "vario_ms": -1.0})), "low"), "low: agl < 80 и v < 0 после 200 м")
	check(_run(l, 5.0, _s({"altitude_agl": 50.0, "vario_ms": -1.0})).is_empty(), "low: снова — только после нового набора 200 м")
	_run(l, 1.0, _s({"altitude_agl": 250.0}))
	check(_run(l, 5.0, _s({"altitude_agl": 50.0, "vario_ms": -1.0})).is_empty(), "low: пауза ситуации 120 с")


func test_high_steps() -> void:
	var l := _flying(_logic({"high": {"cooldown_s": 0.0}}))
	check(_run(l, 2.0, _s({"altitude_msl": 1299.0})).is_empty(), "high: 299 м — нет")
	check(_has(_run(l, 1.0, _s({"altitude_msl": 1301.0})), "high"), "high: ступень 300 м")
	check(_run(l, 30.0, _s({"altitude_msl": 1450.0})).is_empty(), "high: та же ступень второй раз нет")
	_run(l, 25.0, _s({"altitude_msl": 1100.0}))  # ушли вниз
	check(_run(l, 5.0, _s({"altitude_msl": 1350.0})).is_empty(), "high: ступень 300 повторно (после спуска) нет")
	check(_has(_run(l, 5.0, _s({"altitude_msl": 1601.0})), "high"), "high: ступень 600")


func test_view() -> void:
	var l := _flying(_logic())
	var calm := _s({"altitude_agl": 200.0, "vario_ms": 0.3})
	check(_run(l, 40.0, calm).is_empty(), "view: меньше calm_s тихо")
	check(_has(_run(l, 25.0, calm), "view"), "view: 60 с спокойно и тихо")
	var l2 := _flying(_logic())
	check(_run(l2, 90.0, _s({"altitude_agl": 100.0, "vario_ms": 0.3})).is_empty(), "view: ниже 150 м нет")
	var l3 := _flying(_logic())
	check(_run(l3, 90.0, _s({"altitude_agl": 200.0, "vario_ms": 1.5})).filter(func(x: String) -> bool: return x.begins_with("view")).is_empty(), "view: при подъёме нет")


# --- события ------------------------------------------------------------------------------------------


func test_landing_grades_once_per_flight() -> void:
	for pair: Array in [["soft", "landing_soft"], ["hard", "landing_hard"], ["crash", "crash"]]:
		var l := _flying(_logic())
		l.event("landed", {"grade": pair[0]})
		check(_run(l, 0.5, _s({"phase": "landed"})).is_empty(), "%s: раньше delay_s тихо" % pair[0])
		check(_has(_run(l, 1.0, _s({"phase": "landed"})), pair[1]), "%s: реплика %s" % [pair[0], pair[1]])
		l.event("landed", {"grade": pair[0]})
		check(_run(l, 12.0, _s({"phase": "landed"})).is_empty(), "%s: раз за полёт" % pair[0])
		l.reset()
		l.event("landed", {"grade": pair[0]})
		check(_has(_run(l, 1.5, _s({"phase": "landed"})), pair[1]), "%s: после reset снова" % pair[0])
	var l2 := _flying(_logic())
	l2.event("landed", {"grade": "weird"})
	check(_run(l2, 3.0, _s({"phase": "landed"})).is_empty(), "посадка с неизвестной оценкой — тихо")


func test_turnpoint_and_goal_events() -> void:
	var l := _flying(_logic())
	l.event("turnpoint")
	check(_has(_run(l, 0.3, _s()), "turnpoint"), "turnpoint: сразу")
	l.event("turnpoint")
	check(_run(l, 5.0, _s()).is_empty(), "turnpoint: пауза 10 с")
	l.event("goal")
	check(_has(_run(l, 0.3, _s()), "goal"), "goal: сразу")


func test_egg_seen_once_per_flight() -> void:
	var l := _flying(_logic())
	l.event("egg_seen", {"id": "nonexistent"})
	check(_run(l, 3.0, _s()).is_empty(), "egg_seen: неизвестный id игнорируется")
	l.event("egg_seen", {"id": "eagle"})
	check(_has(_run(l, 0.3, _s()), "egg_eagle"), "egg_seen eagle: реплика")
	l.event("egg_seen", {"id": "eagle"})
	check(_run(l, 5.0, _s()).is_empty(), "egg_seen: раз за полёт")
	l.reset()
	_flying(l)
	l.event("egg_seen", {"id": "eagle"})
	check(_has(_run(l, 0.3, _s()), "egg_eagle"), "egg_seen: после reset снова")


func test_egg_is_background() -> void:
	var l := _logic()
	l._rules["gap_s"]["1"] = 0.0  # здесь проверяем только quiet_after_takeoff_s
	l.event("took_off", {"altitude_msl": 1000.0})
	_run(l, 2.0, _s())
	l.event("egg_seen", {"id": "eagle"})
	check(_run(l, 3.0, _s()).is_empty(), "egg: фон не раньше quiet_after_takeoff_s")
	check(_has(_run(l, 5.0, _s()), "egg_eagle"), "egg: ждала в очереди и сказана после 8 с от отрыва (gap_s прошёл)")


# --- правила выдачи -----------------------------------------------------------------------------------


func test_quiet_after_takeoff() -> void:
	var l := _logic()
	l.event("took_off", {"altitude_msl": 1000.0})
	var ids := _run(l, 5.5, _s())
	ids += _run(l, 1.5, _s({"cloud": 0.9}))
	check(_has(ids, "cloud"), "cloud (приоритет 2) можно до 8 с")
	var l2 := _logic()
	l2._rules["gap_s"]["1"] = 0.0  # здесь проверяем только quiet_after_takeoff_s
	l2.event("took_off", {"altitude_msl": 1000.0})
	check(not _has(_run(l2, 7.0, _s({"airspeed_ms": 25.0})), "fast"), "фон (fast) — не раньше 8 с после отрыва")
	check(_has(_run(l2, 6.0, _s({"airspeed_ms": 25.0})), "fast"), "fast — после 8 с")


func test_gap_by_priority() -> void:
	var l := _flying(_logic())
	l.event("goal")
	var id := l.update(DT, _s())
	check(id.begins_with("goal_"), "первая реплика")
	l.line_finished()
	_run(l, 3.0, _s())
	l.event("turnpoint")
	check(_run(l, 1.5, _s()).is_empty(), "после реплики приоритет 2 — не раньше gap_s 5")
	check(_has(_run(l, 1.0, _s()), "turnpoint"), "после 5 с можно (ждала < max_wait_s)")
	# приоритет 1 в паузе 20 с: событие ждёт не дольше max_wait_s 8 с и отбрасывается без траты
	var l2 := _flying(_logic())
	l2.event("goal")
	l2.update(DT, _s())
	l2.line_finished()
	_run(l2, 0.5, _s())
	l2.event("egg_seen", {"id": "eagle"})
	check(_run(l2, 10.0, _s()).is_empty(), "приоритет 1 в паузе 20 с: ждала > 8 с — отброшена")
	check(not l2._egg_done.has("egg_eagle") and not l2._last_fired.has("egg_eagle"), "…и ничего не потратила")
	_run(l2, 12.0, _s())
	l2.event("egg_seen", {"id": "eagle"})
	check(_has(_run(l2, 12.0, _s()), "egg_eagle"), "повторное событие после паузы gap_s — звучит")


func test_urgent_interrupts_background_only() -> void:
	var l := _flying(_logic())
	l.event("egg_seen", {"id": "eagle"})
	var bg := l.update(DT, _s())
	check(bg.begins_with("egg_eagle"), "фоновая звучит")
	check(not l.is_interrupting(bg), "фоновая не прерывает")
	l.event("goal")  # 2 не прерывает 1
	check(l.update(DT, _s()) == "", "приоритет 2 ждёт звучащую фоновую")
	check(l.update(DT, _s({"stalled": true, "altitude_agl": 50.0})) == "", "stall ещё не набрал hold_s")
	var urgent := ""
	for i in 10:
		urgent = l.update(DT, _s({"stalled": true, "altitude_agl": 50.0}))
		if urgent != "":
			break
	check(urgent.begins_with("stall_"), "срочная (3) выдана поверх фоновой: «%s»" % urgent)
	check(l.is_interrupting(urgent), "is_interrupting(stall)")
	# срочная звучит — другая срочная не прерывает
	l.event("landed", {"grade": "crash"})
	check(_run_noend(l, 3.0, _s()).is_empty(), "3 не прерывает 3")


func _run_noend(l: PilotVoiceLogic, secs: float, s: Dictionary) -> Array:
	var out := []
	for i in int(round(secs / DT)):
		var id := l.update(DT, s)
		if id != "":
			out.append(id)
	return out


func test_event_waits_up_to_max_wait() -> void:
	var l := _flying(_logic())
	l.event("egg_seen", {"id": "eagle"})
	l.update(DT, _s())  # звучит фоновая и не кончается
	l.event("goal")
	check(_run_noend(l, 2.0, _s()).is_empty(), "goal ждёт звучащую")
	l.line_finished()
	check(_has(_run(l, 6.0, _s()), "goal"), "goal дождалась (gap_s 5, всего < 8 с)")
	var l2 := _flying(_logic())
	l2.event("egg_seen", {"id": "eagle"})
	l2.update(DT, _s())
	l2.event("goal")
	check(_run_noend(l2, 9.0, _s()).is_empty(), "goal ждёт звучащую 9 с")
	l2.line_finished()
	check(_run(l2, 10.0, _s()).is_empty(), "goal старше max_wait_s 8 с — отброшена")
	check(not l2._last_fired.has("goal"), "отброшенное событие не тратит паузу")


## PV-К1 v3: ситуация по данным во время звучания/gap_s ничего не тратит и скажется, когда станет можно.
func test_blocked_situation_spends_nothing() -> void:
	var l := _flying(_logic())
	l.event("goal")
	check(l.update(DT, _s({"vario_ms": -4.0})).begins_with("goal_"), "звучит goal")
	# sink держится 5 с, пока звучит и идёт gap_s
	check(_run_noend(l, 5.0, _s({"vario_ms": -4.0})).is_empty(), "sink не перебивает")
	check(not l._last_fired.has("sink"), "пауза sink не потрачена")
	l.line_finished()
	check(_run(l, 4.0, _s({"vario_ms": -4.0})).is_empty(), "gap_s 20 для фона ещё идёт")
	check(_has(_run(l, 17.0, _s({"vario_ms": -4.0})), "sink"), "sink сказан, как только можно, пока условие держится")
	# ступень high не теряется
	var l2 := _flying(_logic())
	l2.event("goal")
	l2.update(DT, _s())
	_run_noend(l2, 2.0, _s({"altitude_msl": 1310.0}))
	check(l2._high_level == 0, "ступень high не потрачена, пока звучит")
	l2.line_finished()
	check(_has(_run(l2, 22.0, _s({"altitude_msl": 1310.0})), "high"), "high сказан после gap_s")
	# условие ушло — не скажется
	var l3 := _flying(_logic())
	l3.event("goal")
	l3.update(DT, _s())
	_run_noend(l3, 5.0, _s({"vario_ms": -4.0}))
	l3.line_finished()
	check(_run(l3, 30.0, _s({"vario_ms": 0.0})).is_empty(), "условие не держится — молчим")


func test_events_repeat_egg_until_said() -> void:
	var l := _flying(_logic())
	l.event("egg_seen", {"id": "eagle"})
	l.event("egg_seen", {"id": "eagle"})  # дубль не ставится второй раз
	check(l._pending.size() == 1, "одно событие на ситуацию")
	check(_run(l, 1.0, _s()).size() == 1, "сказана один раз")
	l.event("egg_seen", {"id": "eagle"})
	check(_run(l, 25.0, _s()).is_empty(), "после сказанного — раз за полёт")


func test_variants_do_not_repeat() -> void:
	var l := _logic({"turnpoint": {"cooldown_s": 0.0}, "sink": {"cooldown_s": 0.0}})
	_flying(l)
	var seq := []
	for i in 12:
		l.event("turnpoint")
		var ids := _run(l, 6.0, _s())
		check(ids.size() == 1, "один turnpoint — одна реплика")
		seq.append(ids[0])
	for i in range(1, seq.size()):
		check(seq[i] != seq[i - 1], "turnpoint (2 варианта): подряд не повторяется (%s)" % [seq])
	# антиповтор на одном полёте: thermal_strong (3 варианта) с cooldown 0
	var l4 := _logic({"thermal_strong": {"cooldown_s": 0.0}, "thermal_found": {"chance": 0.0}})
	_flying(l4)
	var seq4 := []
	for i in 12:
		var ids4 := _run(l4, 5.0, _s({"vario_ms": 3.5}))
		_run(l4, 21.0, _s({"vario_ms": 0.0}))
		for x in ids4:
			if x.begins_with("thermal_strong"):
				seq4.append(x)
	check(seq4.size() >= 6, "thermal_strong срабатывает повторно: %d" % seq4.size())
	for i in range(2, seq4.size()):
		check(seq4[i] != seq4[i - 1] and seq4[i] != seq4[i - 2], "3 варианта: не совпадает с двумя последними (%s)" % [seq4])


func test_chance_zero_silent_but_cooldown_spent() -> void:
	var l := _flying(_logic({"sink": {"chance": 0.0}}))
	check(_run(l, 5.0, _s({"vario_ms": -4.0})).is_empty(), "chance 0: тихо")
	var l2 := _flying(_logic({"sink": {"chance": 0.0}}))
	_run(l2, 5.0, _s({"vario_ms": -4.0}))
	# пауза ситуации потрачена: даже при chance 1 теперь молчим в пределах cooldown_s
	l2._sit["sink"]["chance"] = 1.0
	check(_run(l2, 30.0, _s({"vario_ms": -4.0})).is_empty(), "chance не выпал — ситуация ушла на паузу (90 с)")
	check(_has(_run(l2, 70.0, _s({"vario_ms": -4.0})), "sink"), "после паузы снова может")


func test_cooldown() -> void:
	var l := _flying(_logic())
	check(_has(_run(l, 4.0, _s({"vario_ms": -4.0})), "sink"), "первый раз")
	check(_run(l, 60.0, _s({"vario_ms": -4.0})).is_empty(), "sink: пауза 90 с")
	check(_has(_run(l, 40.0, _s({"vario_ms": -4.0})), "sink"), "после паузы")


func test_not_flying_is_silent_and_resets_hold() -> void:
	var l := _flying(_logic())
	for phase in ["standing", "running", "landed"]:
		check(_run(l, 5.0, _s({"phase": phase, "vario_ms": -4.0, "stalled": true, "cloud": 1.0})).is_empty(), "%s: тихо" % phase)
	_run(l, 2.5, _s({"vario_ms": -4.0}))
	_run(l, 1.0, _s({"phase": "standing", "vario_ms": -4.0}))
	check(_run(l, 0.6, _s({"vario_ms": -4.0})).is_empty(), "sink: посадка/пауза фазы обнулила непрерывность")


func test_deterministic_with_seed() -> void:
	var a := _logic({}, 42)
	var b := _logic({}, 42)
	var c := _logic({}, 43)
	var seqs := []
	for l in [a, b, c]:
		_flying(l)
		var all := []
		for i in 6:
			l.event("goal")
			all += _run(l, 8.0, _s())
		seqs.append(all)
	check(seqs[0] == seqs[1], "тот же seed — те же реплики")
	check(not seqs[0].is_empty(), "реплики были")


func test_reset_clears_state() -> void:
	var l := _flying(_logic())
	_run(l, 4.0, _s({"vario_ms": -4.0}))
	l.reset()
	_flying(l)
	check(_has(_run(l, 4.0, _s({"vario_ms": -4.0})), "sink"), "reset снимает паузы")
