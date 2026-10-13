extends Node
## Зонд силуэта гор MLK-К3 v1 (модуль mountain-look). Не игровой код: грузит место как игра
## (Terrain.load_point / load_builtin), строит сырой эталон (Copernicus без сглаживания) и сравнивает
## его с данными игры и с тем, как рисует меш (LOD-выборка вершин + dh К2: v2 — ReliefLook.dh, CPU-зеркало
## vertex() terrain.gdshader; --dh=v1 — прежняя формула, копия в зонде). Печатает «MLOOK <tag> <раздел> …»
## и пишет JSON. Версия 2 (MLK-3): + раздел "mesh" — швы LOD/слоёв, dh в вогнутых местах, перепад высот;
## --quick=1 — только меш (без сырого эталона, горизонта, вершин и гребней; быстро).
##
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/bench/mountain_look_probe.tscn -- \
##     --latlon=LAT,LON [--location=<id>] --tag=<имя> --out=<путь.json> [--agl=300] [--az_step=0.1] \
##     [--cache=<каталог>] [--range_km=45] [--raw=copernicus|game] [--targets="lat,lon,имя;…"]
##     [--dh=v2|v1] [--quick=1] [--look="ключ=число;ключ=a,b"] (подмена terrain_look — подбор relief_*)
##   --raw=game — без сети: «сырым» служат слои игры (форма JSON для теста; curv_ratio = 1).
## Приближения: dh — без шума границ классов (surface_edge_noise), градиент промоин — разностью
## на шаге мипа, а не trilinear по мипам; меш — треугольники (a,b,c / b,d,c) как в _grid_mesh;
## рефракция k = 0,13 (угол горизонта уменьшается на r/2R·(1−k)).

const PROBE_VERSION := 2
const EARTH_R := 6371008.8
const REFRACTION_K := 0.13
const CREST_LAP := -0.15
const ZONES := ["all", "above_forest", "forest"]

var _opt := {
	"lat": NAN, "lon": NAN, "location": "", "tag": "", "out": "", "agl": 300.0, "az_step": 0.1,
	"cache": "", "range_km": 45.0, "raw": "copernicus", "targets": "", "dh": "v2", "quick": 0.0, "look": "",
}
## Вогнутое место для «надувания долин»: лапласиан игры на масштабе VALLEY_SCALE_M больше этого, м/м.
const VALLEY_LAP := 0.05
const VALLEY_SCALE_M := 100.0
const VALLEY_MIN_KM := 3.0
var _look: Dictionary = {}
var _rm: Array = []  # меш отрисовки по слоям (см. _rm_build)
var _D: HeightLayer
var _F: HeightLayer
var _R30: HeightLayer
var _R100: HeightLayer
var _R25: HeightLayer
var _c := Vector2.ZERO
var _h_eye := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0].begins_with("--") and _opt.has(kv[0].substr(2)):
			var k := kv[0].substr(2)
			if k == "lat" or k == "lon":
				continue
			_opt[k] = kv[1] if _opt[k] is String else float(kv[1])
		elif kv[0] == "--latlon":
			var p := kv[1].split(",")
			_opt.lat = float(p[0])
			_opt.lon = float(p[1])
	if _opt.tag == "":
		_opt.tag = _opt.location if _opt.location != "" else "%.3f_%.3f" % [_opt.lat, _opt.lon]
	if _opt.cache != "":
		var w: Dictionary = Config.get_config("world")
		w.runtime_terrain.cache_dir = String(_opt.cache).path_join("terrain_cache")
		w.location_builder.cache_dir = String(_opt.cache).path_join("locations")
	var t := Terrain.new()
	t.location_id = ""
	add_child(t)
	var res := {"ok": false, "done": false, "err": ""}
	t.loaded.connect(func() -> void: res.ok = true; res.done = true)
	t.load_failed.connect(func(m: String) -> void: res.err = m; res.done = true)
	if _opt.location != "":
		t.load_builtin(_opt.location)
	else:
		t.load_point(_opt.lat, _opt.lon)
	var t0 := Time.get_ticks_msec()
	while not res.done and Time.get_ticks_msec() - t0 < 1800000:
		await get_tree().process_frame
	if not res.ok:
		print("mountain_look_probe: FAIL %s %s" % [_opt.tag, res.err])
		get_tree().quit(1)
		return
	var out: Dictionary = await measure(t, _opt)
	if out.is_empty():
		print("mountain_look_probe: FAIL %s measure" % _opt.tag)
		get_tree().quit(1)
		return
	if _opt.out != "":
		DirAccess.make_dir_recursive_absolute(String(_opt.out).get_base_dir())
		var f := FileAccess.open(_opt.out, FileAccess.WRITE)
		f.store_string(JSON.stringify(out, "  ") + "\n")
		f.close()
	print("mountain_look_probe: OK %s" % _opt.tag)
	t.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)


static func _ss(e0: float, e1: float, x: float) -> float:
	var u := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


static func _pct(a: Array, p: float) -> float:
	if a.is_empty():
		return NAN
	a.sort()
	return float(a[mini(int(p * a.size()), a.size() - 1)])


static func _num(v: float) -> Variant:
	return null if is_nan(v) or is_inf(v) else snappedf(v, 0.0001)


# ---------------------------------------------------------------- основной замер


