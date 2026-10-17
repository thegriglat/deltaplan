extends Node
## Сканирование среднего поля воздуха (mean_wind_at) вокруг старта: сетка ±R, три высоты над землёй.
## Запуск: godot --path . res://tools/research/lee_cal/air_scan.tscn -- --autostart ... --out=<json> --R=2400 --step=100
const MAIN_SCENE := preload("res://scenes/main.tscn")
var _out := ""
var _r := 2400.0
var _step := 100.0
var _main: Node = null

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.substr(2).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out": _out = v
			"R": _r = float(v)
			"step": _step = float(v)
	_run()

func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	var t0 := Time.get_ticks_msec()
	while int(_main.get("state")) != 2 and Time.get_ticks_msec() - t0 < 900000:
		await get_tree().process_frame
	var g: Game = _main.get_node("Game")
	await get_tree().create_timer(3.0, true, false, true).timeout
	var c: Vector3 = g.glider.global_position
	var rows := []
	var aglv := [30.0, 100.0, 200.0]
	var n := int(_r / _step)
	for iz in range(-n, n + 1):
		for ix in range(-n, n + 1):
			var x := c.x + ix * _step
			var z := c.z + iz * _step
			var gh: float = g.terrain.height_at(x, z)
			var row := [snappedf(x, 1), snappedf(z, 1), snappedf(gh, 0.1)]
			for a in aglv:
				var w: Vector3 = g.air.mean_wind_at(Vector3(x, gh + a, z))
				row.append_array([snappedf(w.x, 0.01), snappedf(w.z, 0.01), snappedf(w.y, 0.01)])
			rows.append(row)
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify({"center": [c.x, c.z], "agl": aglv, "field_on": g.air.is_air_field_on(), "cols": "x,z,ground,(u,v,w)x3 (east,south,up)", "rows": rows}))
	f.close()
	print("air_scan: OK ", _out, " field=", g.air.is_air_field_on(), " rows=", rows.size())
	_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(0)
