extends TestCase
## RV-К2: набор пород места. Эталон «Алтай не изменился» снят на ветке до правки TreePlacer
## (набор по умолчанию — те же экземпляры: порода, вариант, LOD, позиции, масштабы, цвета).

const OLD_SET: PackedStringArray = ["pine", "cedar", "larch", "birch", "spruce"]

## Эталон: место → список центров → {counts: число по "порода/вариант/lod", sums: суммы x, z, y, масштаб, цвет,
## альфа-код}. Снят до правки; пересъёмка — DUMP_SPECIES_REF=<файл> и test_dump (только если поведение менялось
## осознанно).
const REF_PATH := "res://tests/fixtures/species_set/ref.json"


static func fingerprint(p: TreePlacer, names: PackedStringArray) -> Dictionary:
	var counts := {}
	var sums := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for b in p.buffers.size():
		var n := p.counts[b]
		if n == 0:
			continue
		var lod := b % 3
		var mv := b / 3
		counts["%s/%d/%d" % [names[mv / p.variants], mv % p.variants, lod]] = n
		var buf := p.buffers[b]
		for k in n:
			var o := k * TreePlacer.STRIDE
			sums[0] += buf[o + 3]
			sums[1] += buf[o + 11]
			sums[2] += buf[o + 7]
			sums[3] += buf[o + 5]
			sums[4] += buf[o + 12]
			sums[5] += buf[o + 15]
	return {"counts": counts, "sums": Array(sums)}


func _fingerprints(loc: String, names: PackedStringArray) -> Array:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location(loc), "место " + loc)
	var cfg: Dictionary = Config.get_config("world").trees
	var p := TreePlacer.new()
	p.setup(t.layers[0], t.surfaces[0], cfg)
	var site: Dictionary = t.get_start_sites()[0]
	var c0 := Vector2(site.position.x, site.position.z)
	var out := []
	for c in [c0, c0 + Vector2(900.0, -700.0)]:
		p.build(c)
		out.append(fingerprint(p, names))
	t.free()
	return out


func test_dump() -> void:
	if OS.get_environment("DUMP_SPECIES_REF") == "":
		return
	var all := {}
	for loc in ["ongudai", "altai"]:
		all[loc] = _fingerprints(loc, OLD_SET)
	var f := FileAccess.open(OS.get_environment("DUMP_SPECIES_REF"), FileAccess.WRITE)
	f.store_string(JSON.stringify(all, "\t"))


func test_altai_unchanged() -> void:
	var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF_PATH))
	for loc: String in ref:
		var got := _fingerprints(loc, TreePlacer.DEFAULT_SET)
		var want: Array = ref[loc]
		for i in want.size():
			var w: Dictionary = want[i]
			var g: Dictionary = got[i]
			var same: bool = g.counts.size() == w.counts.size()
			for key: String in w.counts:
				same = same and g.counts.get(key, -1) == int(w.counts[key])
			check(same, "%s #%d: экземпляры по (порода, вариант, LOD) те же" % [loc, i])
			check(g.counts.size() >= 20, "%s #%d: эталон непустой (%d групп)" % [loc, i, g.counts.size()])
			for k in 6:
				approx(float(g.sums[k]), float(w.sums[k]), absf(float(w.sums[k])) * 1e-6 + 1e-6, "%s #%d: сумма %d" % [loc, i, k])


func test_registry_matches_old_constants() -> void:
	var cfg: Dictionary = Config.get_config("world").trees
	check(TreePlacer.species_set(cfg) == TreePlacer.DEFAULT_SET, "набор по умолчанию — старые пять")
	var kind := [0.0, 0.0, 2.0, 1.0, 0.0]
	var con := [true, true, false, false, true]
	for k in 5:
		var sp := TreePlacer.DEFAULT_SET[k]
		approx(TreePlacer.kind_of(cfg, sp), kind[k], 1e-9, "season_kind " + sp)
		check(TreePlacer.conifer_of(cfg, sp) == con[k], "conifer " + sp)
		check(TreePlacer.atlas_cell_of(cfg, sp) == k, "atlas_cell " + sp)


func test_set_validation() -> void:
	var cfg: Dictionary = Config.get_config("world").trees.duplicate(true)
	cfg["set"] = ["birch", "pine", "oak"]
	check(TreePlacer.species_set(cfg) == PackedStringArray(["birch", "pine", "oak"]), "набор из трёх, порядок сохранён")
	cfg["set"] = ["pine", "cedar", "larch", "birch", "spruce", "oak"]
	check(TreePlacer.species_set(cfg).size() == 6, "шесть допустимо")
	for bad in [[], ["pine", "cedar", "larch", "birch", "spruce", "oak", "palm"], ["pine", "pine"], ["pine", "baobab"]]:
		cfg["set"] = bad
		check(TreePlacer.species_set(cfg) == TreePlacer.DEFAULT_SET, "негодный набор %s — по умолчанию" % [bad])


func test_placer_uses_set() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location("altai"), "место altai")
	var cfg: Dictionary = Config.get_config("world").trees.duplicate(true)
	cfg["set"] = ["birch", "spruce"]
	var p := TreePlacer.new()
	p.setup(t.layers[0], t.surfaces[0], cfg)
	check(p.species == PackedStringArray(["birch", "spruce"]), "species из set")
	check(p.buffers.is_empty() and p.model_height.size() == 2 * p.variants, "model_height на 2 породы")
	var site: Dictionary = t.get_start_sites()[0]
	p.build(Vector2(site.position.x, site.position.z))
	check(p.buffers.size() == 2 * p.variants * 3, "буферов: порода × вариант × LOD")
	var total := 0
	for n in p.counts:
		total += n
	check(total > 100, "деревья расставлены: %d" % total)
	t.free()


func test_models_load_only_set() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location("altai"), "место altai")
	var cfg: Dictionary = Config.get_config("world").trees.duplicate(true)
	cfg["set"] = ["larch", "birch"]
	var m := TerrainTreeModels.new()
	check(m.setup(t.layers[0], t.surfaces[0], cfg), "модели набора загружены")
	check(m.get_child_count() == 2 * m.placer.variants * 3, "MultiMesh'ей: порода × вариант × LOD")
	check(m.get_child(0).name.begins_with("larch_"), "первая порода набора — larch")
	var kinds := {}
	for mat in m.materials:
		kinds[mat.get_shader_parameter("sl_tree_kind")] = true
	check(kinds.has(1.0) and kinds.has(2.0) and not kinds.has(0.0), "season_kind материалов — из реестра: %s" % [kinds.keys()])
	m.free()
	t.free()