func measure(t: Terrain, opt: Dictionary) -> Dictionary:
	_opt = opt
	var tag := String(opt.tag)
	_D = t.layers[0]
	_F = t.layers[t.layers.size() - 1] if t.layers.size() > 1 else null
	_look = t._look.duplicate(true)
	for kv in String(opt.get("look", "")).split(";", false):
		var p := kv.split("=")
		if p.size() == 2:
			var vals := p[1].split(",")
			_look[p[0]] = float(vals[0]) if vals.size() == 1 else Array(vals).map(func(v: String) -> float: return float(v))
	if String(opt.get("look", "")) != "":
		print("MLOOK %s look %s" % [tag, String(opt.look)])
	var site_ll := Vector2(float(opt.lat), float(opt.lon))
	if is_nan(site_ll.x):
		var sites := t.get_start_sites()
		if sites.is_empty():
			_c = Vector2.ZERO
			site_ll = t.local_to_latlon(0.0, 0.0)
		else:
			var p: Vector3 = sites[0].position
			_c = Vector2(p.x, p.z)
			site_ll = t.local_to_latlon(_c.x, _c.y)
	else:
		_c = t.latlon_to_local(site_ll.x, site_ll.y)
	_h_eye = _game_h(_c.x, _c.y) + float(opt.agl)
	var rcfg: Dictionary = _render_cfg(t)
	_rm = _rm_build(t.layers, t.surfaces, rcfg, Vector3(_c.x, _h_eye, _c.y))
	var mesh := _mesh_stats(rcfg)
	print("MLOOK %s меш dh=%s %s" % [tag, String(opt.get("dh", "v2")), JSON.stringify(mesh)])
	if float(opt.get("quick", 0.0)) > 0.0:
		return {"probe_version": PROBE_VERSION, "tag": tag, "dh": String(opt.get("dh", "v2")), "quick": true,
				"lat": site_ll.x, "lon": site_ll.y, "h_eye_m": _h_eye, "mesh": mesh}
	print("MLOOK %s старт lat=%.4f lon=%.4f h_eye=%.0f центр=%.3f,%.3f" % [tag, site_ll.x, site_ll.y, _h_eye, t.center_lat, t.center_lon])
	# сырой эталон
	if String(opt.raw) == "game":
		_R25 = _D
		_R30 = _D
		_R100 = _F if _F != null else _D
	else:
		var half := _D.size_x() * 0.5
		_R25 = await _raw_layer(t, "r25", half * 2.0 / 1000.0, _D.spacing)
		_R30 = await _raw_layer(t, "r30", 100.0, 30.0)
		_R100 = await _raw_layer(t, "r100", 100.0, 100.0)
		if _R25 == null or _R30 == null or _R100 == null:
			return {}
	var layers_out: Array = []
	var tl := {}
	for li in t.layers.size():
		var L: HeightLayer = t.layers[li]
		tl[L.id] = _treeline(L, t.surfaces[li])
		layers_out.append({"id": L.id, "spacing_m": L.spacing, "size_km": snappedf(L.size_x() / 1000.0, 0.1),
				"treeline_est_m": _num(tl[L.id])})
	var crests: Array = []
	crests.append_array(_crests(t, 0, _R25, tl[_D.id], [[0.0, 3.0], [3.0, 8.0], [8.0, 14.0], [14.0, 30.0]]))
	if _F != null and _F != _D:
		crests.append_array(_crests(t, t.layers.size() - 1, _R100, tl[_F.id], [[14.0, 30.0], [30.0, 40.0], [40.0, 50.0]]))
	for c in crests:
		print("MLOOK %s гребни %s %s %s n=%d curv_ratio=%s drop_p50=%s drop_p90=%s drop_render_p50=%s"
				% [tag, c.layer, str(c.band_km), c.zone, c.n, str(c.curv_ratio), str(c.drop_m_p50), str(c.drop_m_p90), str(c.drop_render_m_p50)])
	var hz: Dictionary = await _horizon()
	var peaks := _peaks(hz, t)
	for p in peaks:
		print("MLOOK %s вершина %s d=%.1f км слой=%s raw=%.0f game=%.0f render=%.0f недобор=%.1f м (%.2f°) сетка=%.1f источник=%.1f LOD=%.1f"
				% [tag, p.name, p.dist_km, p.layer, p.h_raw, p.h_game, p.h_render, p.h_raw - p.h_render, p.deficit_deg,
				p.loss_grid_m, p.loss_source_m, p.loss_lod_m])
	var hj: Dictionary = hz.summary
	print("MLOOK %s горизонт rough_raw=%.4f rough_render=%.4f ratio=%.2f deficit_p50=%.3f max=%.3f far_share=%.2f" % [tag,
			hj.rough_raw_deg, hj.rough_render_deg, hj.rough_ratio, hj.deficit_deg_p50, hj.deficit_deg_max, hj.far_layer_share])
	var out := {
		"probe_version": PROBE_VERSION, "tag": tag, "lat": site_ll.x, "lon": site_ll.y,
		"center_lat": t.center_lat, "center_lon": t.center_lon, "format_version": Locations.FORMAT_VERSION,
		"agl_m": float(opt.agl), "h_eye_m": _h_eye, "raw": String(opt.raw), "range_km": float(opt.range_km),
		"layers": layers_out, "peaks": peaks, "crests": crests, "horizon": hj, "memory": _memory(t),
		"dh": String(opt.get("dh", "v2")), "mesh": mesh, "look_override": String(opt.get("look", "")),
	}
	if String(opt.out) != "":
		_write_profile(String(opt.out).get_basename() + "_profile.csv", hz)
	return out


func _render_cfg(t: Terrain) -> Dictionary:
	var cfg: Dictionary = Locations.config(t.location_id)
	var r: Dictionary = cfg.get("render", {})
	if r.is_empty():
		r = Config.get_config("world").location_builder.template.render
	return r


func _game_h(x: float, z: float) -> float:
	if _D.contains(x, z):
		return _D.sample(x, z)
	return _F.sample(x, z) if _F != null else _D.sample(x, z)


# ---------------------------------------------------------------- сырой слой


func _raw_layer(t: Terrain, id: String, size_km: float, spacing: float) -> HeightLayer:
	var n := int(round(size_km * 1000.0 / spacing)) + 1
	var half := (n - 1) * spacing / 2.0
	var cdir := String(_opt.cache) if _opt.cache != "" else "user://mlk_cache"
	DirAccess.make_dir_recursive_absolute(cdir.path_join("raw"))
	var fn := cdir.path_join("raw").path_join("%.3f_%.3f_%s_%d_%d.f32" % [t.center_lat, t.center_lon, id, int(size_km * 10), int(spacing)])
	if FileAccess.file_exists(fn):
		var data := FileAccess.get_file_as_bytes(fn).to_float32_array()
		if data.size() == n * n:
			return HeightLayer.from_heights(id, n, n, spacing, -half, -half, data)
	var st: Object = (load("res://scripts/terrain/build/dem_stage.gd") as GDScript).new()
	var ctx := LocationBuildContext.new()
	ctx.key = "mlk_raw_" + id
	ctx.center_lat = t.center_lat
	ctx.center_lon = t.center_lon
	ctx.host = self
	ctx.dir = OS.get_user_data_dir().path_join("mlk_raw_" + id)
	ctx.spec = {"dem": {"layers": [{"id": id, "size_km": size_km, "spacing_m": spacing,
			"source": "copernicus", "zoom": 12, "quantize_per_m": 32, "smooth_sigma_cells": 0}]}}
	var err: int = await st.run(ctx)
	if err != OK:
		print("MLOOK %s raw %s: ошибка %d %s" % [_opt.tag, id, err, str(ctx.log_lines)])
		return null
	var h: PackedFloat32Array = ctx.heights[id]
	var f := FileAccess.open(fn, FileAccess.WRITE)
	if f != null:
		f.store_buffer(h.to_byte_array())
		f.close()
	return HeightLayer.from_heights(id, n, n, spacing, -half, -half, h)


