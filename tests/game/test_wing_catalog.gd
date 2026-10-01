extends TestCase
## WingCatalog: группы крыльев по порядку wing_groups.json, крылья группы по качеству и ветру.


func test_groups_in_file_order() -> void:
	var ids: Array[String] = []
	for g in WingCatalog.groups():
		ids.append(String(g.id))
		check(String(g.name) == "wing_group_" + String(g.id), "ключ названия: %s" % g)
		check(String(g.hint) == "wing_group_%s_hint" % g.id, "ключ подсказки: %s" % g)
	check(ids == ["soviet", "trainer", "kingpost", "topless"], "порядок групп: %s" % [ids])


func test_every_wing_in_one_group() -> void:
	var total := 0
	for g in WingCatalog.groups():
		total += WingCatalog.wings_in_group(String(g.id)).size()
	check(total == Config.list_configs("wings").size(), "каждое крыло в своей группе: %d" % total)
	check(WingCatalog.group_of("wings/training") == "trainer", "Falcon — учебное")
	check(WingCatalog.group_of("laminar") == "kingpost", "Laminar — мачтовое (без префикса)")
	check(WingCatalog.group_of("wings/no_such_wing") == "", "нет крыла — нет группы")


func test_wings_sorted_by_glide_then_wind() -> void:
	for g in WingCatalog.groups():
		var ws := WingCatalog.wings_in_group(String(g.id))
		check(not ws.is_empty(), "%s: есть крылья" % g.id)
		for i in range(1, ws.size()):
			var a := Config.get_config(ws[i - 1])
			var b := Config.get_config(ws[i])
			var ga := WingCatalog.best_glide(a)
			var gb := WingCatalog.best_glide(b)
			var ok := ga < gb or (ga == gb and WingCatalog.wind_max(a) <= WingCatalog.wind_max(b))
			check(ok, "%s: порядок %s → %s" % [g.id, ws[i - 1], ws[i]])
	var soviet := WingCatalog.wings_in_group("soviet")
	check(
		soviet == PackedStringArray(["wings/slavutich_ut", "wings/apogee", "wings/atlas"]),
		"советские: %s" % [soviet]
	)
	var kp := WingCatalog.wings_in_group("kingpost")
	check(
		kp.has("wings/magic") and kp.find("wings/magic") < kp.find("wings/laminar"),
		"мачтовые: Magic раньше Laminar: %s" % [kp]
	)


func test_group_ranges() -> void:
	var prev_glide := 0.0
	for g in WingCatalog.groups():
		var gl := WingCatalog.glide_range(String(g.id))
		var wr := WingCatalog.wind_range(String(g.id))
		check(gl.x > 0.0 and gl.x <= gl.y, "%s: качество %s" % [g.id, gl])
		check(wr.x > 0.0 and wr.x <= wr.y, "%s: ветер %s" % [g.id, wr])
		check(gl.y >= prev_glide, "%s: группы идут по возрастанию качества" % g.id)
		prev_glide = gl.y
	var t := WingCatalog.glide_range("topless")
	approx(t.x, 15.0, 0.3, "безмачтовые: качество от")
	approx(t.y, 16.0, 0.3, "безмачтовые: качество до")
	check(WingCatalog.wind_range("topless") == Vector2(12, 12), "безмачтовые: ветер 12")
	check(WingCatalog.glide_range("no_such_group") == Vector2.ZERO, "пустая группа")
