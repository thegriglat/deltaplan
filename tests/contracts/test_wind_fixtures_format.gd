extends TestCase
## Формат эталонов ветра tests/fixtures/wind/ (rust-wind W8, RW-1, RW-1b): схема json, длины .bin,
## конечные числа, теги точек, растры мест, климат в заголовках мест (W5 v3), дневные случаи
## (t_apply, подписи точек, моменты), согласие описаний ядер с выборкой (в ядре средний vy > 0).
## Снятие — tools/wind_fixtures/run.sh, состав — tests/fixtures/wind/README.md.

const ROOT := "res://tests/fixtures/wind"
const TAGS: Array[String] = [
	"ground", "lee", "thermal", "field_edge", "above_base", "storm", "wave", "far"
]


func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _cases() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(ROOT.path_join("cases")):
		# .desc.json — описания, .weather.json — погода и климат (RW-12d): это не случаи
		if f.ends_with(".json") and not f.ends_with(".desc.json") and not f.ends_with(".weather.json"):
			out.append(f.get_basename())
	out.sort()
	return out


## loc.climate (W5 v3): {tx_c, dtr_k, z_cell_m, has_hh1, has_hh5}.
func _check_climate(n: String, loc: Dictionary) -> void:
	check(loc.get("climate") is Dictionary, "%s: loc.climate — словарь" % n)
	if not loc.get("climate") is Dictionary:
		return
	var cl: Dictionary = loc.climate
	for k in ["tx_c", "dtr_k", "z_cell_m"]:
		check(cl.get(k) is float and is_finite(float(cl[k])), "%s: climate.%s — конечное число" % [n, k])
	for k in ["has_hh1", "has_hh5"]:
		check(cl.get(k) is bool, "%s: climate.%s — bool" % [n, k])
	check(float(cl.get("tx_c", 99.0)) > -60.0 and float(cl.get("tx_c", 99.0)) < 60.0, "%s: tx_c правдоподобен" % n)
	check(float(cl.get("dtr_k", -1.0)) >= 0.0 and float(cl.get("dtr_k", 99.0)) < 40.0, "%s: dtr_k правдоподобен" % n)
	check(float(cl.get("z_cell_m", -1.0)) >= 0.0, "%s: z_cell_m ≥ 0" % n)


func test_places() -> void:
	var names := PackedStringArray()
	for f in DirAccess.get_files_at(ROOT.path_join("places")):
		if f.ends_with(".json"):
			names.append(f.get_basename())
	check(names.size() >= 2, "мест не меньше двух: %d" % names.size())
	for n in names:
		var h: Variant = _json(ROOT.path_join("places/%s.json" % n))
		check(h is Dictionary, "%s: заголовок — словарь" % n)
		if not h is Dictionary:
			continue
		check(int(h.get("version", 0)) == 1, "%s: version 1" % n)
		for k in ["loc", "grid", "surface_classes", "start_sites", "h_offset", "h_scale"]:
			check(h.has(k), "%s: нет ключа %s" % [n, k])
		var g: Dictionary = h.grid
		for k in ["origin_x", "origin_z", "spacing", "width", "height"]:
			check(g.has(k), "%s: grid.%s" % [n, k])
		var cells := int(g.width) * int(g.height)
		check(float(h.h_scale) > 0.0 and float(h.h_scale) <= 0.1, "%s: шаг высоты ≤ 0,1 м" % n)
		_check_climate(n, h.loc)
		var bin := FileAccess.get_file_as_bytes(ROOT.path_join("places/%s.bin" % n))
		check(bin.size() == 5 * cells, "%s: .bin %d байт, нужно %d (heights i16, water, cls, moist)" % [n, bin.size(), 5 * cells])
		if bin.size() != 5 * cells:
			continue
		var ncls := (h.surface_classes as Dictionary).size()
		var lo := INF
		var hi := -INF
		var bad_cls := 0
		var bad_water := 0
		for i in range(0, cells, 7):
			var hh := float(h.h_offset) + float(h.h_scale) * bin.decode_s16(2 * i)
			lo = minf(lo, hh)
			hi = maxf(hi, hh)
			if bin[2 * cells + cells + i] >= ncls:
				bad_cls += 1
			if bin[2 * cells + i] > 1:
				bad_water += 1
		check(lo > -500.0 and hi < 9000.0 and hi > lo, "%s: высоты правдоподобны (%.1f…%.1f)" % [n, lo, hi])
		check(bad_cls == 0, "%s: классы поверхности вне списка: %d" % [n, bad_cls])
		check(bad_water == 0, "%s: вода не 0/1: %d" % [n, bad_water])


