class_name AirNnPrep
extends RefCounted
## Вход и выход нейросети области (контракт O3 docs/contracts/air-onnx.md): перенос один в один
## tools/research/air_nn_pilot/pilotnn/prep.py (П2 v3/v4). float64 внутри, float32 на выходе карт и чисел.
## Системы: x — восток (ось i), y — север (ось j), массивы [j][i] плоско j·nx + i; сетка квадратная (96²).
## Поворот — против часовой на k·90° (np.rot90(a, −k) для [j, i]), остаток r — в числа (cos r, sin r).

const AGL: Array = [25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000]
const N_CH := 7
const Z0 := 0.1
const MAP_NAMES: Array = ["terrain", "heat_flux", "x", "y", "slope_along", "slope_cross", "tpi_2k", "tpi_8k", "shelter"]
const NORM_TERRAIN_M := 1000.0
const NORM_HEAT_WM2 := 800.0
const NORM_SLOPE := 0.3
const TPI_SIGMAS_M: Array = [2000.0, 8000.0]
const NORM_TPI_M: Array = [300.0, 1000.0]
const SX_STEP_M := 200.0
const SX_MAX_M := 4000.0
const NORM_SX_RAD := 0.3
const FILM_NAMES: Array = ["U10", "cos_r", "sin_r", "alpha", "max_profile", "z_i", "z_lcl", "sun_el", "sun_x", "sun_y",
		"heat", "t_max", "stab", "cap_flag", "cap_agl", "hour", "brk", "t_air"]
const STAB := "ABCDEF"


## → [k: int, r: float рад]; сектор «куда дует» в повёрнутой системе [−45°, 45°).
static func rotation_of(wdir_deg: float) -> Array:
	var a := deg_to_rad(wdir_deg)
	var phi := atan2(-cos(a), -sin(a))
	var k := posmod(int(roundf(-phi / (PI / 2.0))), 4)
	var r := phi + k * PI / 2.0
	r = fposmod(r + PI, 2.0 * PI) - PI
	if r >= PI / 4.0 - 1e-12:
		k = posmod(k - 1, 4)
		r -= PI / 2.0
	elif r < -PI / 4.0 - 1e-12:
		k = posmod(k + 1, 4)
		r += PI / 2.0
	return [k, r]


## Значение с умолчанием: null и нефинитные числа → default (как g() в prep.film).
static func _num(d: Variant, key: String, default: float) -> float:
	if not (d is Dictionary) or not d.has(key):
		return default
	var v: Variant = d[key]
	if (v is float or v is int) and is_finite(float(v)):
		return float(v)
	return default


static func case_meta(row: Dictionary, hc: PackedFloat64Array) -> Dictionary:
	var pr: Variant = row.get("profile", {})
	var rk := rotation_of(_num(row, "wdir", 270.0))
	var u10 := _num(row, "U10", 10.0)
	var s := 0.0
	for v in hc:
		s += v
	return {
		"k": rk[0], "r": rk[1], "U10": u10, "alpha": _num(pr, "alpha", 0.2), "mp": _num(pr, "max_profile", 1.5),
		"S": maxf(u10, 1.0), "hc_mean": s / maxf(hc.size(), 1),
	}


## Поворот скалярной карты против часовой на k·90° (np.rot90(a, −k) для [j, i], квадрат n×n).
static func rot_scalar(a: PackedFloat64Array, n: int, k: int) -> PackedFloat64Array:
	var kk := posmod(-k, 4)
	if kk == 0:
		return a.duplicate()
	var o := PackedFloat64Array()
	o.resize(n * n)
	for r in n:
		for c in n:
			var src: int
			match kk:
				1: src = c * n + (n - 1 - r)
				2: src = (n - 1 - r) * n + (n - 1 - c)
				_: src = (n - 1 - c) * n + r
			o[r * n + c] = a[src]
	return o


