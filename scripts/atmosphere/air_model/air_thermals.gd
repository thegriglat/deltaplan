class_name AirThermals
extends RefCounted
## Масштаб 2 из поля (AM-07, docs/air_model.md → «Масштаб 2: термики из поля»): источники термиков
## на час из среднего поля одного уровня (WindField) — где, какой силы, до какой высоты, куда
## сносит; и «между» — сколько конвективной вертикали поля остаётся вне пузырей (компенсирующее
## опускание), чтобы средний поток массы пилоту был тем же, что у поля.
##
## Законы (подробно — документ; H_kin = H/(ρc_p), ζ = z/h):
##   w* = (g/θ0 · H_kin · h)^(1/3), h = max(z_i − hc, 300 м) — масштаб Дирдорфа;
##   w_m = (u*³ + 0,28 w*³)^(1/3), Δθ = b·H_kin/w_m, b = 6,5 — избыток частицы (Холтслаг–Бовилль);
##   F(ζ) = H_kin(1 − ζ)/Δθ = w_m(1 − ζ)/b — поток массы подсеточной конвекции замыкания поля;
##   Φ = F̄ + max(W̄, 0) — поток вверх, который несут ядра: подсеточный + организованный (w_conv);
##   w0 ≈ k·w*, k = e·max ζ^(1/3)(1 − 1,1ζ) ≈ 1,24 — пик Гедеона с потоком ядра Аллена (2006);
##   плотность n = Φ/(k·w*·K̄); сила w0_i = M_i/K̄_i ≤ K_MAX·w*, M_i = Σ Φ·A водосбора;
##   потолок — частица θ̄ + θ′ + Δθ теряет плавучесть по θ̄ + θ′ поля;
##   кольцо ρ = (1 − O/M)·e⁻¹/|кольцо|: подсеточная доля возвращается у пузыря, организованная O —
##   вверх; «между» = w_conv − ожидаемый чистый поток пузырей: среднее пилоту = w_conv поля.
##
## Вход (кроме каналов поля) — в level.meta, их кладёт тот, кто считал поле (как вход решателя):
##   heat_array | heat — поток тепла H (ny·nx), Вт/м²;  z_i — верх слоя перемешивания, м над морем;
##   gam — dθ̄/dz в центрах уровней (nz), К/м;  u10 — ветер прогноза на 10 м (для u*), м/с.
## Нет heat или z_i — источников нет (термики — аналитика).

const G := 9.81
const THETA0 := 300.0
const RHO_CP := 1.2 * 1005.0
const KAPPA := 0.4
## Холтслаг–Бовилль (1993): избыток θ частицы = b·w'θ'₀/w_m.
const HB_B := 6.5
## Мин. толщина слоя перемешивания (как замыкание поля, air.py → Params.zi_min), м.
const ZI_MIN := 300.0
## Пик Гедеона / средний подъём Аллена: ∫ядра e^(−x²)(1 − x²) = πR²·e⁻¹ ⇒ пик = e·среднее;
## среднее Аллена w_c = w*·ζ^(1/3)(1 − 1,1ζ), максимум по ζ — 0,4575 при ζ = 1/4,4.
const K_ALLEN := 2.718281828 * 0.4575
## Доля ядра Гедеона в потоке (∫₀¹ e^(−u)(1 − u) du = e⁻¹).
const CORE_FLUX := 0.36787944
## Предел силы ядра, доли w*: сильнейшие ядра в самолётных замерах — порядка 2–2,5 w* (Lenschow &
## Stephens 1980; Young 1988). Поток сверх w0 = K_MAX·w* (организованный подъём шире ядер: склон,
## схождение) остаётся в «между» — пилоту широким подъёмом, масса сохраняется.
const K_MAX := 2.5
## Случайная последовательная укладка кругов (насыщение 0,547): шаг исключения r = √(0,696/n).
const RSA_K := 0.834
const _NQ := 33
const _SM_STEP := 25.0
## Ячейка поиска источников по месту (тень облаков), м.
const _BUCKET_M := 1000.0
## Ячейка поиска источников, столбцов.
const _B := 4

