extends TestCase
## FL-7: сцена породы собирается один раз на все варианты; меши те же, что по одному варианту;
## фоновая загрузка (request_preload) отдаёт ту же сцену.


func test_species_load_matches_per_variant() -> void:
	var models: Dictionary = Config.get_config("world").get("trees", {}).get("models", {})
	var path := String(models.get("pine", ""))
	check(path != "", "путь модели сосны есть")
	TerrainTreeModels.request_preload(models)
	var all := TerrainTreeModels._load_species(path, 8)
	check(all.size() == 8, "8 вариантов из одной сборки: %d" % all.size())
	for v in all.size():
		var one := TerrainTreeModels._load_lods(path, v)
		check(one.size() == 3 and all[v].size() == 3, "вариант %d: 3 LOD" % v)
		if one.size() == 3:
			check(
				one[0].get_aabb() == (all[v][0] as Mesh).get_aabb(), "вариант %d: LOD0 тот же" % v
			)
	check(TerrainTreeModels._load_species("", 8).is_empty(), "нет пути — пусто")
