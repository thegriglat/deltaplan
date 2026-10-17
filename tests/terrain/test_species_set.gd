extends TestCase
## RV-К2: набор пород места. Эталон «Алтай не изменился» снят на ветке до правки TreePlacer
## (набор по умолчанию — те же экземпляры: порода, вариант, LOD, позиции, масштабы, цвета).

const OLD_SET: PackedStringArray = ["pine", "cedar", "larch", "birch", "spruce"]

## Эталон: место → список центров → {counts: число по "порода/вариант/lod", sums: суммы x, z, y, масштаб, цвет,
## альфа-код}. Снят до правки; пересъёмка — DUMP_SPECIES_REF=<файл> и test_dump (только если поведение менялось
## осознанно).
const REF_PATH := "res://tests/fixtures/species_set/ref.json"
const REF_UNIFORMS_PATH := "res://tests/fixtures/species_set/ref_uniforms.json"


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
	cfg["set"] = ["pine", "cedar", "larch", "birch", "spruce", "oak", "palm"]
	check(TreePlacer.species_set(cfg).size() == 6, "седьмая отброшена")
	cfg["set"] = ["pine", "pine", "baobab", "birch"]
	check(TreePlacer.species_set(cfg) == PackedStringArray(["pine", "birch"]), "повтор и неизвестное имя пропущены, остальные остались")
	for empty in [[], ["baobab"]]:
		cfg["set"] = empty
		check(TreePlacer.species_set(cfg).is_empty(), "пустой набор %s - пусто, не алтайская тайга" % [empty])


func test_empty_set_no_trees_no_crash() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location("altai"), "место altai")
	var cfg: Dictionary = Config.get_config("world").trees.duplicate(true)
	cfg["set"] = []
	var p := TreePlacer.new()
	p.setup(t.layers[0], t.surfaces[0], cfg)
	var site: Dictionary = t.get_start_sites()[0]
	p.build(Vector2(site.position.x, site.position.z))
	check(p.species.is_empty() and p.buffers.is_empty() and p.counts.is_empty(), "деревьев нет")
	var m := TerrainTreeModels.new()
	check(m.setup(t.layers[0], t.surfaces[0], cfg), "модели при пустом наборе не падают")
	check(m.get_child_count() == 0, "MultiMesh'ей нет")
	m.free()
	var u := TreeCrosses.species_uniforms(cfg, TreePlacer.species_set(cfg))
	check(u["sp_count"] == 0 and (u["sp_weight"] as PackedFloat32Array).size() == TreePlacer.MAX_SPECIES, "uniform крестов: sp_count 0, слоты нейтральные")
	var ui := ForestImpostors.species_uniforms(cfg, TreePlacer.species_set(cfg))
	check(ui["sp_count"] == 0, "uniform импостеров: sp_count 0")
	t.free()


## Значения uniform крестов и импостеров при наборе по умолчанию совпадают с эталоном (снят до правки с
## материалов Terrain; ref_uniforms.json), хвост массивов до MAX_SP нейтральный; kind/conifer/cell - прежние константы.
func test_default_uniforms_unchanged() -> void:
	var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF_UNIFORMS_PATH))
	var world: Dictionary = Config.get_config("world").trees
	var all := {}
	for loc: String in ref:
		var cfg := TreePlacer.with_vegetation(Config._deep_merge(world, Config.get_config("locations/" + loc).get("trees", {})))
		var set := TreePlacer.species_set(cfg)
		all[loc] = {"crosses": TreeCrosses.species_uniforms(cfg, set), "impostors": ForestImpostors.species_uniforms(cfg, set)}
	for loc: String in ref:
		var got: Dictionary = all[loc]
		for kind: String in ref[loc]:
			var want: Dictionary = ref[loc][kind]
			for key: String in want:
				check(got[kind].has(key), "%s.%s: есть %s" % [loc, kind, key])
				var w: Array = want[key]
				check(w.size() == 5 and got[kind][key].size() == TreePlacer.MAX_SPECIES, "%s.%s.%s: 5 → 6 слотов" % [loc, kind, key])
				for k in w.size():
					var g: Variant = got[kind][key][k]
					if g is Vector2:
						approx(g.x, float(w[k][0]), 1e-6, "%s.%s.%s[%d].x" % [loc, kind, key, k])
						approx(g.y, float(w[k][1]), 1e-6, "%s.%s.%s[%d].y" % [loc, kind, key, k])
					else:
						approx(float(g), float(w[k]), 1e-6, "%s.%s.%s[%d]" % [loc, kind, key, k])
	var got: Dictionary = all["altai"]
	for kind: String in got:
		var u: Dictionary = got[kind]
		check(u["sp_count"] == 5, kind + ": sp_count 5")
		check(Array(u["sp_kind"]).slice(0, 5) == [0.0, 0.0, 2.0, 1.0, 0.0], kind + ": sp_kind как SL_KIND/SL_DECID")
		check(float(u["sp_weight"][5]) == 0.0, kind + ": шестой слот не выбирается (вес 0)")
	check(Array(got["impostors"]["sp_conifer"]).slice(0, 5) == [1.0, 1.0, 0.0, 0.0, 1.0], "sp_conifer как SL_CONIFER")
	check(Array(got["impostors"]["sp_cell"]).slice(0, 5) == [0.0, 1.0, 2.0, 3.0, 4.0], "sp_cell = прежние sp % 4, sp / 4")


## Набор [birch, pine, larch]: sp_count 3, ячейки атласа 3,0,2, kind 1,0,2, conifer 0,1,0; параметры - своих пород.
func test_three_species_uniforms() -> void:
	var cfg: Dictionary = Config.get_config("world").trees.duplicate(true)
	cfg["set"] = ["birch", "pine", "larch"]
	var set := TreePlacer.species_set(cfg)
	check(set.size() == 3, "набор из трёх")
	var ui := ForestImpostors.species_uniforms(cfg, set)
	var uc := TreeCrosses.species_uniforms(cfg, set)
	check(ui["sp_count"] == 3 and uc["sp_count"] == 3, "sp_count 3")
	check(Array(ui["sp_cell"]).slice(0, 3) == [3.0, 0.0, 2.0], "sp_cell 3,0,2")
	check(Array(ui["sp_kind"]).slice(0, 3) == [1.0, 0.0, 2.0], "импостеры: sp_kind 1,0,2")
	check(Array(uc["sp_kind"]).slice(0, 3) == [1.0, 0.0, 2.0], "кресты: sp_kind 1,0,2")
	check(Array(ui["sp_conifer"]).slice(0, 3) == [0.0, 1.0, 0.0], "sp_conifer 0,1,0")
	var sp: Dictionary = cfg["species"]
	approx(float(uc["sp_weight"][0]), float(sp["birch"]["weight"]), 1e-6, "вес birch в слоте 0")
	approx(float(uc["sp_weight"][1]), float(sp["pine"]["weight"]), 1e-6, "вес pine в слоте 1")
	approx(float(uc["sp_weight"][2]), float(sp["larch"]["weight"]), 1e-6, "вес larch в слоте 2")
	approx(float(uc["sp_gain"][0]), TerrainTreeModels.albedo_gain_for(cfg, "birch", 1), 1e-6, "gain креста birch")
	approx(float(ui["sp_gain"][0]), TerrainTreeModels.albedo_gain_for(cfg, "birch", 2), 1e-6, "gain билборда birch")
	for k in range(3, TreePlacer.MAX_SPECIES):
		check(float(uc["sp_weight"][k]) == 0.0 and float(ui["sp_weight"][k]) == 0.0, "слот %d не выбирается" % k)


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
