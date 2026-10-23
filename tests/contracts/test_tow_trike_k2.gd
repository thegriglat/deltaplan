extends TestCase
## Контрактный тест TT-К2 (docs/contracts/tow-trike.md): крыло буксировщика iXess 15 —
## configs/wings/trike_ixess15.json в группе tug ("player": false), скрыто от игрока и ботов.

const Sim := preload("res://tests/flight/flight_sim.gd")
const WING := "wings/trike_ixess15"
const GLB := "res://assets/models/glider_trike_ixess15.glb"
## tools/research/trike-model/wings.json (iXess 15): площадь, размах, масса крыла; HADS HM16: Vso, MTOW.
const AREA_M2 := 15.0
const SPAN_M := 10.0
const WING_MASS_KG := 53.0
const VSO_KMH := 59.3
const MTOW_KG := 450.0


func _rel(a: float, b: float) -> float:
	return absf(a / b - 1.0)


func test_config_and_model_exist() -> void:
	check(Config.list_configs("wings").has(WING), "есть configs/" + WING + ".json")
	check(ResourceLoader.exists(GLB), "есть " + GLB)
	var cfg := Config.get_config(WING)
	check(String(cfg.get("visual", {}).get("visual_model", "")) == GLB, "visual_model = " + GLB)


func test_group_tug_hidden() -> void:
	var tug: Dictionary = {}
	for g in WingCatalog.all_groups():
		if String(g.get("id", "")) == "tug":
			tug = g
	check(not tug.is_empty(), "группа tug есть в wing_groups.json")
	check(tug.has("player") and tug.player == false, "tug: player == false")
	check(WingCatalog.group_of(WING) == "tug", "крыло в группе tug")
	for g in WingCatalog.groups():
		check(String(g.id) != "tug", "tug нет в группах игрока")
	check(not WingCatalog.player_wings().has(WING), "крыла нет в списке крыльев игрока")
	check(not WingCatalog.is_player_wing(WING), "is_player_wing = false")
	for g in WingCatalog.groups():
		check(not WingCatalog.wings_in_group(String(g.id)).has(WING), "крыла нет в группе " + String(g.id))


func test_not_in_bots() -> void:
	var listed: Array = Config.get_config("bots").get("wings", [])
	check(not listed.has("trike_ixess15") and not listed.has(WING), "нет в configs/bots.json → wings")
	for w in listed:
		check(WingCatalog.is_player_wing(String(w)), "бот-крыло %s доступно игроку" % w)


func test_numbers_match_wings_json() -> void:
	var cfg := Config.get_config(WING)
	check(_rel(float(cfg.area_m2), AREA_M2) <= 0.01, "площадь %s" % cfg.area_m2)
	check(_rel(float(cfg.span_m), SPAN_M) <= 0.01, "размах %s" % cfg.span_m)
	check(_rel(float(cfg.wing_mass_kg), WING_MASS_KG) <= 0.01, "масса крыла %s" % cfg.wing_mass_kg)
	check(float(cfg.pilot_mass_min_kg) < float(cfg.pilot_mass_ref_kg), "min < ref")
	check(float(cfg.pilot_mass_ref_kg) < float(cfg.pilot_mass_max_kg), "ref < max")
	check(_rel(float(cfg.pilot_mass_max_kg) + float(cfg.wing_mass_kg), MTOW_KG) <= 0.01, "max + крыло = MTOW 450")


func test_stall_scales_with_mass() -> void:
	var cfg := Config.get_config(WING)
	var m := Sim.make("trike_ixess15")
	var vs := Units.to_kmh(m.stall_speed())
	var total := float(cfg.pilot_mass_ref_kg) + float(cfg.wing_mass_kg)
	var at_mtow := vs * sqrt(MTOW_KG / total)
	check(_rel(at_mtow, VSO_KMH) <= 0.10, "Vs при MTOW %.1f км/ч, паспорт %.1f" % [at_mtow, VSO_KMH])

