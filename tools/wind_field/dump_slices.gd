extends Node
## Инструмент WF-09 (AM-10, docs/plan/wind_field.md → «Визуально (WF-09)»): PNG-срезы среднего
## поля воздуха (масштаб 1, WindField) — два горизонтальных (20 и 200 м AGL: цвет — разгон
## |G_h|/U₀ − 1, стрелки — направление) и один вертикальный вдоль ветра через точку (цвет —
## w/U₀, тонкие изолинии θ′, силуэт рельефа снизу); термики поверх среза — треугольники по силе
## (текущая модель ThermalField через Atmosphere.thermals_near — поле термиков из среднего поля 1
## ещё не сделано, AM-07 идёт параллельно; это подписано на срезе).
##
## Запуск (headless):
##   godot --headless --path . res://tools/wind_field/dump_slices.tscn -- \
##     --field=<путь.json> [--out=tools/research/air3d/out/slices] [--name=каянча]
##     [--point=x,y,z] [--location=ongudai] [--wind=3] [--from=180] [--hour=13]
##     [--extra_out=build/screenshots] [--extra_prefix=03]
## point по умолчанию — стартовая точка из meta.probes поля (probe "*_agl10"), иначе центр поля.

const IMG_W := 480
const IMG_H := 480
const VERT_W := 640
const VERT_H := 320