## Поворот векторного поля (карты и компоненты) против часовой на k·90°.
static func rot_vec(u: PackedFloat64Array, v: PackedFloat64Array, n: int, k: int) -> Array:
	var ru := rot_scalar(u, n, k)
	var rv := rot_scalar(v, n, k)
	match posmod(k, 4):
		0:
			return [ru, rv]
		1:
			var nv := PackedFloat64Array()
			nv.resize(n * n)
			for i in n * n:
				nv[i] = -rv[i]
			return [nv, ru]
		2:
			var a := PackedFloat64Array()
			var b := PackedFloat64Array()
			a.resize(n * n)
			b.resize(n * n)
			for i in n * n:
				a[i] = -ru[i]
				b[i] = -rv[i]
			return [a, b]
		_:
			var nb := PackedFloat64Array()
			nb.resize(n * n)
			for i in n * n:
				nb[i] = -ru[i]
			return [rv, nb]


## np.gradient(h, dx): [d/dj, d/di].
static func _gradient(h: PackedFloat64Array, n: int, dx: float) -> Array:
	var gy := PackedFloat64Array()
	var gx := PackedFloat64Array()
	gy.resize(n * n)
	gx.resize(n * n)
	for j in n:
		for i in n:
			var p := j * n + i
			if i == 0:
				gx[p] = (h[p + 1] - h[p]) / dx
			elif i == n - 1:
				gx[p] = (h[p] - h[p - 1]) / dx
			else:
				gx[p] = (h[p + 1] - h[p - 1]) / (2.0 * dx)
			if j == 0:
				gy[p] = (h[p + n] - h[p]) / dx
			elif j == n - 1:
				gy[p] = (h[p] - h[p - n]) / dx
			else:
				gy[p] = (h[p + n] - h[p - n]) / (2.0 * dx)
	return [gy, gx]


## scipy.ndimage.gaussian_filter(mode="nearest", truncate=4): ядро 2·int(4σ+0.5)+1, нормированное; два прохода.
static func _gauss(h: PackedFloat64Array, n: int, sigma: float) -> PackedFloat64Array:
	var lw := int(4.0 * sigma + 0.5)
	var w := PackedFloat64Array()
	w.resize(2 * lw + 1)
	var sum := 0.0
	for t in 2 * lw + 1:
		var x := float(t - lw)
		w[t] = exp(-0.5 / (sigma * sigma) * x * x)
		sum += w[t]
	for t in 2 * lw + 1:
		w[t] /= sum
	var tmp := PackedFloat64Array()
	tmp.resize(n * n)
	var out := PackedFloat64Array()
	out.resize(n * n)
	var pad := PackedFloat64Array()
	pad.resize(n + 2 * lw)
	var nt := 2 * lw + 1
	for pass_i in 2:
		var src: PackedFloat64Array = h if pass_i == 0 else tmp
		for line in n:
			for q in n + 2 * lw:
				var idx := clampi(q - lw, 0, n - 1)
				pad[q] = src[line * n + idx] if pass_i == 0 else src[idx * n + line]
			for i in n:
				var acc := 0.0
				for t in nt:
					acc += w[t] * pad[i + t]
				if pass_i == 0:
					tmp[line * n + i] = acc
				else:
					out[i * n + line] = acc
	return out


## hc − G_σ(hc), м.
static func tpi(hc: PackedFloat64Array, n: int, sigma_m: float, dx: float) -> PackedFloat64Array:
	var g := _gauss(hc, n, sigma_m / dx)
	var o := PackedFloat64Array()
	o.resize(n * n)
	for i in n * n:
		o[i] = hc[i] - g[i]
	return o


