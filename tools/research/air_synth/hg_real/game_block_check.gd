extends Node
## SY-10: сверка Python-конвейера (pack_hg.py) с кодом игры. Собирает слой detail вокруг точки КОДОМ ИГРЫ (TerrariumLoader._plan_layer +
## assemble по тайлам из кеша raw/terrarium/z/x/y.png) и берёт клетки 400 м как AirPlace.block_mean — теми же функциями, что в игре.
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path <копия> res://tools/research/air_synth/hg_real/game_block_check.tscn -- lat lon raw_dir out.f64
## Выход: out.f64 — 96·96 float64 (j с юга, i с запада) + заголовок в stdout: z, spacing, n, f=round(400/s).
func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	var lat := float(a[0])
	var lon := float(a[1])
	var raw_dir := String(a[2])
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/world.json"))
	var lc: Dictionary = {}
	for l: Dictionary in world.runtime_terrain.layers:
		if l.id == "detail":
			lc = l
	var loader := TerrariumLoader.new()
	var z := TerrariumLoader.layer_zoom(lc, lat)
	var plan: Dictionary = loader._plan_layer("detail", lat, lon, z, float(lc.size_km) * 1000.0, int(lc.chunk_cells))
	var raw := {}
	for t: Vector2i in plan.tiles:
		var n := 1 << z
		var path := "%s/terrarium/%d/%d/%d.png" % [raw_dir, z, posmod(t.x, n), clampi(t.y, 0, n - 1)]
		raw[t] = FileAccess.get_file_as_bytes(path)
	var r: Dictionary = TerrariumLoader.assemble(plan, raw)
	if r.has("error"):
		print("ERROR ", r.error)
		get_tree().quit(1)
		return
	var layer: HeightLayer = r.layer
	var hc := AirPlace.block_mean(layer, -19200.0, -19200.0, 400.0, 96, 96)
	print("HEADER z=%d spacing=%.9f n=%d f=%d empty=%s" % [z, plan.spacing, plan.n, roundi(400.0 / layer.spacing), hc.is_empty()])
	if not hc.is_empty():
		var f := FileAccess.open(String(a[3]), FileAccess.WRITE)
		f.store_buffer(hc.to_byte_array())
		f.close()
	get_tree().quit(0)