# ---------------------------------------------------------------- dh К2 v1 (копия vertex())


static func _fract(v: float) -> float:
	return v - floorf(v)


static func _hash12(p: Vector2) -> float:
	p = Vector2(p.x - 4096.0 * floorf(p.x / 4096.0), p.y - 4096.0 * floorf(p.y / 4096.0))
	var a := _fract(p.x * 0.1031)
	var b := _fract(p.y * 0.1031)
	var c := _fract(p.x * 0.1031)
	var d := a * (b + 33.33) + b * (c + 33.33) + c * (a + 33.33)
	a += d
	b += d
	c += d
	return _fract((a + b) * c)


static func _gully_cell3(ip: Vector2, fp: Vector2, o: Vector2, dir: Vector2) -> Vector3:
	var hs := _hash12(ip + o)
	var pp := fp - o - (Vector2(hs, _fract(hs * 37.17)) - Vector2(0.5, 0.5)) * 0.5
	var ph := pp.dot(dir) * 6.2832
	return Vector3(-sin(ph) * dir.x * 6.2832, -sin(ph) * dir.y * 6.2832, cos(ph))


static func _gully_octave3(p: Vector2, dir: Vector2) -> Vector3:
	var ip := Vector2(floorf(p.x), floorf(p.y))
	var fp := p - ip
	var u := Vector2(fp.x * fp.x * (3.0 - 2.0 * fp.x), fp.y * fp.y * (3.0 - 2.0 * fp.y))
	var a := _gully_cell3(ip, fp, Vector2(0, 0), dir).lerp(_gully_cell3(ip, fp, Vector2(1, 0), dir), u.x)
	var b := _gully_cell3(ip, fp, Vector2(0, 1), dir).lerp(_gully_cell3(ip, fp, Vector2(1, 1), dir), u.x)
	return a.lerp(b, u.y)


static func _erosion_height(xz: Vector2, g: Vector2, vs: float, k: float, look: Dictionary) -> float:
	var strength := float(look.get("erosion_strength", 0.45))
	var scale := float(look.get("erosion_scale_m", 140.0))
	var octaves := float(look.get("erosion_octaves", 3.0))
	var gain := float(look.get("erosion_gain", 0.55))
	var branch := float(look.get("erosion_branch", 1.0))
	var amp0 := strength * g.length() / 6.2832 * k
	var dg := Vector2.ZERO
	var hsum := 0.0
	for i in 3:
		var o := float(i)
		var lambda := scale * pow(2.0, -o)
		var kv := _ss(2.5, 4.0, lambda / vs) * (1.0 if o + 0.5 <= octaves else 0.0)
		if kv > 0.0:
			var gg := g + dg * branch
			var dir := Vector2(-gg.y, gg.x).normalized() if gg.length() > 1e-4 else Vector2(1, 0)
			var a := amp0 * pow(gain, o) * kv
			var r := _gully_octave3(xz / lambda + Vector2(o * 17.3, o * 17.3), dir)
			dg += Vector2(r.x, r.y) * a
			hsum += r.z * a * lambda
	return hsum


## Вес класса в точке: билинейно по one-hot четырёх узлов и порог 0,5 ± surface_edge_sharpness.
static func _class_w(S: SurfaceLayer, x: float, z: float, cls: int, edge: float) -> float:
	var fx := (x - S.origin_x) / S.spacing
	var fz := (z - S.origin_z) / S.spacing
	var i := int(floorf(fx))
	var j := int(floorf(fz))
	var tx := fx - i
	var tz := fz - j
	var a := lerpf(float(S.node(i, j) == cls), float(S.node(i + 1, j) == cls), tx)
	var b := lerpf(float(S.node(i, j + 1) == cls), float(S.node(i + 1, j + 1) == cls), tx)
	return _ss(0.5 - edge, 0.5 + edge, lerpf(a, b, tz))


## dh формулы v1 в вершине (x, z) узла слоя L; dcam — расстояние до камеры по горизонтали.
static func dh_v1(L: HeightLayer, S: SurfaceLayer, x: float, z: float, dcam: float, look: Dictionary) -> float:
	if not bool(look.get("relief_detail_enabled", true)):
		return 0.0
	var near: Array = look.get("relief_near_m", [200.0, 350.0])
	var kd := _ss(float(near[0]), float(near[1]), dcam)
	if kd <= 0.0:
		return 0.0
	var sp := L.spacing
	var i := roundi((x - L.origin_x) / sp)
	var j := roundi((z - L.origin_z) / sp)
	var h := L.node(i, j)
	var g1 := Vector2(L.node(i + 1, j) - L.node(i - 1, j), L.node(i, j + 1) - L.node(i, j - 1)) / (2.0 * sp)
	var sl: Array = look.get("relief_slope_deg", [15.0, 30.0])
	var ks := kd * _ss(float(sl[0]), float(sl[1]), rad_to_deg(atan(g1.length())))
	if ks <= 0.0:
		return 0.0
	if S != null:
		var e := float(look.get("surface_edge_sharpness", 0.12))
		ks *= (1.0 - _class_w(S, x, z, SurfaceLayer.FOREST, e)) * (1.0 - _class_w(S, x, z, SurfaceLayer.WATER, e)) \
				* (1.0 - _class_w(S, x, z, SurfaceLayer.BUILT, e))
		if ks <= 0.0:
			return 0.0
	var l1 := (L.node(i + 1, j) + L.node(i - 1, j) + L.node(i, j + 1) + L.node(i, j - 1)) * 0.25 - h
	var smax := float(look.get("relief_sharpen_max_m", 8.0))
	var dh := clampf(-float(look.get("relief_sharpen", 0.8)) * l1, -smax, smax)
	var gully := float(look.get("relief_gully", 1.0))
	if bool(look.get("erosion_enabled", true)) and gully > 0.0:
		var escale := float(look.get("erosion_scale_m", 140.0))
		var lod_e := clampf(log(0.5 * escale / sp) / log(2.0), 0.0, 14.0)
		var d := sp * pow(2.0, lod_e)
		var ge := Vector2(L.sample(x + d, z) - L.sample(x - d, z), L.sample(x, z + d) - L.sample(x, z - d)) / (2.0 * d)
		var es: Array = look.get("erosion_slope_deg", [5.0, 18.0])
		var ek := _ss(float(es[0]), float(es[1]), rad_to_deg(atan(ge.length())))
		var vs := sp * maxf(1.0, dcam / float(look.get("relief_lod_m", 1000.0)))
		dh += gully * _erosion_height(Vector2(x, z), ge, vs, ek, look)
	return dh * ks