## Уровень поля, по которому построено.
var level: WindField
## Подпись сетки (dx, x0, y0, nx, ny) — для сети: список ведущего применяется к той же сетке.
var grid_sig: String = ""
## Источники: столбец (j·nx + i), точка источника (мир x, z; y — рельеф сетки), сила ядра на пике
## w0 (м/с), w* водосбора (м/с), потолок частицы (над морем, м; без кромки), снос — средний ветер
## столба (мир x, z), поток водосбора M (м³/с), из него несут ядра (м³/с), площадь водосбора (м²),
## глубина столба D (м).
var col := PackedInt32Array()
var pos := PackedVector3Array()
var w0 := PackedFloat32Array()
var wstar := PackedFloat32Array()
var top := PackedFloat32Array()
var drift := PackedVector2Array()
var flux := PackedFloat32Array()
var carried := PackedFloat32Array()
## Чистый поток пузыря (ядро + кольцо), м³/с, и множитель кольца Гедеона источника: подсеточная
## доля потока ядра возвращается кольцом (чистый ноль, Гедеон ≈ 1,03), организованная (W̄⁺ поля)
## уходит вверх (кольцо слабее).
var net := PackedFloat32Array()
var ring := PackedFloat32Array()
var area := PackedFloat32Array()
var depth := PackedFloat32Array()
## По столбцам: чей водосбор (−1 — ничей), Φ (м/с), H (Вт/м²), W̄ (м/с), F̄ (м/с).
var owner := PackedInt32Array()
var phi := PackedFloat32Array()
var col_heat := PackedFloat32Array()
var col_w := PackedFloat32Array()
var col_f := PackedFloat32Array()
## Средний по столбу поток ядра на 1 м/с пика (без огибающей и доли циклов), м² — K̄/⟨жизнь⟩.
var shape_area: float = 0.0
## Средняя по времени доля (огибающая × доля циклов с термиком).
var life_mean: float = 0.0
## Поток, не доставшийся ни одному водосбору (нет источника в досягаемости), м³/с.
var lost_flux: float = 0.0
var total_flux: float = 0.0
## Поток, который несут ядра (Σ carried), м³/с.
var carried_flux: float = 0.0
## Номер источника по столбцу: Vector2i(j, i) -> s.
var index: Dictionary = {}

var _q := PackedFloat32Array()  ## профиль потока ядра по ξ (0..1), _NQ точек
var _q_mean: float = 1.0
var _sm := PackedFloat32Array()  ## средний поток ядра по столбу глубины n·25 м
var _u_scale := PackedFloat32Array()  ## по столбцам: поток ядер водосбора / A_i (м/с)
var _n_scale := PackedFloat32Array()  ## по столбцам: чистый поток пузыря / A_i (м/с)
var _buckets: Dictionary = {}  ## ячейки поиска 1 км: Vector2i -> номера источников
var _mask := PackedByteArray()
var _src_depth := PackedFloat32Array()  ## по столбцам: глубина D источника-хозяина (м)


## Есть ли в поле всё нужное (H, z_i).
static func has_inputs(f: WindField) -> bool:
	if f == null:
		return false
	var m := f.meta
	return (m.has("heat") or m.has("heat_array") or m.has("arrays")) and m.has("z_i")


## Поток тепла H (ny·nx) из метаданных уровня: heat (PackedFloat32Array/Array) или массив heat
## в .bin файла поля (load_file кладёт путь в meta.path). Пусто — нет.
static func heat_of(f: WindField) -> PackedFloat32Array:
	var m := f.meta
	for k in ["heat", "heat_array"]:
		if m.has(k):
			var v: Variant = m[k]
			if v is PackedFloat32Array:
				return v
			if v is Array:
				return PackedFloat32Array(v)
	if m.has("arrays") and (m.arrays as Dictionary).has("heat") and m.has("path"):
		var raw := FileAccess.get_file_as_bytes(String(m.path) + ".bin")
		if raw.is_empty():
			return PackedFloat32Array()
		var ol: Array = m.arrays.heat
		var h := raw.to_float32_array().slice(int(ol[0]), int(ol[0]) + int(ol[1]))
		m["heat"] = h  # закешировать
		return h
	return PackedFloat32Array()


