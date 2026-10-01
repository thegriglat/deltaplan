extends Node
## Б2: α / max_profile и профиль WindModel из игры (WindProfile, WindModel) для Онгудая в часы
## старта — сверка с эталоном (tools/research/b2/table.py → out/profile_table.md).
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/b2/game_profile.tscn


func _ready() -> void:
	var loc: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://configs/locations/ongudai.json")
	)
	var rc := WeatherModel.reference_context()
	var ctx := {
		month = int(rc.get("month", 7)), day = int(rc.get("day", 15)), lat = float(loc.center_lat),
		lon = float(loc.center_lon), utc_offset_h = float(loc.utc_offset_h)
	}
	var cfg: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://configs/atmosphere.json")
	)
	print("час | солнце | облачность | U10 | класс | α | max_profile | WindModel 10/50/100/300")
	for hour in [6.0, 9.0, 12.0, 15.0, 20.0, 20.5, 21.0]:
		var sun := WindProfile.sun_elevation(ctx, hour)
		for sky in ["clear", "partly", "overcast"]:
			var cover := float(WeatherModel.sky_params(sky).get("cover", 0.0))
			for u in [0.0, 3.0, 6.0]:
				var k := WindProfile.stability_class(u, sun, cover)
				var a := WindProfile.alpha(u, sun, cover)
				var mp := WindProfile.max_profile(a, u, AirCase.Z0, AirCase.F_COR, k)
				var wm := WindModel.new()
				wm.setup(cfg.wind, cfg.turbulence, 1)
				wm.set_conditions(sun, cover)
				wm.set_wind(u, 150.0)
				print(
					"%s | %.2f | %s | %s | %s | %.6f | %.6f | %.3f %.3f %.3f %.3f"
					% [hour, sun, sky, u, WindProfile.CLASSES[k], a, mp, wm.profile(10.0), wm.profile(50.0),
						wm.profile(100.0), wm.profile(300.0)]
				)
	get_tree().quit()