# ---------------------------------------------------------------- меш отрисовки


static func _chunk_range(L: HeightLayer, i0: int, j0: int, cells: int) -> Vector2:
	var stride := maxi(1, cells / 16)
	var lo := INF
	var hi := -INF
	var j := j0
	while j <= j0 + cells:
		var i := i0
		while i <= i0 + cells:
			var v := L.node(i, j)
			lo = minf(lo, v)
			hi = maxf(hi, v)
			i += stride
		j += stride
	var margin := (hi - lo) * 0.1 + L.spacing
	return Vector2(lo - margin, hi + margin)


## Вершины чанков всех слоёв при камере cam: LOD по расстоянию до AABB (как update_lods), высота вершины
## = узел слоя + dh. Чанки грубого слоя, целиком покрытые детальным, пропущены (как в build()).
func _rm_build(layers: Array, surfaces: Array, rcfg: Dictionary, cam: Vector3) -> Array:
	var out: Array = []
	for li in layers.size():
		var L: HeightLayer = layers[li]
		var rc: Dictionary = rcfg.get(L.id, {})
		if rc.is_empty():
			continue
		var cells := int(rc.chunk_cells)
		var lod_d: Array = rc.lod_distances_m
		var lodp := PackedFloat32Array(lod_d)
		var v1 := String(_opt.get("dh", "v2")) == "v1"
		var chunk_m := cells * L.spacing
		var nx := (L.width - 1) / cells
		var nz := (L.height - 1) / cells
		var chunks: Array = []
		chunks.resize(nx * nz)
		for cj in nz:
			for ci in nx:
				var x0 := L.origin_x + ci * chunk_m
				var z0 := L.origin_z + cj * chunk_m
				var covered := false
				for k in li:
					var f: HeightLayer = layers[k]
					if x0 >= f.origin_x and z0 >= f.origin_z and x0 + chunk_m <= f.origin_x + f.size_x() \
							and z0 + chunk_m <= f.origin_z + f.size_z():
						covered = true
				if covered:
					continue
				var hr := _chunk_range(L, ci * cells, cj * cells, cells)
				var qx := clampf(cam.x, x0, x0 + chunk_m)
				var qy := clampf(cam.y, hr.x, hr.y)
				var qz := clampf(cam.z, z0, z0 + chunk_m)
				var d := cam.distance_to(Vector3(qx, qy, qz))
				var lod := lod_d.size()
				for k in lod_d.size():
					if d < float(lod_d[k]):
						lod = k
						break
				var s := 1 << lod
				var nv := cells / s + 1
				var verts := PackedFloat32Array()
				verts.resize(nv * nv)
				var dhs := PackedFloat32Array()
				dhs.resize(nv * nv)
				for vj in nv:
					for vi in nv:
						var gi := ci * cells + vi * s
						var gj := cj * cells + vj * s
						var wx := L.origin_x + gi * L.spacing
						var wz := L.origin_z + gj * L.spacing
						var dc := Vector2(wx - cam.x, wz - cam.z).length()
						var dhv: float = dh_v1(L, surfaces[li], wx, wz, dc, _look) if v1 \
								else ReliefLook.dh(L, surfaces[li], wx, wz, cam, _look, lodp)
						verts[vj * nv + vi] = L.node(gi, gj) + dhv
						dhs[vj * nv + vi] = dhv
				chunks[cj * nx + ci] = {"lod": lod, "s": s, "nv": nv, "verts": verts, "dhs": dhs, "x0": x0, "z0": z0}
		out.append({"L": L, "S": surfaces[li], "cells": cells, "chunk_m": chunk_m, "nx": nx, "nz": nz, "chunks": chunks,
				"skirt": float(rc.skirt_depth_m), "li": li})
	return out


## Слой, чей чанк рисует точку (индекс в _rm), и сам чанк; -1 — нет.
func _rm_sample(x: float, z: float) -> float:
	for lay in _rm:
		var v := _rm_sample_layer(lay, x, z)
		if not is_nan(v):
			return v
	return _game_h(x, z)


## Высота меша слоя lay в точке; NAN — точка вне слоя или чанк не рисуется.
func _rm_sample_layer(lay: Dictionary, x: float, z: float, key: String = "verts") -> float:
	var L: HeightLayer = lay.L
	if not L.contains(x, z):
		return NAN
	var ci := clampi(int((x - L.origin_x) / lay.chunk_m), 0, lay.nx - 1)
	var cj := clampi(int((z - L.origin_z) / lay.chunk_m), 0, lay.nz - 1)
	var ch: Variant = lay.chunks[cj * lay.nx + ci]
	if ch == null:
		return NAN
	var step: float = L.spacing * float(ch.s)
	var u: float = (x - float(ch.x0)) / step
	var v: float = (z - float(ch.z0)) / step
	var nv: int = ch.nv
	var iu := clampi(int(floorf(u)), 0, nv - 2)
	var iv := clampi(int(floorf(v)), 0, nv - 2)
	var fu: float = u - iu
	var fv: float = v - iv
	var vs: PackedFloat32Array = ch[key]
	var a := vs[iv * nv + iu]
	var b := vs[iv * nv + iu + 1]
	var c := vs[(iv + 1) * nv + iu]
	var d := vs[(iv + 1) * nv + iu + 1]
	if fu + fv <= 1.0:
		return a + fu * (b - a) + fv * (c - a)
	return d + (1.0 - fu) * (c - d) + (1.0 - fv) * (b - d)


