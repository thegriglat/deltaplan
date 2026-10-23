extends Node
## CL-1: подбор ракурсов стенда cliff-look (tools/shots/cliff_look_views.json). Не игровой код: грузит место
## как игра (Terrain.load_point), ищет крутые (> --min-deg) участки и печатает кандидатов.
##   XDG_DATA_HOME=build/cliff_look_xdg godot --headless --path . res://tools/research/cliff_look/find_views.tscn -- \
##     --latlon=LAT,LON [--cam=LAT,LON,AGL --az=ЦЕНТР,ПОЛУШИРИНА --dist=МИН,МАКС]   сектор от камеры
##     [--radius=М]   без --cam: стены вокруг точки места и камеры к ним (ниже гребня, 120 и 500 м)
## Строки: «WALL …» (цель lat,lon, уклон, экспозиция, дальность, азимут ракурса az_deg — со стороны камеры),
## «STATION …» нет (станции канатки — tools/shots/cliff_look_shot.gd --mode=find).

var _lat := NAN
var _lon := NAN
var _cam := Vector3(NAN, NAN, 5.0)
var _az := Vector2(180.0, 60.0)
var _dist := Vector2(150.0, 2500.0)
var _radius := 2500.0
var _min_deg := 45.0
var t: Terrain


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() < 2:
			continue
		var p := kv[1].split(",")
		match kv[0]:
			"--latlon":
				_lat = float(p[0])
				_lon = float(p[1])
			"--cam":
				_cam = Vector3(float(p[0]), float(p[1]), float(p[2]) if p.size() > 2 else 5.0)
			"--az":
				_az = Vector2(float(p[0]), float(p[1]))
			"--dist":
				_dist = Vector2(float(p[0]), float(p[1]))
			"--radius":
				_radius = float(kv[1])
			"--min-deg":
				_min_deg = float(kv[1])
	t = Terrain.new()
	t.location_id = ""
	add_child(t)
	var res := {"ok": false, "done": false, "err": ""}
	t.loaded.connect(func() -> void: res.ok = true; res.done = true)
	t.load_failed.connect(func(m: String) -> void: res.err = m; res.done = true)
	t.load_point(_lat, _lon)
	var t0 := Time.get_ticks_msec()
	while not res.done and Time.get_ticks_msec() - t0 < 900000:
		await get_tree().process_frame
	if not res.ok:
		print("find_views: FAIL ", res.err)
		get_tree().quit(1)
		return
	var b := t.detail_bounds()
	print("find_views: detail ", b, " spacing ", t.layers[0].spacing)
	if not is_nan(_cam.x):
		_sector()
	else:
		_walls()
	print("find_views: OK")
	get_tree().quit(0)


func _slope_deg(x: float, z: float, e: float) -> float:
	var dx := t.height_at(x + e, z) - t.height_at(x - e, z)
	var dz := t.height_at(x, z + e) - t.height_at(x, z - e)
	return rad_to_deg(atan(Vector2(dx, dz).length() / (2.0 * e)))


## Экспозиция (куда смотрит склон, ° от севера; север — −z).
func _aspect(x: float, z: float, e: float) -> float:
	var n := Vector2(-(t.height_at(x + e, z) - t.height_at(x - e, z)), -(t.height_at(x, z + e) - t.height_at(x, z - e)))
	return fposmod(rad_to_deg(atan2(n.x, -n.y)), 360.0)


func _visible(eye: Vector3, p: Vector3) -> bool:
	var n := int(eye.distance_to(p) / 10.0)
	for i in range(1, n):
		var q := eye.lerp(p, float(i) / n)
		if t.height_at(q.x, q.z) > q.y + 0.5:
			return false
	return true


func _ll(x: float, z: float) -> String:
	var ll := t.local_to_latlon(x, z)
	return "%.5f,%.5f" % [ll.x, ll.y]


## Сектор от камеры: видимые крутые клетки, лучшие по дальностям.
func _sector() -> void:
	var c := t.latlon_to_local(_cam.x, _cam.y)
	var eye := Vector3(c.x, t.height_at(c.x, c.y) + _cam.z, c.y)
	print("find_views: камера ", _ll(c.x, c.y), " земля %.0f глаз %.0f" % [eye.y - _cam.z, eye.y])
	var found: Array = []
	var az := _az.x - _az.y
	while az <= _az.x + _az.y:
		var d := _dist.x
		while d <= _dist.y:
			var dir := Vector2(sin(deg_to_rad(az)), -cos(deg_to_rad(az)))
			var p2 := c + dir * d
			var h := t.height_at(p2.x, p2.y)
			var s := _slope_deg(p2.x, p2.y, 12.5)
			var s50 := _slope_deg(p2.x, p2.y, 50.0)
			if s >= _min_deg and _visible(eye, Vector3(p2.x, h + 2.0, p2.y)):
				var asp := _aspect(p2.x, p2.y, 25.0)
				var face := cos(deg_to_rad(asp - fposmod(az + 180.0, 360.0)))
				found.append([s50 * face, az, d, s, s50, asp, h, p2])
			d += 20.0
		az += 2.0
	found.sort_custom(func(a: Array, b2: Array) -> bool: return a[0] > b2[0])
	for f in found.slice(0, 25):
		var p2: Vector2 = f[7]
		print("WALL %s az_cam %.0f dist %.0f slope25 %.0f slope100 %.0f aspect %.0f h %.0f (над глазом %+.0f) -> az_deg %.0f"
				% [_ll(p2.x, p2.y), f[1], f[2], f[3], f[4], f[5], f[6], f[6] - eye.y, fposmod(f[1] + 180.0, 360.0)])


## Стены вокруг точки: крутой участок 100 м, камеры со стороны экспозиции ниже гребня.
func _walls() -> void:
	var c := t.latlon_to_local(_lat, _lon)
	var cand: Array = []
	var step := 50.0
	var n := int(_radius / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var p := c + Vector2(i, j) * step
			if p.distance_to(c) > _radius:
				continue
			var s := _slope_deg(p.x, p.y, 50.0)
			if s >= _min_deg:
				cand.append([s, p])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var used: Array[Vector2] = []
	var printed := 0
	for cd in cand:
		var p: Vector2 = cd[1]
		var near := false
		for u in used:
			if u.distance_to(p) < 400.0:
				near = true
		if near:
			continue
		var asp := _aspect(p.x, p.y, 25.0)
		var dir := Vector2(sin(deg_to_rad(asp)), -cos(deg_to_rad(asp)))
		var h := t.height_at(p.x, p.y)
		var crest := h
		for k in range(1, 16):
			var q := p - dir * (k * 20.0)
			crest = maxf(crest, t.height_at(q.x, q.y))
		var line := "WALL %s slope100 %.0f slope25 %.0f aspect %.0f h %.0f crest %.0f" % [_ll(p.x, p.y), cd[0],
				_slope_deg(p.x, p.y, 12.5), asp, h, crest]
		var ok := 0
		for d: float in [120.0, 160.0, 400.0, 600.0]:
			var cp := p + dir * d
			var g := t.height_at(cp.x, cp.y)
			for agl: float in [5.0, 30.0, 80.0, 150.0]:
				var eye := Vector3(cp.x, g + agl, cp.y)
				if eye.y <= crest and _visible(eye, Vector3(p.x, h + 20.0, p.y)):
					line += " | d%.0f agl%.0f eye %.0f" % [d, agl, eye.y]
					ok += 1
					break
		if ok >= 2:
			print(line, " -> az_deg %.0f" % asp)
			used.append(p)
			printed += 1
		if printed >= 12:
			break