static func signature(f: WindField) -> String:
	return "%.3f,%.3f,%.3f,%d,%d" % [f.dx, f.x0, f.y0, f.nx, f.ny]


## Построить источники. cfg — thermal-конфиг (atmosphere.json → thermal) + погода:
##   radius_m [rmin, rmax] (у кромки), duty, grow_s/mature_s/decay_s/gap_s, ground_ramp_m,
##   top_taper_m, radius_min_factor, profile_cutoff_radii; cloudbase_msl — кромка из погоды;
##   height_fn(x, z) — настоящая высота земли (для точки источника; нет — рельеф сетки);
##   pick_fn(i, j) -> Vector2 — точка источника внутри столбца (мир x, z; нет — центр).
## forced — битовая маска столбцов-источников (сеть: список ведущего); пусто — выбрать самим.
## false — нет входа (H, z_i) или размеры не сходятся.
func build(f: WindField, cfg: Dictionary, forced := PackedByteArray()) -> bool:
	level = f
	_mask = PackedByteArray()
	var heat := heat_of(f)
	var n_col := f.nx * f.ny
	if heat.size() != n_col or not f.meta.has("z_i"):
		return false
	grid_sig = signature(f)
	var z_i := float(f.meta.z_i)
	var gam := PackedFloat32Array(f.meta.get("gam", []))
	if gam.size() != f.nz:
		gam.resize(f.nz)
		gam.fill(0.0)
	var u10 := float(f.meta.get("u10", float(f.meta.get("cond", {}).get("wind", 0.0))))
	var ustar := KAPPA * u10 / log(10.0 / f.z0) if u10 > 0.0 else 0.0
	var cb := float(cfg.get("cloudbase_msl", INF))
	_setup_shape(cfg)
	var r_bar := _mean_r2(cfg)
	var cut := float(cfg.get("profile_cutoff_radii", 2.5))
	# ∫ кольца Гедеона 1..cut² e^(−u)(1 − u) du = cut²·e^(−cut²) − e⁻¹ (< 0)
	var ring_int := absf(cut * cut * exp(-cut * cut) - CORE_FLUX)
	var r_min_ex := cut * sqrt(r_bar)
	var wconv := f._wconv
	var theta := f._theta
	var vel := f._vel
	var nxy := n_col
	# θ̄ относительно низа сетки (интеграл dθ̄/dz по центрам уровней)
	var tbar := PackedFloat32Array()
	tbar.resize(f.nz)
	var acc := 0.0
	for k in f.nz:
		if k > 0:
			acc += 0.5 * (gam[k - 1] + gam[k]) * f.dz
		tbar[k] = acc
	owner.resize(n_col)
	owner.fill(-1)
	phi.resize(n_col)
	phi.fill(0.0)
	col_heat = heat.duplicate()
	col_w.resize(n_col)
	col_w.fill(0.0)
	col_f.resize(n_col)
	col_f.fill(0.0)
	var c_top := PackedFloat32Array()
	c_top.resize(n_col)
	var c_ws := PackedFloat32Array()
	c_ws.resize(n_col)
	var cand := PackedInt32Array()
	## Радиус исключения по плотности столба (и досягаемость водосбора = 2 радиуса), м.
	var cand_r := PackedFloat32Array()
	cand_r.resize(n_col)
	cand_r.fill(r_min_ex)
	var cell_a := f.dx * f.dx
	for j in f.ny:
		for i in f.nx:
			var c := j * f.nx + i
			var k1 := f._k1[c]
			if k1 >= f.nz or is_nan(z_i):
				continue
			var hc := f._hc[c]
			var h := maxf(z_i - hc, ZI_MIN)
			var hk := heat[c] / RHO_CP
			var ws := pow(G / THETA0 * hk * h, 1.0 / 3.0) if hk > 0.0 else 0.0
			var wm := pow(ustar * ustar * ustar + 0.28 * ws * ws * ws, 1.0 / 3.0)
			c_ws[c] = ws
			# F̄: средний по слою 0..h поток массы подсеточной конвекции, w_m/(2b)
			var fbar := wm / (2.0 * HB_B) if hk > 0.0 else 0.0
			# W̄: средний w_conv по воздушным клеткам столбца в слое 0..h
			var sw := 0.0
			var nw := 0
			for k in range(k1, f.nz):
				var zk := f.z_bot + (k + 0.5) * f.dz
				if zk - hc > h:
					break
				sw += wconv[k * nxy + c]
				nw += 1
			var wbar := sw / nw if nw > 0 else 0.0
			col_w[c] = wbar
			col_f[c] = fbar
			phi[c] = fbar + maxf(wbar, 0.0)
			# Потолок частицы: θ_p = θ′(k1) + Δθ; выше — θ̄ + θ′ поля.
			var t_top := f.z_bot + f.nz * f.dz
			if hk > 0.0:
				var ex := HB_B * hk / maxf(wm, 1.0e-3)
				var tp := tbar[k1] + theta[k1 * nxy + c] + ex
				var prev := tbar[k1] + theta[k1 * nxy + c]
				for k in range(k1 + 1, f.nz):
					var te := tbar[k] + theta[k * nxy + c]
					if te >= tp:
						var fr := (tp - prev) / maxf(te - prev, 1.0e-6)
						t_top = f.z_bot + (k - 0.5 + clampf(fr, 0.0, 1.0)) * f.dz
						break
					prev = te
			else:
				t_top = hc
			c_top[c] = t_top
			var d_top := minf(t_top, cb) - hc
			if hk > 0.0 and phi[c] > 0.0:
				var kbar := (
					CORE_FLUX * PI * r_bar * _shape_mean(maxf(d_top, ZI_MIN), cfg) * life_mean
				)
				var dens := phi[c] / maxf(K_ALLEN * ws * kbar, 1.0e-6)
				cand_r[c] = clampf(RSA_K / sqrt(maxf(dens, 1.0e-12)), r_min_ex, 4.0 * h)
			# Кандидат: греется (H > 0), поток есть, столб частицы ≥ ZI_MIN, внутри поля
			if hk <= 0.0 or phi[c] <= 0.0 or d_top < ZI_MIN:
				continue
			var ctr := Vector3(f.x0 + (i + 0.5) * f.dx, hc + 10.0, -(f.y0 + (j + 0.5) * f.dx))
			if f.edge_weight(ctr) < 0.5:
				continue
			cand.append(c)
	# --- выбор источников: по убыванию Φ; кандидат берётся, если в радиусе его плотности нет
	# уже взятого (или маска ведущего)
	var nbx := (f.nx + _B - 1) / _B
	var nby := (f.ny + _B - 1) / _B
	var chosen := PackedInt32Array()
	if not forced.is_empty():
		for c in n_col:
			if c >> 3 < forced.size() and (forced[c >> 3] >> (c & 7)) & 1 == 1 and f._k1[c] < f.nz:
				chosen.append(c)
	else:
		var order := Array(cand)
		order.sort_custom(
			func(a: int, b: int) -> bool: return phi[a] > phi[b] or (phi[a] == phi[b] and a < b)
		)
		var grid := []
		grid.resize(nbx * nby)
		for c: int in order:
			var ci := c % f.nx
			var cj := c / f.nx
			var r := cand_r[c]
			var rb := int(ceil(r / (_B * f.dx)))
			var bi := ci / _B
			var bj := cj / _B
			var free := true
			for dj in range(maxi(bj - rb, 0), mini(bj + rb, nby - 1) + 1):
				for di in range(maxi(bi - rb, 0), mini(bi + rb, nbx - 1) + 1):
					var arr: Variant = grid[dj * nbx + di]
					if arr == null:
						continue
					for sc: int in arr:
						var ddx := float(sc % f.nx - ci) * f.dx
						var ddy := float(sc / f.nx - cj) * f.dx
						if ddx * ddx + ddy * ddy < r * r:
							free = false
							break
					if not free:
						break
				if not free:
					break
			if not free:
				continue
			chosen.append(c)
			var k := bj * nbx + bi
			if grid[k] == null:
				grid[k] = PackedInt32Array()
			grid[k].append(c)
		chosen.sort()
	# --- водосборы: каждый воздушный столбец — ближайшему источнику в досягаемости (2 радиуса
	# плотности источника); равные расстояния — меньший номер
	var ns := chosen.size()
	var reach := PackedFloat32Array()
	reach.resize(ns)
	var max_reach := 0.0
	var sgrid := []
	sgrid.resize(nbx * nby)
	for s in ns:
		var c := chosen[s]
		reach[s] = 2.0 * cand_r[c]
		max_reach = maxf(max_reach, reach[s])
		var k := (c / f.nx / _B) * nbx + (c % f.nx) / _B
		if sgrid[k] == null:
			sgrid[k] = PackedInt32Array()
		sgrid[k].append(s)
	var ring_max := int(ceil(max_reach / (_B * f.dx))) + 1
	for c in n_col:
		if f._k1[c] >= f.nz:
			continue
		var ci := c % f.nx
		var cj := c / f.nx
		var bi := ci / _B
		var bj := cj / _B
		var best := -1
		var bd := INF
		for ring in ring_max + 1:
			# после кольца ring всё ближе ring·B·dx уже просмотрено
			if best >= 0 and bd <= pow(maxf(ring - 1, 0) * _B * f.dx, 2.0):
				break
			for dj in range(-ring, ring + 1):
				var jj := bj + dj
				if jj < 0 or jj >= nby:
					continue
				for di in range(-ring, ring + 1):
					if maxi(absi(di), absi(dj)) != ring:
						continue
					var ii := bi + di
					if ii < 0 or ii >= nbx:
						continue
					var arr: Variant = sgrid[jj * nbx + ii]
					if arr == null:
						continue
					for s2: int in arr:
						var sc := chosen[s2]
						var ddx := float(sc % f.nx - ci) * f.dx
						var ddy := float(sc / f.nx - cj) * f.dx
						var d2 := ddx * ddx + ddy * ddy
						if d2 <= reach[s2] * reach[s2] and (d2 < bd or (d2 == bd and s2 < best)):
							bd = d2
							best = s2
		owner[c] = best
	var m_i := PackedFloat64Array()
	m_i.resize(ns)
	var o_i := PackedFloat64Array()
	o_i.resize(ns)
	var a_i := PackedFloat64Array()
	a_i.resize(ns)
	total_flux = 0.0
	lost_flux = 0.0
	for c in n_col:
		if f._k1[c] >= f.nz:
			continue
		total_flux += phi[c] * cell_a
		var o := owner[c]
		if o < 0:
			lost_flux += phi[c] * cell_a
			continue
		m_i[o] += phi[c] * cell_a
		o_i[o] += maxf(col_w[c], 0.0) * cell_a
		a_i[o] += cell_a
	# --- параметры источников
	col = chosen
	pos.resize(ns)
	w0.resize(ns)
	wstar.resize(ns)
	top.resize(ns)
	drift.resize(ns)
	flux.resize(ns)
	carried.resize(ns)
	net.resize(ns)
	ring.resize(ns)
	area.resize(ns)
	depth.resize(ns)
	var hsum := PackedFloat64Array()
	hsum.resize(ns)
	for c in n_col:
		if owner[c] >= 0:
			hsum[owner[c]] += maxf(heat[c], 0.0) * cell_a
	var height_fn: Callable = cfg.get("height_fn", Callable())
	var pick_fn: Callable = cfg.get("pick_fn", Callable())
	carried_flux = 0.0
	for s in ns:
		var c := chosen[s]
		var i := c % f.nx
		var j := c / f.nx
		var hc := f._hc[c]
		var p := Vector2(f.x0 + (i + 0.5) * f.dx, -(f.y0 + (j + 0.5) * f.dx))
		if pick_fn.is_valid():
			p = pick_fn.call(i, j)
		var y := hc
		if height_fn.is_valid():
			y = float(height_fn.call(p.x, p.y))
		pos[s] = Vector3(p.x, y, p.y)
		top[s] = c_top[c]
		var d_top := maxf(minf(c_top[c], cb) - hc, ZI_MIN)
		depth[s] = d_top
		var h := maxf(z_i - hc, ZI_MIN)
		var hk := (hsum[s] / maxf(a_i[s], 1.0)) / RHO_CP
		wstar[s] = pow(G / THETA0 * maxf(hk, 0.0) * h, 1.0 / 3.0)
		flux[s] = m_i[s]
		area[s] = a_i[s]
		var kbar := CORE_FLUX * PI * r_bar * _shape_mean(d_top, cfg) * life_mean
		w0[s] = minf(m_i[s] / maxf(kbar, 1.0e-6), K_MAX * wstar[s])
		carried[s] = w0[s] * kbar
		carried_flux += carried[s]
		# Чистый поток пузыря — организованная доля того, что несут ядра; подсеточная доля
		# возвращается кольцом у самого пузыря: ρ = (1 − O/M)·e⁻¹/|кольцо|.
		var org := clampf(o_i[s] / maxf(m_i[s], 1.0e-9), 0.0, 1.0)
		net[s] = carried[s] * org
		ring[s] = (1.0 - org) * CORE_FLUX / ring_int
		# снос: средний ветер столба источника от земли до потолка
		var k1 := f._k1[c]
		var su := 0.0
		var sv := 0.0
		var n := 0
		for k in range(k1, f.nz):
			var zk := f.z_bot + (k + 0.5) * f.dz
			if zk > hc + d_top:
				break
			var ix := (k * nxy + c) * 3
			su += vel[ix]
			sv += vel[ix + 1]
			n += 1
		drift[s] = Vector2(su / n, -sv / n) if n > 0 else Vector2.ZERO
	# --- по столбцам водосбора: поток ядер и чистый поток / A_i (по ξ — профилем q)
	_u_scale.resize(n_col)
	_u_scale.fill(0.0)
	_n_scale.resize(n_col)
	_n_scale.fill(0.0)
	_src_depth.resize(n_col)
	_src_depth.fill(1.0)
	for c in n_col:
		var s := owner[c]
		if s >= 0:
			_u_scale[c] = carried[s] / maxf(a_i[s], 1.0)
			_n_scale[c] = net[s] / maxf(a_i[s], 1.0)
			_src_depth[c] = depth[s]
	index.clear()
	_buckets.clear()
	for s in ns:
		index[Vector2i(chosen[s] / f.nx, chosen[s] % f.nx)] = s
		var bk := Vector2i(floori(pos[s].x / _BUCKET_M), floori(pos[s].z / _BUCKET_M))
		if not _buckets.has(bk):
			_buckets[bk] = PackedInt32Array()
		_buckets[bk].append(s)
	return true