## Шаг вершин (м) в точке и id слоя — для радиуса сравнения пиков и доли фона.
func _rm_step(x: float, z: float) -> float:
	for lay in _rm:
		var L: HeightLayer = lay.L
		if not L.contains(x, z):
			continue
		var ci := clampi(int((x - L.origin_x) / lay.chunk_m), 0, lay.nx - 1)
		var cj := clampi(int((z - L.origin_z) / lay.chunk_m), 0, lay.nz - 1)
		var ch: Variant = lay.chunks[cj * lay.nx + ci]
		if ch != null:
			return L.spacing * ch.s
	return 100.0

# ---------------------------------------------------------------- меш: швы, долины, перепад высот


## Статистика меша отрисовки (_rm): по слоям — dh вершин (всех; в вогнутых местах дальше VALLEY_MIN_KM —
## «надувание долин»), перепад высот ReliefLook.local_relief_m (открытые узлы, выборка), щели на стыках
## чанков разного LOD (|вершина мелкого − линия крупного| против юбки) и скачок силуэта на краю
## детального слоя (меш детального − меш фона в одной точке).
func _mesh_stats(_rcfg: Dictionary) -> Dictionary:
	var layers: Array = []
	for lay: Dictionary in _rm:
		var L: HeightLayer = lay.L
		var S: SurfaceLayer = lay.S
		var li: int = lay.li
		var k := maxi(1, int(round(VALLEY_SCALE_M / L.spacing)))
		var r := k * L.spacing
		var dh_all: Array = []
		var dh_far: Array = []
		var valley: Array = []
		var rl: Array = []
		var n_v := 0
		var sum_far := 0.0
		for ch: Variant in lay.chunks:
			if ch == null:
				continue
			var nv: int = ch.nv
			var s: int = ch.s
			var gi0 := roundi((float(ch.x0) - L.origin_x) / L.spacing)
			var gj0 := roundi((float(ch.z0) - L.origin_z) / L.spacing)
			var vs: PackedFloat32Array = ch.verts
			for vj in nv:
				for vi in nv:
					var gi := gi0 + vi * s
					var gj := gj0 + vj * s
					var wx := L.origin_x + gi * L.spacing
					var wz := L.origin_z + gj * L.spacing
					if li > 0 and _D.contains(wx, wz):
						continue
					var h := L.node(gi, gj)
					var dh := vs[vj * nv + vi] - h
					n_v += 1
					var dist := Vector2(wx, wz).distance_to(_c) / 1000.0
					if absf(dh) > 0.01:
						dh_all.append(dh)
					if dist < VALLEY_MIN_KM:
						continue
					sum_far += dh
					dh_far.append(dh)
					var lap := (L.node(gi + k, gj) + L.node(gi - k, gj) + L.node(gi, gj + k) + L.node(gi, gj - k) - 4.0 * h) / (4.0 * r)
					if lap > VALLEY_LAP:
						valley.append(dh)
					if (vi + 3 * vj) % 7 == 0 and S != null and ReliefLook.open_share(S, wx, wz, _look) > 0.5:
						rl.append(ReliefLook.local_relief_m(L, wx, wz, _look))
		var vmean := 0.0
		for v: float in valley:
			vmean += v
		vmean = vmean / valley.size() if valley.size() > 0 else NAN
		var gr := _lod_gaps(lay)
		var gaps: Array = gr[0]
		var over: int = gr[1]
		layers.append({"id": L.id, "vertices": n_v,
				"dh_m_p50": _num(_pct(dh_all.duplicate(), 0.5)), "dh_m_p90": _num(_pct(dh_all.duplicate(), 0.9)),
				"dh_m_p99": _num(_pct(dh_all.duplicate(), 0.99)), "dh_m_max": _num(_pct(dh_all.duplicate(), 1.0)),
				"dh_m_min": _num(_pct(dh_all.duplicate(), 0.0)),
				"dh_far_mean_m": _num(sum_far / maxf(dh_far.size(), 1.0)),
				"valley_n": valley.size(), "valley_dh_mean_m": _num(vmean),
				"valley_dh_p90_m": _num(_pct(valley.duplicate(), 0.9)), "valley_dh_max_m": _num(_pct(valley.duplicate(), 1.0)),
				"local_relief_m_p10": _num(_pct(rl.duplicate(), 0.1)), "local_relief_m_p50": _num(_pct(rl.duplicate(), 0.5)),
				"local_relief_m_p90": _num(_pct(rl.duplicate(), 0.9)),
				"lod_gap_n": gaps.size(), "lod_gap_m_p50": _num(_pct(gaps.duplicate(), 0.5)),
				"lod_gap_m_p99": _num(_pct(gaps.duplicate(), 0.99)), "lod_gap_m_max": _num(_pct(gaps.duplicate(), 1.0)),
				"lod_gap_over_skirt": over, "skirt_m": lay.skirt})
	var out := {"valley_scale_m": VALLEY_SCALE_M, "valley_lap": VALLEY_LAP, "valley_min_km": VALLEY_MIN_KM, "layers": layers}
	if _rm.size() > 1:
		out["layer_seam"] = _layer_seam()
	return out


