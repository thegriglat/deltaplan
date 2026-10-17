class_name SeaStage
extends RefCounted
## Стадия сборки места «море» (контракт S2, docs/contracts/sea-ships.md): после smooth, до osm_tiles.
## Читает far.webp, meta.json, far_surface.webp из ctx.dir; пишет far_sea.webp (WebP lossless, сетка far,
## значение — SeaMask.compute) и sea.json {"version": 4, "sea_cells", "components", "levels_m", "flattened_cells", "reclassed_cells", "reclassed_detail_cells", "water10_cells", "seconds"}.
## S2 v2: клетки моря в far.webp выравниваются до уровня воды их компоненты (мода высот, SeaMask), остальное не меняется;
## meta.json — min/max высот слоя. S2 v3: класс 0 в клетках моря := 6 в far_surface.webp (reclassed_cells).
## S2 v4: то же в детальном слое — detail_surface.webp (класс 0 := 6) и канал A detail_detail10.webp (A := 255), по surface.json.
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
	# S2 v3: открытый океан без данных WorldCover (класс 0) в клетках моря := 6 (вода). Признак моря посчитан по исходным данным выше.
	var reclassed := 0
	var cls2 := cls.duplicate()
	for i in w * h:
		if mask[i] != 0 and cls2[i] == 0:
			cls2[i] = 6
			reclassed += 1
	if reclassed > 0:
		var tmp := spath + ".tmp"
		if not SeaMask.write_l8(tmp, w, h, cls2) or DirAccess.rename_absolute(tmp, spath) != OK:
			ctx.log_line("sea: не записать far_surface.webp")
			return ERR_FILE_CANT_WRITE
	var det := await _reclass_detail(ctx, w, h, info, mask)
	if det.err != OK:
		return det.err
	var f := FileAccess.open(ctx.dir.path_join("sea.json"), FileAccess.WRITE)
	if f == null:
		ctx.log_line("sea: не записать sea.json")
		return ERR_FILE_CANT_WRITE
	f.store_string(JSON.stringify({"version": 4, "sea_cells": info_res.sea_cells, "components": info_res.components,
		"levels_m": info_res.levels, "flattened_cells": flat, "reclassed_cells": reclassed,
		"reclassed_detail_cells": det.cells, "water10_cells": det.water10, "seconds": snappedf((Time.get_ticks_usec() - t0) / 1e6, 0.01)}))
	f.close()
	ctx.report(STAGE, 1.0)
	return OK


## S2 v4: детальный слой (surface.json: слой detail, его detail10). Нет surface.json / слоя / файлов — ничего не меняется, {"err": OK}.
## Счёт — в рабочем потоке; запись во временный файл + переименование, форматом SurfaceStage (RGB8 / RGBA8, WebP lossless).
func _reclass_detail(ctx: LocationBuildContext, fw: int, fh: int, finfo: Dictionary, mask: PackedByteArray) -> Dictionary:
	var res := {"err": OK, "cells": 0, "water10": 0}
	if not FileAccess.file_exists(ctx.dir.path_join("surface.json")):
		return res
	var sj: Variant = JSON.parse_string(FileAccess.get_file_as_string(ctx.dir.path_join("surface.json")))
	if not (sj is Dictionary):
		return res
	var le := {}
	for l: Dictionary in (sj as Dictionary).get("layers", []):
		if String(l.get("id", "")) == "detail":
			le = l
	if le.is_empty():
		return res
	var dgeo := {"w": int(le.width), "h": int(le.height), "ox": float(le.origin_x_m), "oz": float(le.origin_z_m), "cell": float(le.spacing_m)}
	var fgeo := {"w": fw, "h": fh, "ox": float(finfo.origin_x_m), "oz": float(finfo.origin_z_m), "cell": float(finfo.spacing_m)}
	var spath := ctx.dir.path_join(String(le.get("file", "detail_surface.webp")))
	var cls := SeaMask.read_l8(spath, int(dgeo.w), int(dgeo.h))
	if cls.is_empty():
		return res
	var rgba := PackedByteArray()
	var g10 := {}
	var p10 := ""
	var d10: Dictionary = le.get("detail10", {})
	if not d10.is_empty():
		g10 = {"w": int(d10.width), "h": int(d10.height), "ox": float(d10.origin_x_m), "oz": float(d10.origin_z_m), "cell": float(d10.spacing_m)}
		p10 = ctx.dir.path_join(String(d10.get("file", "detail_detail10.webp")))
		var img := Image.load_from_file(p10)
		if img != null and img.get_width() == int(g10.w) and img.get_height() == int(g10.h):
			img.convert(Image.FORMAT_RGBA8)
			rgba = img.get_data()
	var out := [{}, {}]
	var tid := WorkerThreadPool.add_task(func() -> void:
		out[0] = SeaMask.reclass_detail(mask, fgeo, cls, dgeo)
		if not rgba.is_empty():
			out[1] = SeaMask.water10_detail(mask, fgeo, cls, dgeo, rgba, g10))
	var tree := Engine.get_main_loop() as SceneTree
	while tree != null and not WorkerThreadPool.is_task_completed(tid):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	if ctx.cancelled:
		res.err = ERR_SKIP
		return res
	var r0: Dictionary = out[0]
	if int(r0.cells) > 0:
		var tmp := spath + ".tmp"
		if not SeaMask.write_l8(tmp, int(dgeo.w), int(dgeo.h), r0.classes) or DirAccess.rename_absolute(tmp, spath) != OK:
			ctx.log_line("sea: не записать %s" % spath.get_file())
			res.err = ERR_FILE_CANT_WRITE
			return res
		res.cells = int(r0.cells)
	var r1: Dictionary = out[1]
	if not r1.is_empty() and int(r1.cells) > 0:
		var img2 := Image.create_from_data(int(g10.w), int(g10.h), false, Image.FORMAT_RGBA8, r1.data)
		var tmp2 := p10 + ".tmp"
		if img2 == null or img2.save_webp(tmp2, false) != OK or DirAccess.rename_absolute(tmp2, p10) != OK:
			ctx.log_line("sea: не записать %s" % p10.get_file())
			res.err = ERR_FILE_CANT_WRITE
			return res
		res.water10 = int(r1.cells)
	return res


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