## Термик источника s (ThermalField): точка, потолок min(частица, кромка cb), сила, кольцо, радиус
## (равномерно в пресете погоды w), редкий очень сильный — как у клетки. −1 — столб ниже ZI_MIN
## (термика нет), 0 — обычный, 1 — очень сильный.
func fill(th: AtmoThermal, s: int, rng: RandomNumberGenerator, w: Dictionary, cb: float) -> int:
	th.src = pos[s]
	th.top = minf(top[s], cb)
	if th.top - th.src.y < ZI_MIN:
		return -1
	th.strength = w0[s]
	th.ring = ring[s]
	var rr: Array = w.thermal_radius_m
	th.radius = lerpf(float(rr[0]), float(rr[1]), rng.randf())
	var ext: Array = w.get("thermal_extreme_ms", [])
	if rng.randf() < float(w.get("thermal_extreme_chance", 0.0)) and ext.size() == 2:
		th.strength = rng.randf_range(float(ext[0]), float(ext[1]))
		th.radius = maxf(th.radius, float(rr[1]))
		return 1
	return 0


## «Между» пузырями (ThermalField.sample): к результату пузырей r = (w, маска, болтанка) — w_conv
## поля без ожидаемого чистого потока пузырей (expected_net), вне ядра (× (1 − маска)); доля поля
## fw вместо фонового опускания: маска → маска + (1 − маска)·fw (Atmosphere: фон × (1 − маска)).
func with_between(air: AirFieldSet, p: Vector3, r: Vector3) -> Vector3:
	var fc := air.sample_w_conv(p, NAN)
	if fc.y <= 0.0:
		return r
	var between := fc.x - fc.y * expected_net(p)
	var m := r.y
	return Vector3(r.x + (1.0 - m) * between, m + (1.0 - m) * fc.y, r.z)