var _args: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var field_path := String(_args.get("field", ""))
	if field_path == "":
		push_error("dump_slices: нужен --field=<путь к .json/.bin>")
		get_tree().quit(1)
		return
	var field := WindField.load_file(field_path)
	if field == null:
		push_error("dump_slices: не читается поле %s" % field_path)
		get_tree().quit(1)
		return
	var out_dir := String(_args.get("out", "tools/research/air3d/out/slices"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var name := String(_args.get("name", field.meta.get("path", "field").get_file()))

	var cond: Dictionary = field.meta.get("cond", {})
	var u_ref := float(_args.get("wind", cond.get("wind", 3.0)))
	var wdir := float(_args.get("from", cond.get("wdir", 180.0)))
	var hour := float(_args.get("hour", cond.get("hour", 13.0)))
	var d := deg_to_rad(wdir)
	# как WindModel.set_wind: X — восток, −Z — север; ветер «от» wdir дует в направлении dir.
	var wind_dir := Vector3(-sin(d), 0.0, cos(d))

	var point := _pick_point(field)
	if _args.has("point"):
		var p := String(_args.point).split(",")
		if p.size() == 3:
			point = Vector3(float(p[0]), float(p[1]), float(p[2]))

	var thermals: Array = []
	var thermals_note := (
		"термики: текущая модель (ThermalField), не из среднего поля — AM-07 идёт параллельно"
	)
	var loc := String(_args.get("location", ""))
	if loc != "":
		thermals = _collect_thermals(loc, point, u_ref, wdir, hour)

	var paths: Array[String] = []
	paths.append(_horizontal_slice(field, 20.0, u_ref, out_dir, "%s_gorizont_20m" % name))
	paths.append(_horizontal_slice(field, 200.0, u_ref, out_dir, "%s_gorizont_200m" % name))
	paths.append(
		_vertical_slice(
			field, point, wind_dir, u_ref, thermals, thermals_note, out_dir,
			"%s_vertikal_vdol_vetra" % name,
			{"loc": loc if loc != "" else name, "hour": hour, "wdir": wdir}
		)
	)

	var extra_out := String(_args.get("extra_out", ""))
	if extra_out != "":
		DirAccess.make_dir_recursive_absolute(extra_out)
		var prefix := String(_args.get("extra_prefix", "03"))
		var suffixes := ["_gorizont_20m", "_gorizont_200m", "_vertikal_vdol_vetra"]
		var n := int(prefix)
		for i in paths.size():
			var img := Image.load_from_file(paths[i])
			if img == null:
				continue
			var dst := "%s/%02d_срез_поля%s.png" % [extra_out, n, suffixes[i]]
			img.save_png(dst)
			n += 1

	print("dump_slices: готово — %s" % ", ".join(paths))
	get_tree().quit(0)


func _pick_point(field: WindField) -> Vector3:
	var probes: Array = field.meta.get("probes", [])
	for pr: Variant in probes:
		var d: Dictionary = pr
		if String(d.get("name", "")).ends_with("agl10"):
			var g: Array = d.game
			return Vector3(float(g[0]), float(g[1]), float(g[2]))
	var c := field.center_xz()
	return Vector3(c.x, field.ground_height(c.x, c.y) + 10.0, c.y)


func _collect_thermals(
	loc: String, point: Vector3, wind_ms: float, wdir: float, hour: float
) -> Array:
	var terrain := Terrain.new()
	terrain.location_id = ""
	if not terrain.load_location(loc):
		push_warning("dump_slices: не загрузилась локация %s — термики не показаны" % loc)
		terrain.free()
		return []
	var weather: Dictionary = Config.get_config("weather/medium").duplicate(true)
	weather.wind_speed_kmh = wind_ms * 3.6
	weather.wind_from_deg = wdir
	var atmo_cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(atmo_cfg, weather)
	atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	atmo.time_s = hour * 3600.0
	atmo.set_focus(point)
	atmo.step(0.0)
	var list := atmo.thermals_near(point, 4000.0)
	terrain.free()
	return list


static func _diverging(t: float) -> Color:
	t = clampf(t, -1.0, 1.0)
	if t < 0.0:
		return Color(0.05, 0.35, 0.9).lerp(Color(1.0, 1.0, 1.0), 1.0 + t)
	return Color(1.0, 1.0, 1.0).lerp(Color(0.95, 0.15, 0.05), t)


## Горизонтальный срез на высоте agl над рельефом сетки: цвет — разгон |Gh|/U₀ − 1 (± 0,6), тонкая
## сетка стрелок направления поверх заливки.
func _horizontal_slice(
	field: WindField, agl: float, u_ref: float, out_dir: String, name: String
) -> String:
	var img := Image.create(IMG_W, IMG_H, false, Image.FORMAT_RGB8)
	var sx := field.size_x()
	var sz := field.ny * field.dx
	for j in IMG_H:
		var z := field.y0 + (float(j) / (IMG_H - 1)) * sz
		for i in IMG_W:
			var x := field.x0 + (float(i) / (IMG_W - 1)) * sx
			var gh := field.ground_height(x, -z)
			var v := field.sample(Vector3(x, gh + agl, -z))
			var speed := Vector2(v.x, v.z).length()
			var t := (speed / maxf(u_ref, 0.1) - 1.0) / 0.6
			img.set_pixel(i, IMG_H - 1 - j, _diverging(t))
	# стрелки направления — редкая сетка поверх заливки
	var step := 24
	for j in range(step / 2, IMG_H, step):
		for i in range(step / 2, IMG_W, step):
			var z := field.y0 + (float(j) / (IMG_H - 1)) * sz
			var x := field.x0 + (float(i) / (IMG_W - 1)) * sx
			var gh := field.ground_height(x, -z)
			var v := field.sample(Vector3(x, gh + agl, -z))
			var h := Vector2(v.x, v.z)
			if h.length() < 1.0e-3:
				continue
			var dirn := h.normalized()
			var len_px := clampf(h.length() / maxf(u_ref, 0.1), 0.3, 1.6) * step * 0.4
			var p0 := Vector2(i, IMG_H - 1 - j)
			var p1 := p0 + Vector2(dirn.x, -dirn.y) * len_px
			_draw_line(img, p0, p1, Color.BLACK)
	var path := "%s/%s.png" % [out_dir, name]
	img.save_png(path)
	return path


## Вертикальный срез вдоль wind_dir через point: ось s — расстояние по ветру (±half_len), ось h —
## высота над стартовой точкой; цвет — w/U₀, изолинии θ′ каждые theta_step К, серый — под землёй,
## треугольники — термики (текущая модель), подпись — режим термиков.
## title — {loc, hour, wdir} для заголовка сайдкара (annotate_slice.py); {} — без подписи места.
func _vertical_slice(
	field: WindField,
	point: Vector3,
	wind_dir: Vector3,
	u_ref: float,
	thermals: Array,
	note: String,
	out_dir: String,
	name: String,
	title: Dictionary = {}
) -> String:
	var half_len := field.size_x() * 0.5
	var h_top := 900.0
	var theta_step := 0.15
	var img := Image.create(VERT_W, VERT_H, false, Image.FORMAT_RGB8)
	# первый проход — θ′ и цвет по w в массив (i, j), второй — контуры по соседям по обеим осям
	# (иначе полосы получаются по столбцу, а не по реальному градиенту θ′).
	var levels := PackedInt32Array()
	levels.resize(VERT_W * VERT_H)
	var cols: Array[Color] = []
	cols.resize(VERT_W * VERT_H)
	for i in VERT_W:
		var s := -half_len + (float(i) / (VERT_W - 1)) * 2.0 * half_len
		var x := point.x + wind_dir.x * s
		var z := point.z + wind_dir.z * s
		var gh := field.ground_height(x, -z)
		for j in VERT_H:
			var y := gh + (float(j) / (VERT_H - 1)) * h_top
			var v := field.sample(Vector3(x, y, -z))
			var th := field.sample_theta(Vector3(x, y, -z))
			var t := clampf(v.y / maxf(u_ref * 0.4, 0.2), -1.0, 1.0)
			var idx := j * VERT_W + i
			cols[idx] = _diverging(t)
			levels[idx] = int(floor(th / theta_step))
	for i in VERT_W:
		for j in VERT_H:
			var idx := j * VERT_W + i
			var col: Color = cols[idx]
			var lvl := levels[idx]
			var edge := false
			if i > 0 and levels[idx - 1] != lvl:
				edge = true
			if j > 0 and levels[idx - VERT_W] != lvl:
				edge = true
			if edge:
				col = col.darkened(0.55)
			img.set_pixel(i, VERT_H - 1 - j, col)
	# силуэт рельефа снизу — там, где выборка ниже уровня земли под пилотом
	for i in VERT_W:
		var s := -half_len + (float(i) / (VERT_W - 1)) * 2.0 * half_len
		var x := point.x + wind_dir.x * s
		var z := point.z + wind_dir.z * s
		var gh := field.ground_height(x, -z)
		var start_gh := field.ground_height(point.x, -point.z)
		var ground_px := int(clampf((gh - start_gh) / h_top, 0.0, 1.0) * (VERT_H - 1))
		for j in range(0, ground_px + 1):
			img.set_pixel(i, VERT_H - 1 - j, Color(0.25, 0.22, 0.18))
	# термики (текущая модель): треугольник у земли в позиции проекции на ось s, размер — сила
	var start_gh2 := field.ground_height(point.x, -point.z)
	for th: Variant in thermals:
		var d: Dictionary = th
		var c: Vector3 = d.get("ground_axis", d.get("source", Vector3.ZERO))
		var rel := Vector2(c.x - point.x, c.z - point.z)
		var s := rel.dot(Vector2(wind_dir.x, wind_dir.z))
		if absf(s) > half_len:
			continue
		var i := int((s + half_len) / (2.0 * half_len) * (VERT_W - 1))
		var strength := float(d.get("strength_ms", 0.0)) * float(d.get("envelope", 1.0))
		var half_w := clampi(4 + int(strength * 3.0), 4, 24)
		var base_gh := field.ground_height(point.x + wind_dir.x * s, -(point.z + wind_dir.z * s))
		var base_px := int(clampf((base_gh - start_gh2) / h_top, 0.0, 1.0) * (VERT_H - 1))
		for k in range(half_w):
			var y0 := VERT_H - 1 - base_px - k
			if y0 < 0 or y0 >= VERT_H:
				continue
			for dx in range(-(half_w - k), (half_w - k) + 1):
				var xi := i + dx
				if xi >= 0 and xi < VERT_W:
					img.set_pixel(xi, y0, Color(1.0, 0.85, 0.1))
	var path := "%s/%s.png" % [out_dir, name]
	img.save_png(path)
	# сайдкар для tools/research/air3d/annotate_slice.py (оси/шкала/заголовок — средствами PIL,
	# GDScript headless не рисует текст без окна).
	var meta := {
		"half_len_m": half_len,
		"h_top_m": h_top,
		"w_scale_ms": maxf(u_ref * 0.4, 0.2),
		"theta_step_k": theta_step,
		"location": String(title.get("loc", "")),
		"hour": float(title.get("hour", -1.0)),
		"wind_ms": u_ref,
		"wind_from_deg": float(title.get("wdir", 0.0)),
	}
	var f := FileAccess.open("%s/%s.json" % [out_dir, name], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta))
	print("dump_slices: %s — %s" % [name, note])
	return path


func _draw_line(img: Image, p0: Vector2, p1: Vector2, col: Color) -> void:
	var n := int(p0.distance_to(p1)) + 1
	for k in range(n + 1):
		var p := p0.lerp(p1, float(k) / maxf(n, 1))
		var xi := int(p.x)
		var yi := int(p.y)
		if xi >= 0 and xi < img.get_width() and yi >= 0 and yi < img.get_height():
			img.set_pixel(xi, yi, col)
