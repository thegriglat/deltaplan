extends SceneTree
## Паритет SurfaceStage со встроенным местом (OA-3): собирает покров askarovo по configs/locations/askarovo.json
## и сравнивает с data/terrain/askarovo/{detail,far}_surface.png и detail_detail10.png (канал L).
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s res://tools/terrain/parity/surface_parity.gd
## Кеш COG — ~/.cache/deltaplan_parity/ (постоянный); кеш Python ~/.cache/deltaplan_terrain/cog читается как
## запасной (только чтение). DP_PARITY_NOFALLBACK=1 — без запасного кеша (проверка пути HTTP).
## Печатает class_agree_detail, class_agree_far, forest_frac_diff, detail10_l_mae, stage_seconds.

const LOC := "askarovo"
const OUT_DIR := "user://parity_surface"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame  # автозагрузки появляются после первого кадра
	var code := await _main()
	quit(code)


func _main() -> int:
	var home := OS.get_environment("HOME")
	var cfg: Dictionary = _cfg("locations/" + LOC)
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/terrain/%s/meta.json" % LOC))
	var ctx := LocationBuildContext.new()
	ctx.key = LOC
	ctx.center_lat = float(meta.center_lat)
	ctx.center_lon = float(meta.center_lon)
	ctx.dir = OUT_DIR
	ctx.spec = cfg
	ctx.host = root
	for l: Dictionary in meta.layers:
		ctx.layers[l.id] = l
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# скрипты с автозагрузками грузим в рабочем режиме: при компиляции -s-скрипта автозагрузок ещё нет
	var stage = load("res://scripts/terrain/build/surface_stage.gd").new()
	stage.cache_dir = home + "/.cache/deltaplan_parity"
	if OS.get_environment("DP_PARITY_NOFALLBACK") != "1":
		stage.extra_cache_dirs = PackedStringArray([home + "/.cache/deltaplan_terrain/cog"])
	# прогрев кеша (возможна сеть), затем замер при прогретом кеше без сети
	var t0 := Time.get_ticks_msec()
	var err: int = await stage.run(ctx)
	print("warmup: err=%s net_requests=%d секунд=%.1f" % [error_string(err), ctx.net_requests, (Time.get_ticks_msec() - t0) / 1000.0])
	if err != OK:
		print("\n".join(ctx.log_lines))
		return 1
	ctx.offline = true
	ctx.net_requests = 0
	t0 = Time.get_ticks_msec()
	err = await stage.run(ctx)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	if err != OK or ctx.net_requests != 0:
		print("повторный прогон: err=%s net=%d\n%s" % [error_string(err), ctx.net_requests, "\n".join(ctx.log_lines)])
		return 1

	var ref_dir := "res://data/terrain/" + LOC
	for id: String in ["detail", "far"]:
		var a := Image.load_from_file(OUT_DIR + "/%s_surface.png" % id).get_data()
		var b := Image.load_from_file(ref_dir + "/%s_surface.png" % id).get_data()
		print("class_agree_%s=%.5f" % [id, _agree(a, b)])
	var m10 := Image.load_from_file(OUT_DIR + "/detail_detail10.png")
	var r10 := Image.load_from_file(ref_dir + "/detail_detail10.png")
	var da := m10.get_data()
	var db := r10.get_data()
	print("detail10: %dx%d fmt=%d / %dx%d fmt=%d" % [m10.get_width(), m10.get_height(), m10.get_format(), r10.get_width(), r10.get_height(), r10.get_format()])
	var n := da.size() / 2
	var sum_abs := 0
	var fa := 0
	var fb := 0
	var alpha_nonzero := 0
	for i in n:
		var x := da[2 * i]
		var y := db[2 * i]
		sum_abs += absi(x - y)
		if x >= 128:
			fa += 1
		if y >= 128:
			fb += 1
		if da[2 * i + 1] != 0:
			alpha_nonzero += 1
	print("forest_frac_mine=%.5f forest_frac_ref=%.5f alpha_nonzero=%d" % [float(fa) / n, float(fb) / n, alpha_nonzero])
	print("forest_frac_diff=%.5f" % absf(float(fa - fb) / n))
	print("detail10_l_mae=%.4f" % (float(sum_abs) / n))
	print("stage_seconds=%.2f" % secs)
	return 0


func _cfg(name: String) -> Dictionary:
	return root.get_node("/root/Config").call("get_config", name)


func _agree(a: PackedByteArray, b: PackedByteArray) -> float:
	if a.size() != b.size():
		return 0.0
	var same := 0
	for i in a.size():
		if a[i] == b[i]:
			same += 1
	return float(same) / a.size()