func test_cases_format() -> void:
	var cases := _cases()
	check(cases.size() >= 6, "случаев не меньше шести: %d" % cases.size())
	var seen := {}
	for n in cases:
		var c: Variant = _json(ROOT.path_join("cases/%s.json" % n))
		check(c is Dictionary, "%s: json — словарь" % n)
		if not c is Dictionary:
			continue
		for k in [
			"version", "place", "conditions", "seed", "static_thermals", "configs_sha1", "times_s",
			"focuses", "points", "point_tags", "terms", "generator"
		]:
			check(c.has(k), "%s: нет ключа %s" % [n, k])
		check(int(c.version) == 1, "%s: version 1" % n)
		check(FileAccess.file_exists(ROOT.path_join("places/%s.json" % c.place)), "%s: место %s есть" % [n, c.place])
		check((c.conditions as Dictionary).has("preset") != (c.conditions as Dictionary).has("forecast"), "%s: условия — ровно один вид" % n)
		var is_day := n.begins_with("ongudai_day")
		var nt := (c.times_s as Array).size()
		check(nt == (4 if is_day else 3), "%s: моментов %d" % [n, nt])
		var np := (c.points as Array).size()
		check(np > 0 and (c.point_tags as Array).size() == np, "%s: тегов столько же, сколько точек" % n)
		for p: Array in c.points:
			check(p.size() == 3 and is_finite(float(p[0])) and is_finite(float(p[1])) and is_finite(float(p[2])), "%s: точка конечна" % n)
		for t: String in c.point_tags:
			check(TAGS.has(t), "%s: тег %s из набора" % [n, t])
			seen[t] = true
		for f: Array in c.focuses:
			check(f.size() == 4 and float(f[3]) > 0.0, "%s: фокус [x, y, z, w>0]" % n)
		var nterms := (c.terms as Array).size() if c.terms is Array else 0
		check(c.terms == null or c.terms is Array, "%s: terms — null или список слагаемых" % n)
		if is_day:
			_check_day(n, c)
		# данные
		var bin := FileAccess.get_file_as_bytes(ROOT.path_join("cases/%s.bin" % n))
		# k = 0 FULL, k = 1 MEAN, дальше слагаемые (README: набор 2 по W7)
		var need: int = (c.times_s as Array).size() * np * (2 + nterms) * 4 * 4
		check(bin.size() == need, "%s: .bin %d байт, нужно %d" % [n, bin.size(), need])
		if bin.size() == need:
			var vals := bin.to_float32_array()
			var bad := 0
			for i in vals.size():
				if not is_finite(vals[i]):
					bad += 1
			check(bad == 0, "%s: нечисловых значений %d" % [n, bad])
			for i in range(3, vals.size(), 4):
				if vals[i] < 0.0:
					check(false, "%s: σ < 0" % n)
					break
		# описания
		var d: Variant = _json(ROOT.path_join("cases/%s.desc.json" % n))
		check(d is Dictionary and (d.frames as Array).size() == nt, "%s: описания на каждый момент" % n)
		if d is Dictionary:
			for fr: Dictionary in d.frames:
				check((fr.cores as Array).size() % 15 == 0, "%s: ядра кратны 15" % n)
				check((fr.clouds as Array).size() % 10 == 0, "%s: облака кратны 10" % n)
				check((fr.crests as Array).size() % 4 == 0, "%s: гребни кратны 4" % n)
				check(is_finite(float(fr.cloudbase_msl)), "%s: база облаков конечна" % n)
	for t in TAGS:
		check(seen.has(t), "метка %s встречается хотя бы в одном случае" % t)