## Щели на стыках соседних чанков разного LOD: насколько линия крупного чанка на общем ребре выше вершины
## мелкого (эту щель видно со стороны мелкого, ближнего к камере), м; [щели, сколько не закрыто юбкой крупного
## (низ юбки — вершина − skirt − max(dh, 0), как в шейдере; v1 — без поправки)].
func _lod_gaps(lay: Dictionary) -> Array:
	var gaps: Array = []
	var open_n := 0
	var skirt: float = lay.skirt
	var v2 := String(_opt.get("dh", "v2")) != "v1"
	var nx: int = lay.nx
	var nz: int = lay.nz
	for cj in nz:
		for ci in nx:
			var a: Variant = lay.chunks[cj * nx + ci]
			if a == null:
				continue
			for dir in 2:
				var bi := ci + (1 if dir == 0 else 0)
				var bj := cj + (0 if dir == 0 else 1)
				if bi >= nx or bj >= nz:
					continue
				var b: Variant = lay.chunks[bj * nx + bi]
				if b == null or int(a.s) == int(b.s):
					continue
				var fine: Dictionary = a if int(a.s) < int(b.s) else b
				var coarse: Dictionary = b if int(a.s) < int(b.s) else a
				var f_first: bool = fine == b   # мелкий — правый/нижний: его ребро — первый столбец/строка
				var fnv: int = fine.nv
				var cnv: int = coarse.nv
				var fv: PackedFloat32Array = fine.verts
				var cv: PackedFloat32Array = coarse.verts
				var cd: PackedFloat32Array = coarse.dhs
				var ratio := int(coarse.s) / int(fine.s)
				for t in fnv:
					var fi := (t if dir == 1 else (0 if f_first else fnv - 1))
					var fj := (t if dir == 0 else (0 if f_first else fnv - 1))
					var hf := fv[fj * fnv + fi]
					var q := float(t) / ratio
					var q0 := mini(int(floorf(q)), cnv - 2)
					var fr := q - q0
					var e := cnv - 1 if f_first else 0   # ребро крупного — у мелкого справа/снизу
					var k0 := q0 * cnv + e if dir == 0 else e * cnv + q0
					var k1 := (q0 + 1) * cnv + e if dir == 0 else e * cnv + q0 + 1
					var c0 := cv[k0]
					var c1 := cv[k1]
					var b0 := c0 - skirt - (maxf(cd[k0], 0.0) if v2 else 0.0)
					var b1 := c1 - skirt - (maxf(cd[k1], 0.0) if v2 else 0.0)
					if lerpf(b0, b1, fr) > hf:
						open_n += 1
					# видимая щель — крупный выше мелкого (мелкий чанк ближе к камере; обратную щель
					# закрывает поверхность самого мелкого чанка)
					gaps.append(maxf(lerpf(c0, c1, fr) - hf, 0.0))
	return [gaps, open_n]


## Скачок силуэта на краю детального слоя: меш детального − меш фона в точках на 1 узел внутри края.
func _layer_seam() -> Dictionary:
	var dl: Dictionary = _rm[0]
	var D: HeightLayer = dl.L
	var jumps: Array = []
	var absj: Array = []
	var r_max := float(_opt.range_km) * 1000.0
	var v2 := String(_opt.get("dh", "v2")) != "v1"
	var open_n := 0
	var step := D.spacing * 2.0
	var e := 0.5   # детальный — на 0,5 м внутри края, фон — на 0,5 м снаружи (его чанки под детальным не рисуются)
	var x0 := D.origin_x
	var z0 := D.origin_z
	var x1 := D.origin_x + D.size_x()
	var z1 := D.origin_z + D.size_z()
	var pts: Array = []   # [точка на краю, нормаль наружу]
	var n := int((x1 - x0) / step)
	for k in range(1, n):
		var u := x0 + k * step
		pts.append([Vector2(u, z0), Vector2(0, -1)])
		pts.append([Vector2(u, z1), Vector2(0, 1)])
		var w := z0 + k * step
		pts.append([Vector2(x0, w), Vector2(-1, 0)])
		pts.append([Vector2(x1, w), Vector2(1, 0)])
	for pn: Array in pts:
		var p: Vector2 = pn[0]
		var o: Vector2 = pn[1]
		if p.distance_to(_c) > r_max:
			continue
		var p_in := p - o * e
		var p_out := p + o * e
		var hd := _rm_sample_layer(dl, p_in.x, p_in.y)
		var hf := NAN
		for k in range(1, _rm.size()):
			hf = _rm_sample_layer(_rm[k], p_out.x, p_out.y)
			if not is_nan(hf):
				break
		if is_nan(hd) or is_nan(hf):
			continue
		jumps.append(hd - hf)
		absj.append(absf(hd - hf))
		# камера внутри детального: видна щель, где фон выше края детального глубже юбки фона
		# (низ юбки — от высоты без подъёма, как в шейдере v2)
		var lf: Dictionary = _rm[_rm.size() - 1]
		var dhf := maxf(_rm_sample_layer(lf, p_out.x, p_out.y, "dhs"), 0.0) if v2 else 0.0
		if hf - float(lf.skirt) - dhf > hd:
			open_n += 1
	var mean := 0.0
	for j: float in jumps:
		mean += j
	return {"n": jumps.size(), "open_over_skirt": open_n, "jump_mean_m": _num(mean / maxf(jumps.size(), 1.0)),
			"jump_abs_m_p50": _num(_pct(absj.duplicate(), 0.5)), "jump_abs_m_p90": _num(_pct(absj.duplicate(), 0.9)),
			"jump_abs_m_max": _num(_pct(absj.duplicate(), 1.0))}


# ---------------------------------------------------------------- горизонт


