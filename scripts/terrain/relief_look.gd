class_name ReliefLook
extends RefCounted
## CPU-зеркало дальней формы рельефа (MLK-К2 v2): смещение вершины меша dh, как его считает vertex()
## terrain.gdshader (только картинка — физика, height_at его не видит). Шейдер и зеркало правятся вместе.
##
## dh = подъём выпуклых мест к максимуму окна (а) + заострение гребней и промоины на открытых склонах (б):
##  (а) окно максимумов ±2^(L−1) узла, L = уровень LOD по 3D-дальности до камеры (пороги слоя lod_m, плавно
##      за relief_peak_ramp доли порога) + relief_peak_level; дробный уровень — смесь соседних. Вес —
##      выпуклость (h − среднее на уровне L+1)/(max − h) через smoothstep(0, relief_peak_convex): в долинах
##      и на ровных склонах 0; × «вершина горы в окне»: 1 − smoothstep(0, relief_peak_summit, (max окна вдвое
##      шире − max)/(max − h)) — на склоне окно лишь дотягивается вверх, подъёма нет. dh_a = relief_peak · вес · min(max − h, relief_peak_max_m).
##  (б) перепад высот на relief_scale_m (max − среднее) → kr = smoothstep(relief_high_m): доля кривизны
##      relief_sharpen → relief_sharpen_high, предел relief_sharpen_max_m → clamp(relief_subgrid_k·шаг·tg уклона,
##      relief_sharpen_max_m, relief_sharpen_cap_m); маска уклона relief_slope_deg; промоины relief_gully.
##  (а) — только дальше relief_peak_near_m по горизонтали (ближе окно сдвигает гребень к камере: угол h/r²·сдвиг
##  больше, чем срезает LOD); (б) × гашение у камеры relief_near_m; всё × доля «открытого» (не лес/вода/застройка).
## Приближения зеркала: доли классов без шума границ (surface_edge_noise), градиент промоин — разностью
## на шаге мипа (не trilinear); textureLod — билинейно + между уровнями, как GPU (точность весов GPU — нет).


## dh вершины в мировой точке (x, z) — узле слоя layer; cam — позиция камеры (мир), lod_m — пороги LOD
## слоя (render.<слой>.lod_distances_m), surface — карта поверхности слоя (null — всё открыто).
static func dh(
	layer: HeightLayer,
	surface: SurfaceLayer,
	x: float,
	z: float,
	cam: Vector3,
	look: Dictionary,
	lod_m: PackedFloat32Array
) -> float:
	if not bool(look.get("relief_detail_enabled", true)):
		return 0.0
	var near: Array = look.get("relief_near_m", [200.0, 350.0])
	var dcam := Vector2(x - cam.x, z - cam.z).length()
	var kd := _ss(float(near[0]), float(near[1]), dcam)
	if kd <= 0.0:
		return 0.0
	var sp := layer.spacing
	var i := roundi((x - layer.origin_x) / sp)
	var j := roundi((z - layer.origin_z) / sp)
	var h := layer.node(i, j)
	var g1 := (
		Vector2(layer.node(i + 1, j) - layer.node(i - 1, j), layer.node(i, j + 1) - layer.node(i, j - 1))
		/ (2.0 * sp)
	)
	var sl: Array = look.get("relief_slope_deg", [15.0, 30.0])
	var ks := kd * _ss(float(sl[0]), float(sl[1]), rad_to_deg(atan(g1.length())))
	var peak := float(look.get("relief_peak", 1.0))
	var pn: Array = look.get("relief_peak_near_m", [5000.0, 10000.0])
	var kp := _ss(float(pn[0]), float(pn[1]), dcam)
	var lw := 0.0
	if peak > 0.0 and kp > 0.0:
		var d3 := Vector3(x, h, z).distance_to(cam)
		lw = clampf(lod_level(d3, lod_m, look) + float(look.get("relief_peak_level", -1.0)), 0.0, 6.0)
	var ko := 1.0
	if (ks > 0.0 or lw > 0.0) and surface != null:
		ko = open_share(surface, x, z, look)
		ks *= ko
	var out := 0.0
	if lw > 0.0 and ko > 0.0:
		var l0 := int(floorf(lw))
		var fw := lw - l0
		var m1 := max_window(layer, i, j, l0 + 1)
		var m := lerpf(max_window(layer, i, j, l0), m1, fw)
		var m2 := lerpf(m1, max_window(layer, i, j, l0 + 2), fw)
		var mean := mean_lod(layer, x, z, lw + 1.0)
		var up := m - h + 0.5
		var w := (
			_ss(0.0, float(look.get("relief_peak_convex", 0.25)), (h - mean) / up)
			* (1.0 - _ss(0.0, float(look.get("relief_peak_summit", 0.5)), (m2 - m) / up))
		)
		out += peak * w * clampf(m - h, 0.0, float(look.get("relief_peak_max_m", 400.0))) * kp * ko
	if ks > 0.0:
		var kr := high_share(layer, x, z, look)
		var smax := float(look.get("relief_sharpen_max_m", 8.0))
		var cap := lerpf(
			smax,
			clampf(
				float(look.get("relief_subgrid_k", 0.25)) * sp * g1.length(),
				smax,
				float(look.get("relief_sharpen_cap_m", 30.0))
			),
			kr
		)
		var l1 := (
			(layer.node(i + 1, j) + layer.node(i - 1, j) + layer.node(i, j + 1) + layer.node(i, j - 1)) * 0.25
			- h
		)
		var sh := lerpf(
			float(look.get("relief_sharpen", 0.8)), float(look.get("relief_sharpen_high", 1.0)), kr
		)
		var ds := clampf(-sh * l1, -cap, cap)
		var gully := float(look.get("relief_gully", 1.0))
		if bool(look.get("erosion_enabled", true)) and gully > 0.0:
			var escale := float(look.get("erosion_scale_m", 140.0))
			var lod_e := clampf(log(0.5 * escale / sp) / log(2.0), 0.0, 14.0)
			var d := sp * pow(2.0, lod_e)
			var ge := (
				Vector2(
					layer.sample(x + d, z) - layer.sample(x - d, z),
					layer.sample(x, z + d) - layer.sample(x, z - d)
				)
				/ (2.0 * d)
			)
			var es: Array = look.get("erosion_slope_deg", [5.0, 18.0])
			var ek := _ss(float(es[0]), float(es[1]), rad_to_deg(atan(ge.length())))
			var vs := sp * maxf(1.0, dcam / float(look.get("relief_lod_m", 1000.0)))
			ds += gully * _erosion_height(Vector2(x, z), ge, vs, ek, look)
		out += ds * ks
	return out


