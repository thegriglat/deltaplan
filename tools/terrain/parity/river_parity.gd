extends SceneTree
## Паритет RiverStage с rivers.py: на высотах встроенных мест считаем маски и сравниваем (IoU по >127)
## с data/terrain/<id>/*_water.png. Запуск: godot --headless --path . -s res://tools/terrain/parity/river_parity.gd

const IDS := ["askarovo", "altai"]


func _init() -> void:
	var iou_far := 1.0
	var iou_det := 1.0
	var sec_max := 0.0
	for id in IDS:
		var base := "res://data/terrain/%s" % id
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base + "/meta.json"))
		var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/locations/%s.json" % id)).rivers
		var heights := {}
		var layers := {}
		for info in meta.layers:
			var hl := HeightLayer.load_from_file("%s/%s" % [base, info.file], info)
			heights[info.id] = hl.heights
			layers[info.id] = info
		var t0 := Time.get_ticks_msec()
		var imgs := RiverStage.compute(heights, layers, cfg)
		var sec := (Time.get_ticks_msec() - t0) / 1000.0
		sec_max = maxf(sec_max, sec)
		print("%s: расчёт %.1f с" % [id, sec])
		for lid in imgs:
			var ref := Image.load_from_file(ProjectSettings.globalize_path("%s/%s_water.png" % [base, lid]))
			var a: PackedByteArray = imgs[lid].get_data()
			var b: PackedByteArray = ref.get_data()
			var inter := 0
			var uni := 0
			if a.size() != b.size():
				print("  %s: размеры не совпали" % lid)
				continue
			for n in a.size():
				var x := a[n] > 127
				var y := b[n] > 127
				if x and y:
					inter += 1
				if x or y:
					uni += 1
			var iou := 1.0 if uni == 0 else float(inter) / uni
			print("  %s: IoU=%.4f (пересечение %d, объединение %d)" % [lid, iou, inter, uni])
			if lid == "far":
				iou_far = minf(iou_far, iou)
			else:
				iou_det = minf(iou_det, iou)
	print("iou_far_min=%.4f" % iou_far)
	print("iou_detail_min=%.4f" % iou_det)
	print("stage_seconds_max=%.1f" % sec_max)
	quit()
