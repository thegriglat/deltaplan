extends TestCase
## Формат эталонов ветра tests/fixtures/wind/ (rust-wind W8, RW-1): схема json, длины .bin, конечные
## числа, теги точек, растры мест, согласие описаний ядер с выборкой (в ядре средний vy > 0).
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
		if f.ends_with(".json") and not f.ends_with(".desc.json"):
			out.append(f.get_basename())
	out.sort()
	return out


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
		check((c.times_s as Array).size() == 3, "%s: три момента" % n)
		var np := (c.points as Array).size()
		check(np > 0 and (c.point_tags as Array).size() == np, "%s: тегов столько же, сколько точек" % n)
		for p: Array in c.points:
			check(p.size() == 3 and is_finite(float(p[0])) and is_finite(float(p[1])) and is_finite(float(p[2])), "%s: точка конечна" % n)
		for t: String in c.point_tags:
			check(TAGS.has(t), "%s: тег %s из набора" % [n, t])
			seen[t] = true
		for f: Array in c.focuses:
			check(f.size() == 4 and float(f[3]) > 0.0, "%s: фокус [x, y, z, w>0]" % n)
		check(c.terms == null, "%s: слагаемых нет (первый набор)" % n)
		# данные
		var bin := FileAccess.get_file_as_bytes(ROOT.path_join("cases/%s.bin" % n))
		var need: int = (c.times_s as Array).size() * np * 2 * 4 * 4
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
		check(d is Dictionary and (d.frames as Array).size() == 3, "%s: описания на три момента" % n)
		if d is Dictionary:
			for fr: Dictionary in d.frames:
				check((fr.cores as Array).size() % 15 == 0, "%s: ядра кратны 15" % n)
				check((fr.clouds as Array).size() % 10 == 0, "%s: облака кратны 10" % n)
				check((fr.crests as Array).size() % 4 == 0, "%s: гребни кратны 4" % n)
				check(is_finite(float(fr.cloudbase_msl)), "%s: база облаков конечна" % n)
	for t in TAGS:
		check(seen.has(t), "метка %s встречается хотя бы в одном случае" % t)


## В найденном сильном ядре (в кадре без Cb) средний vy на оси в середине столба > 0 по выборке MEAN.
func test_core_updraft_in_samples() -> void:
	var checked := 0
	for n in _cases():
		var c: Dictionary = _json(ROOT.path_join("cases/%s.json" % n))
		var d: Dictionary = _json(ROOT.path_join("cases/%s.desc.json" % n))
		var vals := FileAccess.get_file_as_bytes(ROOT.path_join("cases/%s.bin" % n)).to_float32_array()
		var np := (c.points as Array).size()
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
						sum += vals[((k * np + i) * 2 + 1) * 4 + 1]
						cnt += 1
				if cnt > 0:
					checked += 1
					check(sum / cnt > 0.0, "%s, момент %d, ядро %d: средний vy %.2f ≤ 0" % [n, k, int(r[0]), sum / cnt])
	check(checked >= 10, "проверено ядер: %d (нужно ≥ 10)" % checked)
