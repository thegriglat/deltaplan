extends TestCase
## Контрактные тесты wingman: WM-К1 (напарник в BotPilots). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/wingman.md"


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	check(_read(DOC).contains("## WM-К1 v1"), "WM-К1 v1 заголовок")


func test_k1_config() -> void:
	var w: Dictionary = Config.get_config("bots").get("wingman", {})
	for k in ["count", "count_max", "near_m", "far_m", "lead_s", "join_m", "leave_m", "leave_below_m"]:
		check(w.has(k), "wingman.%s есть" % k)
		check(w.has(k + "_doc"), "wingman.%s_doc есть" % k)
		check(typeof(w.get(k)) in [TYPE_INT, TYPE_FLOAT], "wingman.%s — число" % k)
	check(float(w.near_m) < float(w.far_m), "near_m < far_m")
	check(int(w.count_max) == 2, "count_max == 2")
	check(int(w.count) >= 0 and int(w.count) <= int(w.count_max), "count в [0, count_max]")


func _make(count: int, wingmen: int) -> BotPilots:
	var b := BotPilots.new()
	b.visuals_enabled = false
	b.wingmen = wingmen
	b.setup(
		{
			"air_fn": func(_p: Vector3) -> Vector3: return Vector3.ZERO,
			"ground_fn": func(_x: float, _z: float) -> float: return 300.0,
			"start": Vector3(0.0, 300.0, 0.0),
			"heading_deg": 0.0,
			"count": count,
			"seed": 0,
		}
	)
	return b


func test_k1_code() -> void:
	var d := BotPilots.new()
	check(d.wingmen == 0, "wingmen по умолчанию 0")
	d.free()
	var b := _make(4, 1)
	check(b.agents.size() == 4, "4 бота")
	for i in b.agents.size():
		check(b.agents[i].wingman == (i == 0), "бот %d: wingman=%s" % [i, b.agents[i].wingman])
	b.free()
	var one := _make(1, 5)
	var n := 0
	for a in one.agents:
		n += 1 if a.wingman else 0
	check(n == 1, "wingmen=5 при 1 боте — один напарник: %d" % n)
	one.free()
	var w := WanderPilot.new()
	for f in ["lead_active", "lead_pos", "lead_vel", "lead_circling", "lead_center"]:
		check(f in w, "WanderPilot.%s" % f)
