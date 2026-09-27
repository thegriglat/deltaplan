class_name SurfaceClassifier
extends RefCounted
## Запасная процедурная карта поверхности: когда нет карты земного покрова (рантайм-локация
## без сети). Классы — по высоте, уклону, экспозиции и шуму; результат — такой же SurfaceLayer,
## как из WorldCover, поэтому раскраска, деревья и источники термиков по-прежнему из одной карты.
## Параметры — configs/world.json → surface.fallback.


## Классифицировать слой высот. Шаг карты = шаг слоя × cell_factor.
## Маска рек слоя (water_texture), если есть, даёт класс «вода».
static func classify(layer: HeightLayer, fb: Dictionary) -> SurfaceLayer:
	var factor := maxi(1, int(fb.get("cell_factor", 4)))
	var step := layer.spacing * factor
	var w := int(floor(layer.size_x() / step)) + 1
	var h := int(floor(layer.size_z() / step)) + 1
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_octaves = 4
	noise.frequency = 1.0 / float(fb.get("patch_scale_m", 700.0))
	noise.seed = 1
	var water_img := _water_image(layer)
	var forest_min := float(fb.forest_min_m)
	var treeline := float(fb.treeline_m)
	var cover := float(fb.forest_cover)
	var north_bias := float(fb.forest_north_bias)
	var forest_max_slope := float(fb.forest_max_slope_deg)
	var snowline := float(fb.snowline_m)
	var snow_max_slope := float(fb.snow_max_slope_deg)
	var field_max_slope := float(fb.field_max_slope_deg)
	var field_max_h := float(fb.field_max_height_m)
	var data := PackedByteArray()
	data.resize(w * h)
	var e := layer.spacing
	for j in h:
		var z := layer.origin_z + j * step
		for i in w:
			var x := layer.origin_x + i * step
			var hc := layer.sample(x, z)
			var gx := (layer.sample(x + e, z) - layer.sample(x - e, z)) / (2.0 * e)
			var gz := (layer.sample(x, z + e) - layer.sample(x, z - e)) / (2.0 * e)
			var grad := sqrt(gx * gx + gz * gz)
			var slope := rad_to_deg(atan(grad))
			# «северность»: нормаль (−gx, 1, −gz) смотрит на −Z, т. е. gz > 0
			var north := (
				(gz / grad) * clampf((slope - 3.0) / 12.0, 0.0, 1.0) if grad > 1e-4 else 0.0
			)
			var p := noise.get_noise_2d(x, z) * 0.5 + 0.5
			var c := SurfaceLayer.GRASS
			if water_img != null and _water(water_img, layer, x, z) > 0.5:
				c = SurfaceLayer.WATER
			elif hc > snowline + 150.0 * (p - 0.5) and slope < snow_max_slope:
				c = SurfaceLayer.SNOW
			elif slope < field_max_slope and hc < field_max_h and p > 0.55:
				c = SurfaceLayer.CROP
			elif (
				hc > forest_min
				and hc < treeline + 200.0 * (p - 0.5)
				and slope < forest_max_slope
				and p > 1.0 - cover - north_bias * north
			):
				c = SurfaceLayer.FOREST
			elif hc > treeline - 150.0 and hc < treeline + 250.0:
				c = SurfaceLayer.SHRUB
			data[j * w + i] = c
	var s := SurfaceLayer.from_classes(layer.id, w, h, step, layer.origin_x, layer.origin_z, data)
	s.source = "procedural"
	return s


static func _water_image(layer: HeightLayer) -> Image:
	if layer.water_texture == null:
		return null
	var img := layer.water_texture.get_image()
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	return img


static func _water(img: Image, layer: HeightLayer, x: float, z: float) -> float:
	var u := clampi(roundi((x - layer.origin_x) / layer.spacing), 0, img.get_width() - 1)
	var v := clampi(roundi((z - layer.origin_z) / layer.spacing), 0, img.get_height() - 1)
	return img.get_pixel(u, v).r
