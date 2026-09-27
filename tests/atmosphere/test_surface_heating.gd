extends TestCase
## Инерция прогрева (SurfaceHeating, фаза 2 погоды): камни и деревни греют дольше луга.


func test_rocks_lag_behind_meadow() -> void:
	var h := SurfaceHeating.new()
	h.setup(51.87, 85.87, 7, 15, 7.0)
	var d19 := h.directions(19.5)
	check(d19.size() == SurfaceLayer.CLASS_COUNT, "по направлению на класс")
	var meadow := d19[SurfaceLayer.GRASS]
	var rock := d19[SurfaceLayer.BARE]
	var built := d19[SurfaceLayer.BUILT]
	check(rock.y > meadow.y, "вечером камни «видят» солнце выше, чем луг")
	check(built.y > rock.y, "деревня — ещё дольше")
	# Утром наоборот: камни ещё холодные.
	var d8 := h.directions(8.0)
	check(d8[SurfaceLayer.BARE].y < d8[SurfaceLayer.GRASS].y, "утром камни отстают")
	# Ночью — ноль.
	check(h.directions(2.0)[SurfaceLayer.GRASS] == Vector3.ZERO, "ночью не греет")


func test_disabled_returns_empty() -> void:
	var cfg: Dictionary = WeatherModel.config().duplicate(true)
	cfg.heating.enabled = false
	var h := SurfaceHeating.new()
	h.setup(51.87, 85.87, 7, 15, 7.0, cfg)
	check(h.directions(13.0).is_empty(), "выключено — текущее солнце")