## Предел |dh| конфига (контракт К2 v2): заострение ≤ relief_sharpen_cap_m (и relief_sharpen_max_m),
## промоины ≤ erosion_strength·λ/2π по октавам (уклон до 1), подъём пика ≤ relief_peak_max_m.
static func dh_limit_m(look: Dictionary) -> float:
	var cap := maxf(
		float(look.get("relief_sharpen_cap_m", 30.0)), float(look.get("relief_sharpen_max_m", 8.0))
	)
	var gully := (
		float(look.get("relief_gully", 1.0))
		* float(look.get("erosion_strength", 0.45))
		* float(look.get("erosion_scale_m", 140.0))
		/ 6.2832
		* 2.0
	)
	return cap + gully + float(look.get("relief_peak", 1.0)) * float(look.get("relief_peak_max_m", 400.0))


## Уровень LOD (log2 шага вершин в узлах) по 3D-дальности d: ступени порогов lod_m, каждая плавно.
static func lod_level(d: float, lod_m: PackedFloat32Array, look: Dictionary) -> float:
	var ramp := float(look.get("relief_peak_ramp", 0.25))
	var s := 0.0
	for k in mini(lod_m.size(), 4):
		s += _ss(lod_m[k] * (1.0 - ramp), lod_m[k], d)
	return s


## Максимум узлов в окне ±2^(L−1) узла вокруг (i, j) — 2×2 текселя уровня L пирамиды (как шейдер).
static func max_window(layer: HeightLayer, i: int, j: int, lv: int) -> float:
	if lv <= 0:
		return layer.node(i, j)
	var hw := 1 << (lv - 1)
	var a_i := (i - hw) >> lv
	var a_j := (j - hw) >> lv
	var b_i := (i + hw) >> lv
	var b_j := (j + hw) >> lv
	return maxf(
		maxf(layer.max_texel(lv, a_i, a_j), layer.max_texel(lv, b_i, a_j)),
		maxf(layer.max_texel(lv, a_i, b_j), layer.max_texel(lv, b_i, b_j))
	)