## Дневной случай (набор 2): условия-прогноз, t_apply и моменты, подписи точек.
func _check_day(n: String, c: Dictionary) -> void:
	var cond: Dictionary = c.conditions
	check(cond.has("forecast") and not cond.has("preset"), "%s: условия — прогноз" % n)
	var fc: Dictionary = cond.get("forecast", {})
	for k in ["temperature_c", "wind_speed_kmh", "wind_from_deg"]:
		check(fc.get(k) is float and is_finite(float(fc[k])), "%s: forecast.%s" % [n, k])
	check(["clear", "partly", "overcast"].has(String(fc.get("sky", ""))), "%s: forecast.sky" % n)
	var sh := float(cond.get("start_hour", 0.0))
	check(sh >= 10.0 and sh <= 12.0, "%s: start_hour 10…12" % n)
	check(float(cond.get("speed", 0.0)) == 1.0, "%s: speed 1" % n)
	check(float(cond.get("quantum_h", 0.0)) > 0.0, "%s: quantum_h" % n)
	check(not cond.has("inflow" + "_mode"), "%s: режима притока нет (WF-К1)" % n)
	check((cond.get("overrides", {}) as Dictionary).has("thermal_spacing_m"), "%s: overrides.thermal_spacing_m" % n)
	var wr: Dictionary = cond.get("wind_ref", {})
	check(wr.has("ref_msl") and wr.has("gain_per_km"), "%s: wind_ref" % n)
	var x: Dictionary = c.extra
	var ta: Array = x.get("t_apply", [])
	check(ta.size() >= 1, "%s: extra.t_apply — хотя бы одна подача поля в полёте" % n)
	for t: Variant in ta:
		check(t is float and is_finite(float(t)) and float(t) > 0.0 and float(t) <= 3600.0, "%s: t_apply в (0, 3600]" % n)
	var blend := float(x.get("blend_s", 0.0))
	check(blend > 0.0, "%s: extra.blend_s > 0" % n)
	check(x.get("window_levels_m") is Array and (x.window_levels_m as Array).size() == 2, "%s: окна 100/50" % n)
	var ts: Array = c.times_s
	if ts.size() == 4 and ta.size() >= 1:
		check(float(ts[0]) == 0.0, "%s: момент 0 — после загрузки" % n)
		check(float(ts[3]) == 3600.0, "%s: последний момент 3600 с" % n)
		var dt := float(x.get("dt_s", 0.25))
		check(absf(float(ts[1]) - (float(ta[0]) + 0.5 * blend)) <= dt, "%s: момент 1 — середина подмены" % n)
		check(absf(float(ts[2]) - (float(ta[0]) + blend + 30.0)) <= dt, "%s: момент 2 — подмена + 30 с" % n)
	var labels: Array = x.get("point_labels", [])
	check(labels.size() == (c.points as Array).size(), "%s: подписей точек столько же, сколько точек" % n)
	var edges := {}
	for i in mini(labels.size(), (c.point_tags as Array).size()):
		if String(labels[i]).begins_with("edge_"):
			check(c.point_tags[i] == "field_edge", "%s: подпись edge_* только у field_edge" % n)
			edges[String(labels[i])] = true
	check(edges.has("edge_50_100") and edges.has("edge_100_400"), "%s: есть точки на границах окон 100/50 и 100/400" % n)
	check(labels.has("L50"), "%s: есть точки внутри окна 50 м" % n)


## Набор 2: дневных случаев не меньше трёх, есть ветер ≥ 25 км/ч и ≤ 15 км/ч.
func test_day_cases_set() -> void:
	var days := 0
	var strong := 0
	var weak := 0
	for n in _cases():
		if not n.begins_with("ongudai_day"):
			continue
		days += 1
		var c: Dictionary = _json(ROOT.path_join("cases/%s.json" % n))
		var w := float((c.conditions.forecast as Dictionary).get("wind_speed_kmh", 0.0))
		strong += 1 if w >= 25.0 else 0
		weak += 1 if w >= 10.0 and w <= 15.0 else 0
	check(days >= 3, "дневных случаев не меньше трёх: %d" % days)
	check(strong >= 1 and weak >= 1, "есть ветер ≥ 25 км/ч (%d) и 10…15 км/ч (%d)" % [strong, weak])


## В найденном сильном ядре (в кадре без Cb) средний vy на оси в середине столба > 0 по выборке MEAN.
func test_core_updraft_in_samples() -> void:
	var checked := 0
	for n in _cases():
		var c: Dictionary = _json(ROOT.path_join("cases/%s.json" % n))
		var d: Dictionary = _json(ROOT.path_join("cases/%s.desc.json" % n))
		var vals := FileAccess.get_file_as_bytes(ROOT.path_join("cases/%s.bin" % n)).to_float32_array()
		var np := (c.points as Array).size()
		var nk := 2 + ((c.terms as Array).size() if c.terms is Array else 0)
		for k in (d.frames as Array).size():
			var cores: Array = d.frames[k].cores
			# в кадре с Cb рядом возможен нисходящий поток ливня над любым ядром — граница модели
			var has_cb := false
			for j in range(1, cores.size(), 15):
				has_cb = has_cb or (int(cores[j]) & 4) != 0
			if has_cb:
				continue
			for j in range(0, cores.size(), 15):
				var r := cores.slice(j, j + 15)
				if float(r[6]) < 2.0 or float(r[14]) > 0.0:
					continue
				var sum := 0.0
				var cnt := 0
				for i in np:
					if c.point_tags[i] != "thermal":
						continue
					var p: Array = c.points[i]
					var span := float(r[5]) - float(r[4])
					if absf(float(p[1]) - 0.5 * (float(r[4]) + float(r[5]))) > 0.2 * span:
						continue
					var ax := float(r[2]) + float(r[8]) * (float(p[1]) - float(r[4]))
					var az := float(r[3]) + float(r[9]) * (float(p[1]) - float(r[4]))
					if Vector2(float(p[0]) - ax, float(p[2]) - az).length() < 0.5 * float(r[7]):
						sum += vals[((k * np + i) * nk + 1) * 4 + 1]
						cnt += 1
				if cnt > 0:
					checked += 1
					check(sum / cnt > 0.0, "%s, момент %d, ядро %d: средний vy %.2f ≤ 0" % [n, k, int(r[0]), sum / cnt])
	check(checked >= 10, "проверено ядер: %d (нужно ≥ 10)" % checked)
