extends TestCase
## W5 v7 (RW-6v): AirPlaceData.fill_climate кладёт loc.climate_lag — климат той же ячейки на дату
## month/day − round(water.lag_days) с переходом через год (SurfaceHeat.water_temp_c). Числа
## (учебный и вулканический острова) — из разбора RW-6q; сверяется разность lag − дата места: высота долины острова
## входит в обе ячейки одинаково, поэтому не зависит от плоского места теста. Эталон — ClimateGrid.place.
## Нет сеток климата (свежая копия без data/climate) — has_hh5 = false, числа не проверяются.


## Плоское место 5 x 5 на нулевой высоте (острова у уровня моря) с центром (lat, lon).
func _place(lat: float, lon: float, month: int, day: int) -> AirPlaceData:
	var n := 25
	var heights := PackedFloat32Array()
	heights.resize(n)
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	var moist := PackedFloat32Array()
	moist.resize(n)
	moist.fill(0.5)
	var loc := {
		"id": "t", "center_lat": lat, "center_lon": lon, "utc_offset_h": 0.0, "month": month, "day": day
	}
	var grid := {"origin_x": -100.0, "origin_z": -100.0, "spacing": 50.0, "width": 5, "height": 5}
	return AirPlaceData.from_arrays(AirPlaceData.make_header(loc, grid, []), heights, water, cls, moist)


func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _case(tag: String, lat: float, lon: float, m: int, d: int, want: Array, want_lag: Array) -> void:
	var p := _place(lat, lon, m, d)
	p.fill_climate()
	var loc: Dictionary = p.header.loc
	check(loc.has("climate") and loc.has("climate_lag"), "%s: climate и climate_lag в loc" % tag)
	var c: Dictionary = loc.climate
	var l: Dictionary = loc.climate_lag
	for k in ["tx_c", "dtr_k", "z_cell_m", "has_hh1", "has_hh5"]:
		check(l.has(k), "%s: climate_lag.%s" % [tag, k])
	if not bool(c.has_hh5):
		return
	var d_tx := float(l.tx_c) - float(c.tx_c)
	var d_dtr := float(l.dtr_k) - float(c.dtr_k)
	check(_near(d_tx, want_lag[0] - want[0], 0.002) and _near(d_dtr, want_lag[1] - want[1], 0.002),
		"%s: lag − %d.%02d = (%s, %s), ждали (%s, %s)" % [tag, d, m, d_tx, d_dtr, want_lag[0] - want[0], want_lag[1] - want[1]])
	# тот же порядок величины, что в разборе (высота долины острова сдвигает обе на доли К)
	check(_near(float(c.tx_c), want[0], 0.2) and _near(float(l.tx_c), want_lag[0], 0.2), "%s: tx_c около %s / %s" % [tag, want[0], want_lag[0]])


func test_training_island_lag_is_a_month_back() -> void:
	_case("учебный", 43.2, 34.0, 7, 15, [24.839, 1.385], [22.228, 1.436])


func test_volcano_island_lag_crosses_the_year() -> void:
	_case("вулканический", -27.1, -109.35, 1, 15, [23.579, 0.945], [22.361, 0.968])


func test_lag_equals_climate_grid_on_the_shifted_date() -> void:
	var p := _place(51.5, 86.5, 3, 10)
	p.fill_climate()
	var lag := int(round(float(SurfaceHeat.config().water.lag_days)))
	var md := SurfaceHeat._month_day(SunClock.day_of_year(3, 10) - lag + (365 if SunClock.day_of_year(3, 10) - lag < 1 else 0))
	var ctx := {"month": md.x, "day": md.y, "lat": 51.5, "lon": 86.5}
	ctx.merge(
		WeatherModel.ground_context(
			Callable(p, "height_at"),
			float(Config.get_config("atmosphere").ground.reference_radius_m),
			int(Config.get_config("atmosphere").ground.reference_samples),
			float(WeatherModel.config().valley_percentile)
		)
	)
	var cp := ClimateGrid.place(ctx)
	check(_near(float(p.header.loc.climate_lag.tx_c), float(cp.tx_c), 1e-9), "climate_lag.tx_c = ClimateGrid.place(дата сдвига)")
	check(_near(float(p.header.loc.climate_lag.dtr_k), float(cp.dtr_k), 1e-9), "climate_lag.dtr_k = ClimateGrid.place(дата сдвига)")