## Точка (x, z) там, где термики берутся из поля (уровень покрывает её с весом ≥ ½).
func covers(p: Vector2) -> bool:
	var f := level
	return f != null and f.edge_weight(Vector3(p.x, f.ground_height(p.x, p.y) + 10.0, p.y)) >= 0.5


## Источники с точкой (x, z мира) в круге радиуса r вокруг c или, при r < 0, в прямоугольнике
## c ± half.
func sources_in(c: Vector2, r: float, half := Vector2.ZERO) -> PackedInt32Array:
	var out := PackedInt32Array()
	var h := half if r < 0.0 else Vector2(r, r)
	var lo := c - h
	var hi := c + h
	for bz in range(floori(lo.y / _BUCKET_M), floori(hi.y / _BUCKET_M) + 1):
		for bx in range(floori(lo.x / _BUCKET_M), floori(hi.x / _BUCKET_M) + 1):
			var arr: Variant = _buckets.get(Vector2i(bx, bz))
			if arr == null:
				continue
			for s: int in arr:
				var p := pos[s]
				if p.x < lo.x or p.x > hi.x or p.z < lo.y or p.z > hi.y:
					continue
				if r < 0.0 or Vector2(p.x - c.x, p.z - c.y).length_squared() <= r * r:
					out.append(s)
	return out