## Sx (Winstral 2002) на повёрнутом рельефе: max по d от atan((h(p − d·ê′) − h(p))/d), рад.
static func shelter(h: PackedFloat64Array, n: int, r: float, dx: float) -> PackedFloat64Array:
	var c := cos(r)
	var s := sin(r)
	var best := PackedFloat64Array()
	best.resize(n * n)
	best.fill(-INF)
	var nd := int(ceilf((SX_MAX_M + 0.5 * SX_STEP_M - SX_STEP_M) / SX_STEP_M))
	var hi := float(n - 1)
	for m in nd:
		var d := SX_STEP_M * (m + 1)
		var oj := d * s / dx
		var oi := d * c / dx
		for j in n:
			var yj := clampf(j - oj, 0.0, hi)
			var j0 := mini(int(yj), n - 2)
			var ty := yj - j0
			for i in n:
				var xi := clampf(i - oi, 0.0, hi)
				var i0 := mini(int(xi), n - 2)
				var tx := xi - i0
				var p := j0 * n + i0
				var hu := (h[p] * (1.0 - tx) + h[p + 1] * tx) * (1.0 - ty) + (h[p + n] * (1.0 - tx) + h[p + n + 1] * tx) * ty
				var q := j * n + i
				var v := atan((hu - h[q]) / d)
				if v > best[q]:
					best[q] = v
	return best


## Карты входа в повёрнутой системе, порядок MAP_NAMES (первые n_maps), [c][j′][i′] float32.
static func maps(hc: PackedFloat64Array, heat: PackedFloat64Array, meta: Dictionary, n_maps: int = 9, dx: float = 400.0) -> PackedFloat32Array:
	var n := int(roundf(sqrt(float(hc.size()))))
	var nn := n * n
	var k: int = meta["k"]
	var r: float = meta["r"]
	var half := 0.5 * n * dx
	var hr := rot_scalar(hc, n, k)
	var mean := 0.0
	for v in hr:
		mean += v
	mean /= nn
	var out := PackedFloat32Array()
	out.resize(n_maps * nn)
	var hrot := rot_scalar(heat, n, k) if n_maps > 1 else PackedFloat64Array()
	var sa := PackedFloat64Array()
	var sc := PackedFloat64Array()
	if n_maps > 4:
		var g := _gradient(hr, n, dx)
		var gy: PackedFloat64Array = g[0]
		var gx: PackedFloat64Array = g[1]
		var c := cos(r)
		var s := sin(r)
		sa.resize(nn)
		sc.resize(nn)
		for i in nn:
			sa[i] = gx[i] * c + gy[i] * s
			sc[i] = -gx[i] * s + gy[i] * c
	var t2 := PackedFloat64Array()
	var t8 := PackedFloat64Array()
	var sx := PackedFloat64Array()
	if n_maps > 6:
		t2 = tpi(hr, n, TPI_SIGMAS_M[0], dx)
	if n_maps > 7:
		t8 = tpi(hr, n, TPI_SIGMAS_M[1], dx)
	if n_maps > 8:
		sx = shelter(hr, n, r, dx)
	for j in n:
		var yy := ((j + 0.5) * dx - half) / half
		for i in n:
			var p := j * n + i
			for c_i in n_maps:
				var v: float
				match c_i:
					0: v = (hr[p] - mean) / NORM_TERRAIN_M
					1: v = hrot[p] / NORM_HEAT_WM2
					2: v = ((i + 0.5) * dx - half) / half
					3: v = yy
					4: v = sa[p] / NORM_SLOPE
					5: v = sc[p] / NORM_SLOPE
					6: v = t2[p] / NORM_TPI_M[0]
					7: v = t8[p] / NORM_TPI_M[1]
					_: v = sx[p] / NORM_SX_RAD
				out[c_i * nn + p] = v
	return out


