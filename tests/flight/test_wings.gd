extends TestCase
## Линейка крыльев (docs/archive/plan/wings-lineup.md): новые поля у всех крыльев, ориентиры поляры.

const Sim := preload("res://tests/flight/flight_sim.gd")
const TP := preload("res://tests/flight/test_polar.gd")
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
