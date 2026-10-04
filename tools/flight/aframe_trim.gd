extends Node
## Балансировка для геометрии трапеции (AF-1, docs/contracts/aframe-geometry.md → A3.1): тангаж киля
## в установившемся планировании на скорости трима у каждого крыла и плечи пилота в полёте лёжа
## (трапеция в нейтрали) относительно HangPoint в осях крыла (x вправо, y вверх, z вперёд).
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/aframe_trim.tscn -- [--out=файл.json]
## Ответ: {"trim_pitch_deg": {крыло: °}, "shoulder_mid": [x, y, z]} (плечи — по крылу apogee).

const FlightSim := preload("res://tests/flight/flight_sim.gd")


func _ready() -> void:
	var out_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)
	var pitch := {}
	for c in Config.list_configs("wings"):
		var wing: String = c.get_file()
		var m := FlightSim.make(wing)
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		pitch[wing] = snappedf(rad_to_deg(m.theta), 0.001)
	var v := GliderVisual.new()
	add_child(v)
	v.build(Config.get_config("wings/apogee"), Config.get_config("pilot"), Config.get_config("flight").visual)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.5)
	v.set_pose(0.0, 0.0, true, 1.0e6)
	for i in 3:
		await get_tree().process_frame
	var hang := Vector3(0, float(Config.get_config("flight").visual.hang_height_m), 0)
	var mid := ((v.shoulder(-1) + v.shoulder(1)) * 0.5) - hang
	var res := {"trim_pitch_deg": pitch, "shoulder_mid": [snappedf(mid.x, 0.0001), snappedf(mid.y, 0.0001), snappedf(-mid.z, 0.0001)]}
	var txt := JSON.stringify(res, "  ")
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(txt)
	print(txt)
	get_tree().quit(0)
