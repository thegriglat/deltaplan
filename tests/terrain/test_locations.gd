extends TestCase
## Все встроенные локации: данные на месте, старты на склоне вниз по курсу, посадки пологие.

const LOCATIONS := ["altai", "ongudai", "askarovo", "aushkul", "training_island", "volcano_island"]


func test_locations() -> void:
	for id: String in LOCATIONS:
		var t := Terrain.new()
		t.location_id = ""
		var ok := t.load_location(id)
		check(ok, "%s загружена" % id)
		if not ok:
			t.free()
			continue
		check(t.last_load_time_s < 10.0, "%s: загрузка %.2f с (NFR-2)" % [id, t.last_load_time_s])
		for s in t.surfaces:
			# вымышленное место: карта классов синтетическая, не WorldCover (источник слой не хранит)
			check(Locations.is_synthetic(id) or s.source == "worldcover", "%s/%s: карта WorldCover" % [id, s.id])
		var sites := t.get_start_sites()
		var max_sites := 4 if Locations.is_synthetic(id) or id == "volcano_island" else 3
		check(sites.size() >= 1 and sites.size() <= max_sites, "%s: 1–%d старта" % [id, max_sites])
		for site in sites:
			_check_site(t, id, site)
		for land in t.get_landing_sites():
			var p: Vector3 = land.position
			var slope := rad_to_deg(acos(t.normal_at(p.x, p.z).y))
			check(slope < 10.0, "%s/%s: посадка пологая (%.1f°)" % [id, land.id, slope])
			var c := t.surface_at(p.x, p.z)
			check(
				c != SurfaceLayer.WATER and c != SurfaceLayer.FOREST,
				"%s/%s: посадка не в лесу и не в воде (класс %d)" % [id, land.id, c]
			)
		t.free()


func _check_site(t: Terrain, id: String, site: Dictionary) -> void:
	var p: Vector3 = site.position
	var slope := rad_to_deg(acos(t.normal_at(p.x, p.z).y))
	check(slope > 8.0 and slope < 35.0, "%s/%s: уклон старта %.1f°" % [id, site.id, slope])
	var fwd := TerrainGeo.heading_vector(float(site.heading_deg))
	var ahead := p + fwd * 60.0
	check(
		t.height_at(ahead.x, ahead.z) < p.y - 5.0,
		"%s/%s: по курсу вниз (%.0f → %.0f м)" % [id, site.id, p.y, t.height_at(ahead.x, ahead.z)]
	)
	check(t.surface_at(p.x, p.z) != SurfaceLayer.FOREST, "%s/%s: старт не в лесу" % [id, site.id])