func _horizon() -> Dictionary:
	var step := float(_opt.az_step)
	var n_az := int(round(360.0 / step))
	var ds := 30.0
	var r_max := float(_opt.range_km) * 1000.0
	var n_steps := int((r_max - ds) / ds) + 1
	var res: Array = []
	res.resize(n_az)
	var job := func(a: int) -> void:
		var th := deg_to_rad(a * step)
		var dx := sin(th)
		var dz := -cos(th)
		var best := PackedFloat32Array([-9.0, -9.0, -9.0, -9.0, 0.0, 0.0, 0.0, 0.0])
		for k in n_steps:
			var r := ds + k * ds
			var x := _c.x + dx * r
			var z := _c.y + dz * r
			var corr := r / (2.0 * EARTH_R) * (1.0 - REFRACTION_K)
			var a0 := atan2(_R30.sample(x, z) - _h_eye, r) - corr
			var a1 := atan2(_R100.sample(x, z) - _h_eye, r) - corr
			var a2 := atan2(_game_h(x, z) - _h_eye, r) - corr
			var a3 := atan2(_rm_sample(x, z) - _h_eye, r) - corr
			if a0 > best[0]:
				best[0] = a0
				best[4] = r
			if a1 > best[1]:
				best[1] = a1
				best[7] = r
			if a2 > best[2]:
				best[2] = a2
				best[5] = r
			if a3 > best[3]:
				best[3] = a3
				best[6] = r
		res[a] = best
	var gid := WorkerThreadPool.add_group_task(job, n_az, -1, true, "mlk_horizon")
	while not WorkerThreadPool.is_group_task_completed(gid):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(gid)
	var f_raw := PackedFloat64Array()
	var f_r100 := PackedFloat64Array()
	var f_game := PackedFloat64Array()
	var f_rend := PackedFloat64Array()
	for a in n_az:
		var b: PackedFloat32Array = res[a]
		f_raw.append(rad_to_deg(b[0]))
		f_r100.append(rad_to_deg(b[1]))
		f_game.append(rad_to_deg(b[2]))
		f_rend.append(rad_to_deg(b[3]))
	var win := maxi(1, int(round(1.0 / step)))  # ±1° = окно 2°
	var rough := func(s: PackedFloat64Array) -> float:
		var acc := 0.0
		for a in n_az:
			var m := 0.0
			for w in range(-win, win + 1):
				m += s[posmod(a + w, n_az)]
			m /= (2 * win + 1)
			acc += (s[a] - m) * (s[a] - m)
		return sqrt(acc / n_az)
	var def_all: Array = []
	var d_grid: Array = []
	var d_src: Array = []
	var d_lod: Array = []
	var far_r := 0
	var far_g := 0
	for a in n_az:
		var b: PackedFloat32Array = res[a]
		def_all.append(f_raw[a] - f_rend[a])
		d_grid.append(f_raw[a] - f_r100[a])
		d_src.append(f_r100[a] - f_game[a])
		d_lod.append(f_game[a] - f_rend[a])
		var pr := Vector2(_c.x + sin(deg_to_rad(a * step)) * b[6], _c.y - cos(deg_to_rad(a * step)) * b[6])
		var pg := Vector2(_c.x + sin(deg_to_rad(a * step)) * b[5], _c.y - cos(deg_to_rad(a * step)) * b[5])
		if not _D.contains(pr.x, pr.y):
			far_r += 1
		if not _D.contains(pg.x, pg.y):
			far_g += 1
	var rr: float = rough.call(f_raw)
	var rd: float = rough.call(f_rend)
	var summary := {
		"az_step_deg": step, "rough_raw_deg": rr, "rough_render_deg": rd, "rough_ratio": rd / maxf(rr, 1e-9),
		"rough_game_deg": rough.call(f_game), "rough_raw100_deg": rough.call(f_r100),
		"deficit_deg_p50": _pct(def_all.duplicate(), 0.5), "deficit_deg_p90": _pct(def_all.duplicate(), 0.9),
		"deficit_deg_max": _pct(def_all.duplicate(), 1.0),
		"deficit_grid100_deg_p50": _pct(d_grid.duplicate(), 0.5), "deficit_grid100_deg_p90": _pct(d_grid.duplicate(), 0.9),
		"deficit_source_deg_p50": _pct(d_src.duplicate(), 0.5), "deficit_source_deg_p90": _pct(d_src.duplicate(), 0.9),
		"deficit_lod_deg_p50": _pct(d_lod.duplicate(), 0.5), "deficit_lod_deg_p90": _pct(d_lod.duplicate(), 0.9),
		"far_layer_share": float(far_r) / n_az, "far_layer_share_game": float(far_g) / n_az,
		"elev_raw_max_deg": _pct(Array(f_raw).duplicate(), 1.0), "range_km": float(_opt.range_km),
	}
	return {"res": res, "raw": f_raw, "r100": f_r100, "game": f_game, "render": f_rend, "summary": summary, "n_az": n_az}


