extends TestCase
## Линейка крыльев (docs/archive/plan/wings-lineup.md): новые поля у всех крыльев, ориентиры поляры,
## управляемость «Апогея».

const Sim := preload("res://tests/flight/flight_sim.gd")
const TP := preload("res://tests/flight/test_polar.gd")
const TW := preload("res://tests/flight/test_roll_weight_shift.gd")
const NEW_FIELDS := ["group", "wind_class", "prototype", "era", "kingpost", "double_surface_pct"]


func test_every_wing_has_new_fields() -> void:
	var group_ids := []
	for g: Dictionary in Config.get_config("wing_groups").groups:
		group_ids.append(String(g.id))
	var ws := TP.wings()
	check(ws.size() >= 9, "крыльев в configs/wings: %d" % ws.size())
	for w in ws:
		var cfg := Config.get_config("wings/" + w)
		for f: String in NEW_FIELDS:
			check(cfg.has(f), "%s: нет поля %s" % [w, f])
			check(String(cfg.get(f + "_doc", "")) != "", "%s: нет %s_doc" % [w, f])
		check(group_ids.has(String(cfg.get("group", ""))), "%s: группа из wing_groups.json" % w)
		check(not cfg.has("wind_max_ms"), "%s: wind_max_ms убран (WL-К1)" % w)
		var wc := WingCatalog.wind_class(cfg)
		check(wc >= 1 and wc <= 4, "%s: класс %d" % [w, wc])
		var src := String(cfg.get("double_surface_src", ""))
		check(src in ["passport", "pilot_estimate", "config_prior"], "%s: источник доли обшивки" % w)
		check(cfg.get("kingpost") is bool, "%s: kingpost — bool" % w)
		var ds := int(cfg.get("double_surface_pct", -1))
		check(ds >= 0 and ds <= 100, "%s: доля двойной обшивки %d %%" % [w, ds])
		check(String(cfg.get("prototype", "")) != "" and String(cfg.get("era", "")) != "", w)
		var vis := String(cfg.visual.visual_model)
		check(vis == "res://assets/models/glider_%s.glb" % w, "%s: модель %s" % [w, vis])
		check(ResourceLoader.exists(vis), "%s: файл модели есть" % w)


func test_best_glide_matches_polar() -> void:
	for w in TP.wings():
		var ref := float(Config.value("wings/" + w, "reference.best_glide"))
		approx(TP.sweep(Sim.make(w)).best_ld, ref, 0.3, w + ": reference.best_glide")


func test_apogee_levels_faster_than_training() -> void:
	var ta := TW.level_time(Sim.make("apogee"))
	var tt := TW.level_time(Sim.make("training"))
	check(ta < tt, "«Апогей» выравнивается быстрее учебного: %.2f против %.2f с" % [ta, tt])
	check(ta >= 1.0 and ta < 3.0, "«Апогей»: в горизонт за %.2f с" % ta)


## Сваливание в крене bank_deg: полное выжимание до срыва, через reaction_s — трапеция и вес в
## центр. {stalled, max_bank (°), bank (°) и stalled в конце, v (м/с)} через after_s.
static func stall_in_bank(
	w: String, bank_deg: float, reaction_s := 0.3, after_s := 15.0
) -> Dictionary:
	var m := Sim.make(w)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	Sim.run_for(m, 3.0, TW.ws())
	m.bank = deg_to_rad(bank_deg)
	m.roll_rate = 0.0
	var t := 0.0
	while not m.stalled and t < 10.0:
		# держим крен смещением, пока выжимаем трапецию
		var hold := TW.hold_input(m, bank_deg, 1.0)
		m.step(Sim.DT, hold, Callable(), Callable())
		t += Sim.DT
	var was_stalled := m.stalled
	var max_bank := absf(m.telemetry.bank_deg)
	t = 0.0
	while t < reaction_s + after_s:
		var inp := TW.ws(1.0) if t < reaction_s else TW.ws()
		m.step(Sim.DT, inp, Callable(), Callable())
		max_bank = maxf(max_bank, absf(m.telemetry.bank_deg))
		t += Sim.DT
	return {
		"stalled": was_stalled,
		"max_bank": max_bank,
		"bank": m.telemetry.bank_deg,
		"still_stalled": m.stalled,
		"v": m.telemetry.airspeed,
		"trim": m.trim_speed(),
	}


func test_apogee_stall_in_bank_no_spiral() -> void:
	# сваливание в крене 20°, пилот отпускает трапецию и встаёт в центр: крыло само выходит
	var r := stall_in_bank("apogee", 20.0)
	check(r.stalled, "«Апогей»: полное выжимание в крене сваливает")
	var ob := float(Config.value("wings/apogee", "weight_shift.roll_overbank_deg"))
	check(r.max_bank < ob - 15.0, "«Апогей»: до спирали далеко: крен до %.0f°" % r.max_bank)
	check(not r.still_stalled, "«Апогей»: вышел из срыва")
	check(absf(r.bank) < 3.0, "«Апогей»: выровнялся: %.1f°" % r.bank)
	approx(r.v, r.trim, 0.5, "«Апогей»: вернулся на трим")
	var s := stall_in_bank("sport", 20.0)
	check(
		r.max_bank < s.max_bank, "мягче спортивного: %.0f° против %.0f°" % [r.max_bank, s.max_bank]
	)
