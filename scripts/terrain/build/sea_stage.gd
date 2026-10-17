class_name SeaStage
extends RefCounted
## Стадия сборки места «море» (контракт S2, docs/contracts/sea-ships.md): после smooth, до osm_tiles.
## Читает far.webp, meta.json, far_surface.webp из ctx.dir; пишет far_sea.webp (WebP lossless, сетка far,
## значение — SeaMask.compute) и sea.json {"version": 2, "sea_cells", "components", "levels_m", "flattened_cells", "seconds"}.
## S2 v2: клетки моря в far.webp выравниваются до уровня воды их компоненты (мода высот, SeaMask), остальное не меняется;
## meta.json — min/max высот слоя.
## Нет far_surface.webp (или слоя far) — ERR_UNAVAILABLE: место без судов, следующая сборка дособерёт стадию.
## Счёт идёт в рабочем потоке (тысячи клеток на строку — секунды в GDScript), стадия ждёт по кадрам.

const STAGE := "sea"


func run(ctx: LocationBuildContext) -> Error:
	ctx.report(STAGE, 0.0)
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(ctx.dir.path_join("meta.json")))
	var info := {}
	if meta is Dictionary:
		for l: Dictionary in (meta as Dictionary).get("layers", []):
			if String(l.get("id", "")) == "far":
				info = l
	if info.is_empty():
		ctx.log_line("sea: нет слоя far в meta.json")
		return ERR_UNAVAILABLE
	var spath := ctx.dir.path_join("far_surface.webp")
	if not FileAccess.file_exists(spath):
		ctx.log_line("sea: нет far_surface.webp — море не посчитано")
		return ERR_UNAVAILABLE
	var w := int(info.width)
	var h := int(info.height)
	var cls := SeaMask.read_l8(spath, w, h)
	var hl := HeightLayer.load_from_file(ctx.dir.path_join(String(info.get("file", "far.webp"))), info)
	if cls.is_empty() or hl == null:
		ctx.log_line("sea: не прочитаны far / far_surface")
		return ERR_UNAVAILABLE
	var t0 := Time.get_ticks_usec()
	var params := SeaMask.params_from_config()
	var cell_m := float(info.spacing_m)
	var heights := hl.heights
	var res := [{}]
	var tid := WorkerThreadPool.add_task(func() -> void:
		res[0] = SeaMask.compute_info(heights, cls, w, h, cell_m, params))
	var tree := Engine.get_main_loop() as SceneTree
	while tree != null and not WorkerThreadPool.is_task_completed(tid):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	if ctx.cancelled:
		return ERR_SKIP
	var info_res: Dictionary = res[0]
	var mask: PackedByteArray = info_res.mask
	if not SeaMask.write_l8(ctx.dir.path_join(SeaMask.FILE), w, h, mask):
		ctx.log_line("sea: не записать %s" % SeaMask.FILE)
		return ERR_FILE_CANT_WRITE
	var flat := int(info_res.flattened)
	if flat > 0:
		var err := _write_aligned(ctx, info, info_res.heights)
		if err != OK:
			ctx.log_line("sea: не записать выровненный far (%d)" % err)
			return err
	var f := FileAccess.open(ctx.dir.path_join("sea.json"), FileAccess.WRITE)
	if f == null:
		ctx.log_line("sea: не записать sea.json")
		return ERR_FILE_CANT_WRITE
	f.store_string(JSON.stringify({"version": 2, "sea_cells": info_res.sea_cells, "components": info_res.components,
		"levels_m": info_res.levels, "flattened_cells": flat, "seconds": snappedf((Time.get_ticks_usec() - t0) / 1e6, 0.01)}))
	f.close()
	ctx.report(STAGE, 1.0)
	return OK


## far.webp с выровненным морем + min/max в meta.json. Смещение кода height_min_m остаётся прежним (суша побайтно та же),
## пока новый минимум не ниже него; иначе смещение = новый минимум.
func _write_aligned(ctx: LocationBuildContext, info: Dictionary, aligned: PackedFloat32Array) -> Error:
	var mm := DemStage._min_max(aligned)
	var hmin := float(info.height_min_m)
	if mm.x < hmin:
		hmin = mm.x
	var w := int(info.width)
	var h := int(info.height)
	var img := HeightLayer.encode_rgb24(aligned, w, h, hmin, float(info.height_step_m))
	var err := img.save_webp(ctx.dir.path_join(String(info.get("file", "far.webp"))), false)
	if err != OK:
		return err
	var path := ctx.dir.path_join("meta.json")
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (meta is Dictionary):
		return ERR_FILE_CORRUPT
	for l: Dictionary in (meta as Dictionary).get("layers", []):
		if String(l.get("id", "")) == "far":
			l["min_height_m"] = mm.x
			l["max_height_m"] = mm.y
			l["height_min_m"] = hmin
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ERR_FILE_CANT_WRITE
	f.store_string(JSON.stringify(meta, "  ") + "\n")
	f.close()
	return OK