## Точка источника в столбце (i, j) уровня f: лучшая по освещённости земли (скалы, опушки —
## GroundField.sun) из candidates точек столбца; сид — столбец и сид мира (у всех клиентов одна).
static func pick_in_column(
	i: int, j: int, f: WindField, ground: GroundField, seed_value: int, candidates: int
) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(seed_value, i, j))
	var best := Vector2(f.x0 + (i + 0.5) * f.dx, -(f.y0 + (j + 0.5) * f.dx))
	var best_s := -1.0
	for k in candidates:
		var x := f.x0 + (i + rng.randf_range(0.1, 0.9)) * f.dx
		var z := -(f.y0 + (j + rng.randf_range(0.1, 0.9)) * f.dx)
		var s := ground.sun(x, z) if ground != null and ground.has_ground else 0.0
		if s > best_s:
			best_s = s
			best = Vector2(x, z)
	return best


func count() -> int:
	return col.size()


## Маска столбцов-источников (бит на столбец, j·nx + i) — для сети.
func mask_bytes() -> PackedByteArray:
	if not _mask.is_empty() or level == null:
		return _mask
	_mask.resize((level.nx * level.ny + 7) >> 3)
	for c in col:
		_mask[c >> 3] = _mask[c >> 3] | (1 << (c & 7))
	return _mask


