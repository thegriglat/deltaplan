extends Node
## Подгонка длины подвески под крыло (A3.5 v8): для каждого крыла находит visual.hang_drop_m
## (configs/wings/<id>.json), при котором зазор низ тела — верх штанги в полёте на балансировке
## (по вертикали мира, киль под тангажем трима) равен pilot.json → visual.bar_gap_m.
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/hang_drop_fit.tscn -- [--out=файл.json]
## Ответ: {крыло: hang_drop_m}. Применяет tools/research/pilot_view/apply_hang_drop.py.
## Измерение — как в tests/game/test_aframe_contracts.gd → test_gap_every_wing.

const FlightSim := preload("res://tests/flight/flight_sim.gd")
const AFC := preload("res://tests/game/test_aframe_contracts.gd")


func _ready() -> void:
	var out_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)
	var gap_want := float(Config.get_config("pilot").visual.bar_gap_m)
	var bar_r := float(Config.get_config("pilot").visual.bar_radius_m)
	var res := {}
	for c in Config.list_configs("wings"):
		var wing: String = c.get_file()
		var m := FlightSim.make(wing)
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		var wc: Dictionary = Config.get_config("wings/" + wing).duplicate(true)
		wc.visual.erase("hang_drop_m")
		var v := GliderVisual.new()
		add_child(v)
		v.build(wc, Config.get_config("pilot"), Config.get_config("flight").visual)
		var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
		ap.play("prone", 0.0)
		ap.advance(0.5)
		v.basis = Basis(Vector3.RIGHT, m.theta)
		v.set_pose(0.0, 0.0, true, 1.0e6)
		for i in 3:
			await get_tree().process_frame
		var bar: Vector3 = v.global_transform * v._marker_pos("BaseBar")
		var low: float = AFC.new()._pilot_dims(v).torso_low_y
		var g0 := low - bar.y - bar_r
		res[wing] = snappedf(v.hang_drop_m + (g0 - gap_want) / cos(m.theta), 0.001)
		v.free()
	var txt := JSON.stringify(res, "  ")
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(txt)
	print(txt)
	get_tree().quit(0)