func _write_profile(path: String, hz: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("az_deg,raw30_deg,raw100_deg,game_deg,render_deg,dist_raw_km,dist_render_km")
	var step := float(_opt.az_step)
	for a in int(hz.n_az):
		var b: PackedFloat32Array = hz.res[a]
		f.store_line("%.2f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f" % [a * step, hz.raw[a], hz.r100[a], hz.game[a], hz.render[a],
				b[4] / 1000.0, b[6] / 1000.0])
	f.close()


# ---------------------------------------------------------------- вершины


func _disc_max(f: Callable, p: Vector2, rad: float, step: float) -> float:
	var m := -INF
	var n := int(rad / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			if Vector2(i, j).length() * step <= rad:
				m = maxf(m, float(f.call(p.x + i * step, p.y + j * step)))
	return m


func _peaks(hz: Dictionary, t: Terrain) -> Array:
	var step := float(_opt.az_step)
	var n_az: int = hz.n_az
	var raw: PackedFloat64Array = hz.raw
	var w1 := maxi(1, int(round(1.0 / step)))
	var w3 := maxi(2, int(round(3.0 / step)))
	var cand: Array = []
	for a in n_az:
		var v := raw[a]
		var is_max := true
		var lo := v
		for w in range(-w3, w3 + 1):
			var u := raw[posmod(a + w, n_az)]
			lo = minf(lo, u)
			if absi(w) <= w1 and u > v:
				is_max = false
		if is_max and v - lo >= 0.25:
			cand.append([v, a])
	cand.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	var pts: Array = []
	var used: Array = []
	for c in cand:
		if pts.size() >= 10:
			break
		var a: int = c[1]
		var b: PackedFloat32Array = hz.res[a]
		var th := deg_to_rad(a * step)
		pts.append({"name": "sil_az%.1f" % (a * step), "az": a * step,
				"pos": Vector2(_c.x + sin(th) * b[4], _c.y - cos(th) * b[4])})
	for tg in String(_opt.targets).split(";", false):
		var p := tg.split(",")
		if p.size() >= 3:
			pts.append({"name": p[2], "az": NAN, "pos": t.latlon_to_local(float(p[0]), float(p[1]))})
	var out: Array = []
	var fr := func(x: float, z: float) -> float: return _R30.sample(x, z)
	var fg := func(x: float, z: float) -> float: return _game_h(x, z)
	var fd := func(x: float, z: float) -> float: return _rm_sample(x, z)
	var f100 := func(x: float, z: float) -> float: return _R100.sample(x, z)
	for q in pts:
		var p: Vector2 = q.pos
		# поднять до локального максимума сырых в 300 м
		for it in 12:
			var best := p
			var bh: float = fr.call(p.x, p.y)
			for dj in range(-2, 3):
				for di in range(-2, 3):
					var pp := p + Vector2(di, dj) * 30.0
					var hh: float = fr.call(pp.x, pp.y)
					if hh > bh:
						bh = hh
						best = pp
			if best == p:
				break
			p = best
		var d := p.distance_to(_c)
		var rad := 150.0 + 0.5 * _rm_step(p.x, p.y)
		var h_raw := _disc_max(fr, p, rad, 30.0)
		var h_r100 := _disc_max(f100, p, rad, 50.0)
		var h_game := _disc_max(fg, p, rad, 25.0)
		var h_rend := _disc_max(fd, p, rad, 25.0)
		var elev_raw := rad_to_deg(atan2(h_raw - _h_eye, d))
		var elev_rend := rad_to_deg(atan2(h_rend - _h_eye, d))
		var ll := t.local_to_latlon(p.x, p.y)
		out.append({"name": q.name, "lat": _num(ll.x), "lon": _num(ll.y), "dist_km": _num(d / 1000.0),
				"layer": _D.id if _D.contains(p.x, p.y) else (_F.id if _F != null else _D.id),
				"h_raw": _num(h_raw), "h_raw100": _num(h_r100), "h_game": _num(h_game), "h_render": _num(h_rend),
				"loss_grid_m": _num(h_raw - h_r100), "loss_source_m": _num(h_r100 - h_game),
				"loss_lod_m": _num(h_game - h_rend), "deficit_deg": _num(elev_raw - elev_rend),
				"elev_raw_deg": _num(elev_raw), "disc_radius_m": rad, "vertex_step_m": _rm_step(p.x, p.y)})
	return out


# ---------------------------------------------------------------- гребни


func _treeline(L: HeightLayer, S: SurfaceLayer) -> float:
	var hs: Array = []
	var st := maxi(1, int(L.spacing >= 50.0) + 2)
	for j in range(0, L.height, st):
		for i in range(0, L.width, st):
			if S.node(i, j) == SurfaceLayer.FOREST:
				hs.append(L.heights[j * L.width + i])
	return _pct(hs, 0.95) if hs.size() > 100 else NAN


func _crests(t: Terrain, li: int, R: HeightLayer, treeline: float, bands: Array) -> Array:
	var L: HeightLayer = t.layers[li]
	var S: SurfaceLayer = t.surfaces[li]
	var is_far := li > 0
	var sp := L.spacing
	var nb := bands.size()
	var curv: Array = []
	var drop: Array = []
	var dropr: Array = []
	for k in nb * 3:
		curv.append([])
		drop.append([])
		dropr.append([])
	var tl := treeline if not is_nan(treeline) else INF
	for j in range(1, L.height - 1):
		var z := L.origin_z + j * sp
		for i in range(1, L.width - 1):
			var x := L.origin_x + i * sp
			if is_far and _D.contains(x, z):
				continue
			if not R.contains(x - sp, z - sp) or not R.contains(x + sp, z + sp):
				continue
			var dist := Vector2(x, z).distance_to(_c) / 1000.0
			var b := -1
			for k in nb:
				if dist >= bands[k][0] and dist < bands[k][1]:
					b = k
			if b < 0:
				continue
			var h0 := R.sample(x, z)
			var lap := (R.sample(x + sp, z) + R.sample(x - sp, z) + R.sample(x, z + sp) + R.sample(x, z - sp) - 4.0 * h0) / (4.0 * sp)
			if lap >= CREST_LAP:
				continue
			var hg := L.heights[j * L.width + i]
			var lapg := (L.heights[j * L.width + i + 1] + L.heights[j * L.width + i - 1] + L.heights[(j + 1) * L.width + i]
					+ L.heights[(j - 1) * L.width + i] - 4.0 * hg) / (4.0 * sp)
			var ratio := lapg / lap
			var dr := h0 - hg
			var drr := h0 - _rm_sample(x, z)
			var cls := S.node(i, j)
			var zs := [0]
			if cls == SurfaceLayer.FOREST:
				zs.append(2)
			elif hg >= tl:
				var open := true
				for dj in range(-2, 3):
					for di in range(-2, 3):
						if S.node(i + di, j + dj) == SurfaceLayer.FOREST:
							open = false
				if open:
					zs.append(1)
			for zi in zs:
				var idx: int = b * 3 + zi
				curv[idx].append(ratio)
				drop[idx].append(dr)
				dropr[idx].append(drr)
	var out: Array = []
	for b in nb:
		for zi in 3:
			var idx := b * 3 + zi
			var n: int = curv[idx].size()
			out.append({"layer": L.id, "band_km": bands[b], "zone": ZONES[zi], "n": n,
					"curv_ratio": _num(_pct(curv[idx], 0.5)) if n >= 5 else null,
					"drop_m_p50": _num(_pct(drop[idx], 0.5)) if n >= 5 else null,
					"drop_m_p90": _num(_pct(drop[idx], 0.9)) if n >= 5 else null,
					"drop_render_m_p50": _num(_pct(dropr[idx], 0.5)) if n >= 5 else null,
					"drop_render_m_p90": _num(_pct(dropr[idx], 0.9)) if n >= 5 else null})
	return out


# ---------------------------------------------------------------- память


static func _mb(b: float) -> float:
	return snappedf(b / 1048576.0, 0.1)


func _memory(t: Terrain) -> Dictionary:
	var S: SurfaceLayer = t.surfaces[0]
	var mask_sp := S.mask_spacing if S.has_forest_mask() else 10.0
	var rows: Array = []
	for size_km: float in [40.0, 60.0, 80.0]:
		var w := int(round(size_km * 1000.0 / _D.spacing)) + 1
		var heights_rf := w * w * 4.0 * 4.0 / 3.0  # RF + мипы
		var classes := float(w * w)  # R8
		var mw := int(round(size_km * 1000.0 / mask_sp)) + 1
		var mask := mw * mw * 2.0  # RG8 без мипов
		rows.append({"detail_km": size_km, "heights_rf_mips_mb": _mb(heights_rf), "classes_r8_mb": _mb(classes),
				"mask10_rg8_mb": _mb(mask), "detail_total_mb": _mb(heights_rf + classes + mask),
				"heights_cpu_f32_mb": _mb(w * w * 4.0)})
	var far_mb := 0.0
	if _F != null and _F != _D:
		far_mb = _F.width * _F.height * 4.0 * 4.0 / 3.0 + _F.width * _F.height
	return {"rows": rows, "far_layer_mb": _mb(far_mb), "mask_spacing_m": mask_sp,
			"note": "VRAM: высоты RF с мипами 4·4/3 Б/клетку, классы R8, маска RG8 2 Б/клетку без мипов; relief-поля ограничены grid_max 801 (не растут)"}