## Ожидаемый средний поток ядер пузырей водосбора в точке (x, z мира, высота y), м/с (Монте-Карло
## в тестах). Вне поля — 0.
func expected_up(p: Vector3) -> float:
	return _expected(p, _u_scale)


## Ожидаемый средний чистый поток пузырей (ядро + кольцо) в точке, м/с: столько w_conv поля уже
## несут пузыри — «между» = w_conv − это.
func expected_net(p: Vector3) -> float:
	return _expected(p, _n_scale)


func _expected(p: Vector3, scale: PackedFloat32Array) -> float:
	var f := level
	if f == null:
		return 0.0
	var i := int(floor((p.x - f.x0) / f.dx))
	var j := int(floor((-p.z - f.y0) / f.dx))
	if i < 0 or j < 0 or i >= f.nx or j >= f.ny:
		return 0.0
	var c := j * f.nx + i
	var u := scale[c]
	if u == 0.0:
		return 0.0
	var xi := (p.y - f._hc[c]) / _src_depth[c]
	if xi <= 0.0 or xi >= 1.0:
		return 0.0
	var fq := xi * (_NQ - 1)
	var k := int(fq)
	var q := lerpf(_q[k], _q[mini(k + 1, _NQ - 1)], fq - k)
	return u * q / _q_mean