## Доля «высоких гор» 0..1: перепад max − среднее на relief_scale_m (как шейдер: textureLod пирамид).
static func high_share(layer: HeightLayer, x: float, z: float, look: Dictionary) -> float:
	var hm: Array = look.get("relief_high_m", [150.0, 400.0])
	return _ss(float(hm[0]), float(hm[1]), local_relief_m(layer, x, z, look))


## Перепад высот max − среднее на relief_scale_m, м.
static func local_relief_m(layer: HeightLayer, x: float, z: float, look: Dictionary) -> float:
	var lr := log(float(look.get("relief_scale_m", 1000.0)) / layer.spacing) / log(2.0)
	var fx := (x - layer.origin_x) / layer.spacing + 0.5
	var fz := (z - layer.origin_z) / layer.spacing + 0.5
	var w1 := maxi(1, layer.width >> 1)
	var h1 := maxi(1, layer.height >> 1)
	var mx := _tex_lod(
		layer.max_pyramid(), w1, h1, Vector2(fx / (2.0 * w1), fz / (2.0 * h1)), maxf(lr - 1.0, 0.0)
	)
	return mx - mean_lod(layer, x, z, lr)


## Среднее высот как textureLod(height_mip_tex, uv, lod): мипы — Image.generate_mipmaps (2×2 среднее).
static func mean_lod(layer: HeightLayer, x: float, z: float, lod: float) -> float:
	var uv := Vector2(
		((x - layer.origin_x) / layer.spacing + 0.5) / layer.width,
		((z - layer.origin_z) / layer.spacing + 0.5) / layer.height
	)
	return _tex_lod(layer.mean_levels(), layer.width, layer.height, uv, lod)


## Доля открытого склона (1 − лес)(1 − вода)(1 − застройка) по карте классов (без шума границ).
static func open_share(surface: SurfaceLayer, x: float, z: float, look: Dictionary) -> float:
	var e := float(look.get("surface_edge_sharpness", 0.12))
	return (
		(1.0 - _class_w(surface, x, z, SurfaceLayer.FOREST, e))
		* (1.0 - _class_w(surface, x, z, SurfaceLayer.WATER, e))
		* (1.0 - _class_w(surface, x, z, SurfaceLayer.BUILT, e))
	)


# ---------------------------------------------------------------- служебное


## textureLod по цепочке уровней levels (уровень 0 — w0×h0, далее max(1, w>>k)), clamp к краю,
## билинейно в уровне и линейно между уровнями.
static func _tex_lod(levels: Array, w0: int, h0: int, uv: Vector2, lod: float) -> float:
	var top := levels.size() - 1
	lod = clampf(lod, 0.0, float(top))
	var l0 := int(floorf(lod))
	var a := _bilinear(levels[l0], maxi(1, w0 >> l0), maxi(1, h0 >> l0), uv)
	if l0 >= top or lod - l0 <= 0.0:
		return a
	var b := _bilinear(levels[l0 + 1], maxi(1, w0 >> (l0 + 1)), maxi(1, h0 >> (l0 + 1)), uv)
	return lerpf(a, b, lod - l0)


static func _bilinear(a: PackedFloat32Array, w: int, h: int, uv: Vector2) -> float:
	var fx := uv.x * w - 0.5
	var fz := uv.y * h - 0.5
	var i := int(floorf(fx))
	var j := int(floorf(fz))
	var tx := fx - i
	var tz := fz - j
	var i0 := clampi(i, 0, w - 1)
	var i1 := clampi(i + 1, 0, w - 1)
	var j0 := clampi(j, 0, h - 1)
	var j1 := clampi(j + 1, 0, h - 1)
	return lerpf(
		lerpf(a[j0 * w + i0], a[j0 * w + i1], tx), lerpf(a[j1 * w + i0], a[j1 * w + i1], tx), tz
	)


static func _ss(e0: float, e1: float, x: float) -> float:
	var u := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


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
	var a := _gully_cell3(ip, fp, Vector2(0, 0), dir).lerp(
		_gully_cell3(ip, fp, Vector2(1, 0), dir), u.x
	)
	var b := _gully_cell3(ip, fp, Vector2(0, 1), dir).lerp(
		_gully_cell3(ip, fp, Vector2(1, 1), dir), u.x
	)
	return a.lerp(b, u.y)


static func _erosion_height(
	xz: Vector2, g: Vector2, vs: float, k: float, look: Dictionary
) -> float:
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