## 18 чисел FiLM (порядок FILM_NAMES), float32.
static func film(row: Dictionary, meta: Dictionary) -> PackedFloat32Array:
	var pr: Variant = row.get("profile", {})
	var day: Variant = row.get("day", {})
	if day == null:
		day = {}
	var hm: float = meta["hc_mean"]
	var az := deg_to_rad(_num(pr, "sun_az", 180.0))
	var sx := sin(az)
	var sy := cos(az)
	for _i in int(meta["k"]):
		var t := sx
		sx = -sy
		sy = t
	var cap_ok: bool = day is Dictionary and day.has("cap_agl") and (day["cap_agl"] is float or day["cap_agl"] is int) \
		and is_finite(float(day["cap_agl"]))
	var cap := float(day["cap_agl"]) if cap_ok else 0.0
	var st := str(pr.get("stab", "D")) if pr is Dictionary else "D"
	var si := STAB.find(st) if st.length() == 1 else -1
	var v := PackedFloat32Array([
		meta["U10"] / 10.0, cos(meta["r"]), sin(meta["r"]),
		(meta["alpha"] - 0.2) / 0.1, (meta["mp"] - 1.5) / 0.5,
		(_num(day, "z_i_msl", hm) - hm) / 1000.0, (_num(day, "z_lcl_msl", hm + 3000.0) - hm) / 1000.0,
		_num(pr, "sun_el", 0.0) / 90.0, sx, sy, _num(day, "heat", 0.0), (_num(row, "t_max", 26.0) - 26.0) / 8.0,
		(si - 2.5) / 2.5 if si >= 0 else 0.0, 1.0 if cap_ok else 0.0, cap / 1000.0 if cap_ok else 0.0,
		(_num(row, "hour", 14.0) - 14.0) / 6.0, _num(day, "brk", 1.0), (_num(day, "t", 20.0) - 20.0) / 10.0])
	return v


## Профиль притока Ub(a) = U10·mp·min((max(a, z0)/z_sat)^α, 1), z_sat = 10·mp^(1/α).
static func ubg(agl: float, alpha: float, mp: float, u10: float) -> float:
	var z_sat := 10.0 * pow(mp, 1.0 / alpha)
	return u10 * mp * minf(pow(maxf(agl, Z0) / z_sat, alpha), 1.0)


## Выход сети [91·ny·nx] (повёрнутая система, единицы П2) → {m: 3·13·ny·nx (u, v, w), h: 4·13·ny·nx (u, v, w, θ′)},
## исходная система; индекс ((c·13 + a)·ny + j)·nx + i; м/с и К.
static func to_physical(out: PackedFloat32Array, meta: Dictionary, nx: int = 96, ny: int = 96) -> Dictionary:
	assert(nx == ny)
	var n := nx
	var nn := n * n
	var na := AGL.size()
	var k: int = meta["k"]
	var r: float = meta["r"]
	var s: float = meta["S"]
	var cr := cos(r)
	var sr := sin(r)
	var res := {}
	var kinv := posmod(-k, 4)
	for key in ["m", "h"]:
		var c0 := 0 if key == "m" else 3
		var nc := 3 if key == "m" else 4
		var buf := PackedFloat32Array()
		buf.resize(nc * na * nn)
		for a in na:
			var ub := ubg(AGL[a], meta["alpha"], meta["mp"], meta["U10"])
			var up := PackedFloat64Array()
			var vp := PackedFloat64Array()
			var wp := PackedFloat64Array()
			up.resize(nn)
			vp.resize(nn)
			wp.resize(nn)
			var o0 := (c0 * na + a) * nn
			var o1 := ((c0 + 1) * na + a) * nn
			var o2 := ((c0 + 2) * na + a) * nn
			for p in nn:
				up[p] = out[o0 + p] * s + ub * cr
				vp[p] = out[o1 + p] * s + ub * sr
				wp[p] = out[o2 + p] * s
			var uv := rot_vec(up, vp, n, kinv)
			var chans: Array = [uv[0], uv[1], rot_scalar(wp, n, kinv)]
			if nc == 4:
				var th := PackedFloat64Array()
				th.resize(nn)
				var o3 := ((c0 + 3) * na + a) * nn
				for p in nn:
					th[p] = out[o3 + p]
				chans.append(rot_scalar(th, n, kinv))
			for c in nc:
				var ch: PackedFloat64Array = chans[c]
				var base := (c * na + a) * nn
				for p in nn:
					buf[base + p] = ch[p]
		res[key] = buf
	return res