## Номер источника с позицией рядом с точкой (x, z) в радиусе r — для тестов/отладки.
func near(x: float, z: float, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in col.size():
		if Vector2(pos[s].x - x, pos[s].z - z).length() <= r:
			out.append(s)
	return out


# ------------------------------------------------------ форма пузыря (как ThermalField.sample)


## Профиль потока ядра по ξ = высота над источником / глубина столба: R(ξ)²·рост у земли·спад у
## верха (на глубине 1000 м; сам спад зависит от D — _shape_mean пересчитывает).
func _setup_shape(cfg: Dictionary) -> void:
	# ⟨огибающая × доля циклов⟩: пауза, рост (smoothstep, среднее ½), зрелость, распад (½).
	var g := _mid(cfg.grow_s)
	var m := _mid(cfg.mature_s)
	var d := _mid(cfg.decay_s)
	var gap := _mid(cfg.gap_s)
	life_mean = (0.5 * g + m + 0.5 * d) / (g + m + d + gap) * float(cfg.get("duty", 1.0))
	_q.resize(_NQ)
	var s := 0.0
	var d0 := 1000.0
	for n in _NQ:
		var xi := float(n) / (_NQ - 1)
		_q[n] = _q_at(xi, d0, cfg)
		s += _q[n] * (0.5 if n == 0 or n == _NQ - 1 else 1.0)
	_q_mean = maxf(s / (_NQ - 1), 1.0e-6)
	shape_area = CORE_FLUX * PI * _q_mean
	_sm.resize(241)
	for n in _sm.size():
		_sm[n] = _shape_mean_exact(maxf(n * _SM_STEP, 1.0), cfg)


func _q_at(xi: float, d: float, cfg: Dictionary) -> float:
	var rmin := float(cfg.get("radius_min_factor", 0.45))
	var ramp := float(cfg.get("ground_ramp_m", 150.0))
	var taper := float(cfg.get("top_taper_m", 120.0))
	var rf := maxf(rmin, pow(xi, 1.0 / 3.0) * (1.0 - 0.25 * xi) / 0.75)
	var dh := xi * d
	var vert := minf(1.0, pow(dh / ramp, 1.0 / 3.0)) if dh > 0.0 else 0.0
	var tp := smoothstep(0.0, taper, d - dh)
	return rf * rf * vert * tp


## Средний по столбу глубины d поток ядра на 1 м/с пика и R² = 1 (безразмерный); таблица по d
## шагом 25 м (_setup_shape).
func _shape_mean(d: float, _cfg_unused: Dictionary) -> float:
	var fd := clampf(d / _SM_STEP, 0.0, _sm.size() - 1.001)
	var k := int(fd)
	return lerpf(_sm[k], _sm[k + 1], fd - k)


func _shape_mean_exact(d: float, cfg: Dictionary) -> float:
	var s := 0.0
	for n in _NQ:
		var xi := float(n) / (_NQ - 1)
		s += _q_at(xi, d, cfg) * (0.5 if n == 0 or n == _NQ - 1 else 1.0)
	return s / (_NQ - 1)


## E[R²] для радиуса у кромки, равномерного в [rmin, rmax].
static func _mean_r2(cfg: Dictionary) -> float:
	var r: Array = cfg.get("radius_m", [90.0, 170.0])
	var a := float(r[0])
	var b := float(r[1])
	return (a * a + a * b + b * b) / 3.0


static func _mid(v: Variant) -> float:
	if v is Array:
		return 0.5 * (float(v[0]) + float(v[1]))
	return float(v)
