class_name AirThermals
extends RefCounted
## Масштаб 2 из поля (AM-07, docs/guide/air-model.md → «Масштаб 2: термики из поля»): источники термиков
## на час из среднего поля одного уровня (WindField) — где, какой силы, до какой высоты, куда
## сносит; и «между» — сколько конвективной вертикали поля остаётся вне пузырей (компенсирующее
## опускание), чтобы средний поток массы пилоту был тем же, что у поля.
##
## Законы (подробно — документ; H_kin = H/(ρc_p), ζ = z/h):
##   w* = (g/θ0 · H_kin · h)^(1/3), h = max(z_i − hc, 300 м) — масштаб Дирдорфа
##   (WindField.deardorff_wstar; H — средний по водосбору источника);
##   w_m = (u*³ + 0,28 w*³)^(1/3), Δθ = b·H_kin/w_m, b = 6,5 — избыток частицы (Холтслаг–Бовилль);
##   F(ζ) = H_kin(1 − ζ)/Δθ = w_m(1 − ζ)/b — поток массы подсеточной конвекции замыкания поля;
##   Φ = F̄ + max(W̄, 0) — восходящий поток поля: подсеточный + организованный (w_conv);
##   потолок — частица θ̄ + θ′ + Δθ теряет плавучесть по θ̄ + θ′ поля; её столб над землёй —
##   местная толщина слоя z_l (не ниже 300 м);
##   ядра — по Аллену (2006): радиус у верха R = r₂(1, z_l), r₂(ζ) = max(10, 0,102ζ^(1/3)(1 −
##   0,25ζ)z_l); живых на площадь n_A = 0,6/(z_l·r₂(½)); сила w0 = k·w*, k = e·max ζ^(1/3)(1 −
##   1,1ζ) ≈ 1,24 — пик Гедеона с потоком ядра среднего подъёма Аллена;
##   плотность источников n = n_A·Φ/Φ̂/p_жизни (Φ̂ — средний Φ кандидатов с весом n_A), не больше
##   Φ/(w0·K̄) — ядра не несут больше потока поля;
##   остаток организованного потока (W̄⁺ сверх несомого ядрами) — широким подъёмом в «между»;
##   кольцо ρ = (1 − O/M)·e⁻¹/|кольцо|: подсеточная доля возвращается у пузыря, организованная O —
##   вверх; «между» = w_conv − ожидаемый чистый поток пузырей: среднее пилоту = w_conv поля.
##   Вода (VI-7): источник не над водой — точка источника только на суше (pick_in_column), а поток
##   столбца источникам — только с его суши: Φ, W̄⁺, H и площадь водосбора × доля суши L (land);
##   столбец целиком на воде (L = 0) — ничей: его w_conv остаётся пилоту широким средним полем.
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
## Аллен (2006, AIAA 2006-1510, по замерам Lenschow & Stephens 1980): радиус восходящего потока
## r₂ = max(R_MIN, 0,102·ζ^(1/3)(1 − 0,25ζ)·z_i), число потоков N = 0,6·A/(z_i·r₂(½)).
const ALLEN_R2 := 0.102
const ALLEN_R_MIN := 10.0
const ALLEN_N := 0.6
## Случайная последовательная укладка кругов (насыщение 0,547): шаг исключения r = √(0,696/n).
const RSA_K := 0.834
const _NQ := 33
const _SM_STEP := 25.0
## Ячейка поиска источников по месту (тень облаков), м.
const _BUCKET_M := 1000.0
## Ячейка поиска источников, столбцов.
const _B := 4
## Доля суши столбца — по _LAND_N × _LAND_N точкам (центры подклеток; 100 м на уровне 400 м).
const _LAND_N := 4

## Уровень поля, по которому построено.
var level: WindField
## Подпись сетки (dx, x0, y0, nx, ny) — для сети: список ведущего применяется к той же сетке.
var grid_sig: String = ""
## Источники: столбец (j·nx + i), точка источника (мир x, z; y — рельеф сетки), сила ядра на пике
## w0 (м/с), радиус ядра у верха (м, Аллен), w* водосбора (м/с), потолок частицы (над морем, м; без
## кромки), снос — средний ветер столба (мир x, z), поток водосбора M (м³/с), из него несут ядра
## (м³/с), площадь водосбора (м²), глубина столба D (м).
var col := PackedInt32Array()
var pos := PackedVector3Array()
var w0 := PackedFloat32Array()
var radius := PackedFloat32Array()
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
## Доля времени, когда термик источника жив (доля циклов × жизнь / период): n_A живых ⇒ n_A/это
## источников.
var alive_frac: float = 1.0
## Средний Φ кандидатов с весом n_A (нормировка плотности), м/с.
var phi_ref: float = 0.0
## Поток, не доставшийся ни одному водосбору (нет источника в досягаемости), м³/с.
var lost_flux: float = 0.0
var total_flux: float = 0.0
## Поток, который несут ядра (Σ carried), м³/с.
var carried_flux: float = 0.0
## Номер источника по столбцу: Vector2i(j, i) -> s.
var index: Dictionary = {}
## Полос параллельной сборки (build, FL-15): 0 — авто (до 4); 1 — последовательно в своём
## потоке. Итог от числа полос не зависит (бит-в-бит).
var bands: int = 0
## По столбцам: доля суши 0..1 (точки не на воде, GroundField.is_water); пусто — воды не знаем
## (вся суша). Вход cfg.land (кеш по подписи сетки) или считается по cfg.water_fn.
var land := PackedFloat32Array()
## Время подсчёта доли суши в этой сборке, мс (0 — из кеша или без воды).
var land_ms: float = 0.0

var _q := PackedFloat32Array()  ## профиль потока ядра по ξ (0..1), _NQ точек
var _q_mean: float = 1.0
var _sm := PackedFloat32Array()  ## средний поток ядра по столбу глубины n·25 м
var _u_scale := PackedFloat32Array()  ## по столбцам: поток ядер водосбора / A_i (м/с)
var _n_scale := PackedFloat32Array()  ## по столбцам: чистый поток пузыря / A_i (м/с)
var _buckets: Dictionary = {}  ## ячейки поиска 1 км: Vector2i -> номера источников
var _mask := PackedByteArray()
var _src_depth := PackedFloat32Array()
var _hcs := PackedFloat32Array()  ## по столбцам: глубина D источника-хозяина (м)


## Есть ли в поле всё нужное: H (meta.heat | heat_array или массив heat файла), z_i, gam.
static func has_inputs(f: WindField) -> bool:
	if f == null:
		return false
	var m := f.meta
	var arrs: Dictionary = m.get("arrays", {})
	var heat: bool = m.has("heat") or m.has("heat_array") or arrs.has("heat")
	return heat and not is_nan(f.z_i()) and f.gam().size() == f.nz


## Радиус восходящего потока Аллена (2006) на высоте ζ = z/z_i слоя толщины zi, м.
static func allen_r2(zeta: float, zi: float) -> float:
	return maxf(ALLEN_R_MIN, ALLEN_R2 * pow(zeta, 1.0 / 3.0) * (1.0 - 0.25 * zeta) * zi)


## Живых потоков Аллена на м² в слое толщины zi: 0,6/(z_i·r₂(½)).
static func allen_density(zi: float) -> float:
	return ALLEN_N / (zi * allen_r2(0.5, zi))


## Два уровня покрывают одни и те же точки (covers: сетка, верх, рельеф сетки, кромка) — клетки
## аналитики вне зависимости от смены источников остаются теми же.
static func same_cover(a: WindField, b: WindField) -> bool:
	if a == b:
		return true
	if a == null or b == null:
		return false
	return (
		a.x0 == b.x0 and a.y0 == b.y0 and a.dx == b.dx and a.nx == b.nx and a.ny == b.ny
		and a.nz == b.nz and a.dz == b.dz and a.z_bot == b.z_bot
		and a.edge_cells == b.edge_cells and a.raw_hc() == b.raw_hc()
	)


static func signature(f: WindField) -> String:
	return "%.3f,%.3f,%.3f,%d,%d" % [f.dx, f.x0, f.y0, f.nx, f.ny]


## Построить источники. cfg — thermal-конфиг (atmosphere.json → thermal) + погода:
##   duty, grow_s/mature_s/decay_s/gap_s, ground_ramp_m,
##   top_taper_m, radius_min_factor, profile_cutoff_radii; cloudbase_msl — кромка из погоды;
##   height_fn(x, z) — настоящая высота земли (для точки источника; нет — рельеф сетки);
##   pick_fn(i, j) -> Vector2 — точка источника внутри столбца (мир x, z; нет — центр);
##   land — доля суши по столбцам (land прежней сборки той же сетки); нет — water_fn(x, z) -> bool.
## forced — битовая маска столбцов-источников (сеть: список ведущего); пусто — выбрать самим.
## false — нет входа (H, z_i) или размеры не сходятся.
func build(f: WindField, cfg: Dictionary, forced := PackedByteArray()) -> bool:
	level = f
	_mask = PackedByteArray()
	var heat := f.heat_flux()
	var k1s := f.raw_k1()
	var hcs := f.raw_hc()
	var n_col := f.nx * f.ny
	if heat.size() != n_col or is_nan(f.z_i()):
		return false
	grid_sig = signature(f)
	_hcs = hcs
	var z_i := f.z_i()
	var gam := f.gam()
	if gam.size() != f.nz:
		gam.resize(f.nz)
		gam.fill(0.0)
	var u10 := f.u10()
	var ustar := KAPPA * u10 / log(10.0 / f.z0) if u10 > 0.0 else 0.0
	var cb := float(cfg.get("cloudbase_msl", INF))
	_setup_shape(cfg)
	var cut := float(cfg.get("profile_cutoff_radii", 2.5))
	# ∫ кольца Гедеона 1..cut² e^(−u)(1 − u) du = cut²·e^(−cut²) − e⁻¹ (< 0)
	var ring_int := absf(cut * cut * exp(-cut * cut) - CORE_FLUX)
	var wconv := f.raw_w_conv()
	var theta := f.raw_theta()
	var vel := f.raw_vel()
	# θ̄ относительно низа сетки (интеграл dθ̄/dz по центрам уровней)
	var tbar := PackedFloat32Array()
	tbar.resize(f.nz)
	var acc := 0.0
	for k in f.nz:
		if k > 0:
			acc += 0.5 * (gam[k - 1] + gam[k]) * f.dz
		tbar[k] = acc
	col_heat = heat.duplicate()
	var cell_a := f.dx * f.dx
	land_ms = 0.0
	land = cfg.get("land", PackedFloat32Array())
	if land.size() != n_col:
		land = PackedFloat32Array()
		var water_fn: Callable = cfg.get("water_fn", Callable())
		if water_fn.is_valid():
			var t0 := Time.get_ticks_usec()
			land = land_fraction(f, water_fn)
			land_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var has_land := not land.is_empty()
	# --- столбцы — полосами строк (параллельно, FL-15): Φ, потолок частицы, z_l, n_A, K̄, кандидаты;
	# полосы склеиваются по порядку строк — как последовательный обход
	var parts := _run_bands(
		f.ny, _cols_band.bind(f, cfg, heat, k1s, hcs, z_i, ustar, cb, cut, tbar, wconv, theta, land)
	)
	var c_top := PackedFloat32Array()
	var c_ws := PackedFloat32Array()
	var cand := PackedInt32Array()
	## Радиус исключения по плотности столба (и досягаемость водосбора = 2 радиуса), м.
	var cand_r := PackedFloat32Array()
	## По столбцам: местная толщина слоя z_l (м), живых потоков Аллена n_A (1/м²), K̄ ядра на 1 м/с.
	var c_zl := PackedFloat32Array()
	var c_na := PackedFloat32Array()
	var c_k := PackedFloat32Array()
	phi = PackedFloat32Array()
	col_w = PackedFloat32Array()
	col_f = PackedFloat32Array()
	for part: Array in parts:
		c_ws.append_array(part[0])
		col_w.append_array(part[1])
		col_f.append_array(part[2])
		phi.append_array(part[3])
		c_top.append_array(part[4])
		c_zl.append_array(part[5])
		cand_r.append_array(part[6])
		c_na.append_array(part[7])
		c_k.append_array(part[8])
		cand.append_array(part[9])
	# --- плотность: живых n_A (Аллен) на площадь, распределённых по Φ (Φ/Φ̂, Φ̂ — средний Φ
	# кандидатов с весом n_A: Σ n·A = Σ n_A·A), ÷ доля жизни; ядра не несут больше Φ столбца.
	var s_na := 0.0
	var s_naphi := 0.0
	for c in cand:
		s_na += c_na[c]
		s_naphi += c_na[c] * phi[c]
	phi_ref = s_naphi / s_na if s_na > 0.0 else 0.0
	for c in n_col:
		if c_na[c] <= 0.0 or phi_ref <= 0.0:
			continue
		var dens := c_na[c] * phi[c] / phi_ref / maxf(alive_frac, 1.0e-3)
		var cap := phi[c] / maxf(K_ALLEN * c_ws[c] * c_k[c], 1.0e-9)
		dens = minf(dens, cap)
		var rc := cand_r[c]
		cand_r[c] = clampf(RSA_K / sqrt(maxf(dens, 1.0e-12)), rc, maxf(4.0 * c_zl[c], rc))
	# --- выбор источников: по убыванию Φ; кандидат берётся, если в радиусе его плотности нет
	# уже взятого (или маска ведущего)
	var nbx := (f.nx + _B - 1) / _B
	var nby := (f.ny + _B - 1) / _B
	var chosen := PackedInt32Array()
	if not forced.is_empty():
		for c in n_col:
			if c >> 3 < forced.size() and (forced[c >> 3] >> (c & 7)) & 1 == 1 and k1s[c] < f.nz:
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
	# --- столбцы без точки источника (вода): не источники; pick_fn детерминирован (столбец, сид),
	# у ведущего и клиентов одинаков
	var pick_fn: Callable = cfg.get("pick_fn", Callable())
	var picked := {}
	if pick_fn.is_valid():
		# точки — параллельно (FL-15: 8 проб силы источника на столбец — главное время сборки)
		var pts := PackedVector2Array()
		for part: PackedVector2Array in _run_bands(chosen.size(), _pick_band.bind(chosen, f.nx, pick_fn)):
			pts.append_array(part)
		var kept := PackedInt32Array()
		for s in chosen.size():
			var c := chosen[s]
			var pp := pts[s]
			if pp == NO_SOURCE:
				continue
			picked[c] = pp
			kept.append(c)
		chosen = kept
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
	# ячейки → источники плоско (s_start/s_list): без Variant-массивов в потоках
	var s_start := PackedInt32Array()
	s_start.resize(nbx * nby + 1)
	var s_list := PackedInt32Array()
	for kb in nbx * nby:
		s_start[kb] = s_list.size()
		if sgrid[kb] != null:
			s_list.append_array(sgrid[kb])
	s_start[nbx * nby] = s_list.size()
	owner = PackedInt32Array()
	for part: PackedInt32Array in _run_bands(
		n_col,
		_owner_band.bind(
			f.nx, f.nz, f.dx, k1s, land, chosen, reach, s_start, s_list, nbx, nby, ring_max
		)
	):
		owner.append_array(part)
	var m_i := PackedFloat64Array()
	m_i.resize(ns)
	var o_i := PackedFloat64Array()
	o_i.resize(ns)
	var a_i := PackedFloat64Array()
	a_i.resize(ns)
	total_flux = 0.0
	lost_flux = 0.0
	for c in n_col:
		if k1s[c] >= f.nz:
			continue
		total_flux += phi[c] * cell_a
		var o := owner[c]
		if o < 0:
			lost_flux += phi[c] * cell_a
			continue
		var la := cell_a * (land[c] if has_land else 1.0)
		m_i[o] += phi[c] * cell_a
		o_i[o] += maxf(col_w[c], 0.0) * la
		a_i[o] += la
	# --- параметры источников (параллельно по источникам; суммы — по порядку)
	var hsum := PackedFloat64Array()
	hsum.resize(ns)
	for c in n_col:
		if owner[c] >= 0:
			hsum[owner[c]] += maxf(heat[c], 0.0) * cell_a * (land[c] if has_land else 1.0)
	col = chosen
	pos = PackedVector3Array()
	w0 = PackedFloat32Array()
	radius = PackedFloat32Array()
	wstar = PackedFloat32Array()
	top = PackedFloat32Array()
	drift = PackedVector2Array()
	flux = PackedFloat32Array()
	carried = PackedFloat32Array()
	net = PackedFloat32Array()
	ring = PackedFloat32Array()
	area = PackedFloat32Array()
	depth = PackedFloat32Array()
	var src_parts := _run_bands(
		ns,
		_src_band.bind(
			f, cfg, chosen, picked, hcs, k1s, c_top, c_zl, cb, z_i, hsum, m_i, o_i, a_i, vel, ring_int
		)
	)
	for part: Array in src_parts:
		pos.append_array(part[0])
		top.append_array(part[1])
		depth.append_array(part[2])
		wstar.append_array(part[3])
		flux.append_array(part[4])
		area.append_array(part[5])
		radius.append_array(part[6])
		w0.append_array(part[7])
		carried.append_array(part[8])
		net.append_array(part[9])
		ring.append_array(part[10])
		drift.append_array(part[11])
	carried_flux = 0.0
	for s in ns:
		carried_flux += carried[s]
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


# ------------------------------------------------- сборка полосами (FL-15, WorkerThreadPool)


## Полосы на n единиц работы: bands > 0 — столько (1 — последовательно в своём потоке, старый
## путь); 0 — по числу ядер, не больше 4, если пул больше одного потока.
func _band_count(n: int) -> int:
	var nb := bands
	if nb <= 0:
		var mt := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
		var cores := OS.get_processor_count()
		# не больше 4: точки источников зовут рельеф (обращения к объектам — общий замок ObjectDB
		# движка), и дальше потоки толкаются на нём — замер FL-15 на точке: 1 → 2,65 с, 2 → 1,74,
		# 4 → 1,24, 8 → 2,27
		nb = 1 if mt == 1 or cores <= 1 else mini(cores, 4)
	return clampi(nb, 1, maxi(n, 1))


## fn(lo, hi) по полосам [lo, hi) из n — в WorkerThreadPool (из рабочего потока — вложенная
## группа, как AirBakedField.load_file); результаты — по порядку полос. fn только читает общие
## данные и пишет в свои массивы: итог тот же, что последовательный обход.
func _run_bands(n: int, fn: Callable) -> Array:
	var nb := _band_count(n)
	var out := []
	out.resize(nb)
	if nb == 1:
		out[0] = fn.call(0, n)
		return out
	var gid := WorkerThreadPool.add_group_task(
		func(b: int) -> void: out[b] = fn.call(n * b / nb, n * (b + 1) / nb),
		nb,
		-1,
		true,
		"AirThermals.build"
	)
	WorkerThreadPool.wait_for_group_task_completion(gid)
	return out


## = WindField.deardorff_wstar (те же выражения) — без обращения к классу из потоков.
static func _wstar(heat_wm2: float, z_i: float, hc: float) -> float:
	if heat_wm2 <= 0.0 or not is_finite(z_i):
		return 0.0
	return pow(
		WindField.G / WindField.THETA0 * heat_wm2 / WindField.RHO_CP * maxf(z_i - hc, WindField.ZI_MIN),
		1.0 / 3.0
	)


## Столбцы строк [lo, hi): [w*, W̄, F̄, Φ, потолок, z_l, радиус исключения, n_A, K̄, кандидаты].
func _cols_band(
	lo: int,
	hi: int,
	f: WindField,
	cfg: Dictionary,
	heat: PackedFloat32Array,
	k1s: PackedInt32Array,
	hcs: PackedFloat32Array,
	z_i: float,
	ustar: float,
	cb: float,
	cut: float,
	tbar: PackedFloat32Array,
	wconv: PackedFloat32Array,
	theta: PackedFloat32Array,
	land: PackedFloat32Array
) -> Array:
	# поля уровня — в локальные: обращение к чужому объекту из потоков упирается в общий замок
	# ObjectDB движка (16 потоков медленнее одного)
	var nx := f.nx
	var ny := f.ny
	var nz := f.nz
	var dx := f.dx
	var dz := f.dz
	var x0 := f.x0
	var y0 := f.y0
	var z_bot := f.z_bot
	var e_cells := f.edge_cells
	var e_inv_dx := f._inv_dx
	var e_inv_dz := f._inv_dz
	var e_z_top := f._z_top
	var nxy := nx * ny
	var has_land := not land.is_empty()
	var nb := (hi - lo) * nx
	var c0 := lo * nx
	var c_ws := PackedFloat32Array()
	var b_w := PackedFloat32Array()
	var b_f := PackedFloat32Array()
	var b_phi := PackedFloat32Array()
	var c_top := PackedFloat32Array()
	var c_zl := PackedFloat32Array()
	var cand_r := PackedFloat32Array()
	var c_na := PackedFloat32Array()
	var c_k := PackedFloat32Array()
	# (Packed-массивы — значения: в цикле по списку resize ушёл бы копии)
	var zero := PackedFloat32Array()
	zero.resize(nb)
	zero.fill(0.0)
	c_ws = zero.duplicate()
	b_w = zero.duplicate()
	b_f = zero.duplicate()
	b_phi = zero.duplicate()
	c_top = zero.duplicate()
	cand_r = zero.duplicate()
	c_na = zero.duplicate()
	c_k = zero.duplicate()
	c_zl.resize(nb)
	c_zl.fill(ZI_MIN)
	var cand := PackedInt32Array()
	for j in range(lo, hi):
		for i in nx:
			var c := j * nx + i
			var l := c - c0
			var k1 := k1s[c]
			if k1 >= nz or is_nan(z_i):
				continue
			var hc := hcs[c]
			var hk := heat[c] / RHO_CP
			var h := maxf(z_i - hc, ZI_MIN)
			var ws := _wstar(heat[c], z_i, hc)
			var wm := pow(ustar * ustar * ustar + 0.28 * ws * ws * ws, 1.0 / 3.0)
			c_ws[l] = ws
			# F̄: средний по слою 0..h поток массы подсеточной конвекции, w_m/(2b)
			var fbar := wm / (2.0 * HB_B) if hk > 0.0 else 0.0
			# W̄: средний w_conv по воздушным клеткам столбца в слое 0..h
			var sw := 0.0
			var nw := 0
			for k in range(k1, nz):
				var zk := z_bot + (k + 0.5) * dz
				if zk - hc > h:
					break
				sw += wconv[k * nxy + c]
				nw += 1
			var wbar := sw / nw if nw > 0 else 0.0
			b_w[l] = wbar
			b_f[l] = fbar
			# источникам — поток только с суши столбца (над водой источника нет)
			b_phi[l] = (fbar + maxf(wbar, 0.0)) * (land[c] if has_land else 1.0)
			# Потолок частицы: θ_p = θ′(k1) + Δθ; выше — θ̄ + θ′ поля.
			var t_top := z_bot + nz * dz
			if hk > 0.0:
				var ex := HB_B * hk / maxf(wm, 1.0e-3)
				var tp := tbar[k1] + theta[k1 * nxy + c] + ex
				var prev := tbar[k1] + theta[k1 * nxy + c]
				for k in range(k1 + 1, nz):
					var te := tbar[k] + theta[k * nxy + c]
					if te >= tp:
						var fr := (tp - prev) / maxf(te - prev, 1.0e-6)
						t_top = z_bot + (k - 0.5 + clampf(fr, 0.0, 1.0)) * dz
						break
					prev = te
			else:
				t_top = hc
			c_top[l] = t_top
			var d_top := minf(t_top, cb) - hc
			var zl := maxf(t_top - hc, ZI_MIN)
			c_zl[l] = zl
			var rc := allen_r2(1.0, zl)
			cand_r[l] = cut * rc
			if hk > 0.0 and b_phi[l] > 0.0:
				c_na[l] = allen_density(zl)
				c_k[l] = CORE_FLUX * PI * rc * rc * _shape_mean(maxf(d_top, ZI_MIN), cfg) * life_mean
			# Кандидат: греется (H > 0), поток есть, столб частицы ≥ ZI_MIN, внутри поля
			if hk <= 0.0 or b_phi[l] <= 0.0 or d_top < ZI_MIN:
				continue
			var ctr := Vector3(x0 + (i + 0.5) * dx, hc + 10.0, -(y0 + (j + 0.5) * dx))
			# = WindField.edge_weight(ctr) < 0.5 (те же выражения)
			var gx := (ctr.x - x0) * e_inv_dx
			var gy := (-ctr.z - y0) * e_inv_dx
			var ed := minf(minf(gx, nx - gx), minf(gy, ny - gy))
			ed = minf(ed, (e_z_top - ctr.y) * e_inv_dz)
			var ew := 1.0
			if ed <= 0.0:
				ew = 0.0
			elif ed < e_cells:
				ew = smoothstep(0.0, e_cells, ed)
			if ew < 0.5:
				continue
			cand.append(c)
	return [c_ws, b_w, b_f, b_phi, c_top, c_zl, cand_r, c_na, c_k, cand]


## Точки источников chosen[lo..hi) (pick_fn детерминирован по столбцу).
func _pick_band(
	lo: int, hi: int, chosen: PackedInt32Array, nx: int, pick_fn: Callable
) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(hi - lo)
	for s in range(lo, hi):
		var c := chosen[s]
		out[s - lo] = pick_fn.call(c % nx, c / nx)
	return out


## Водосборы столбцов [lo, hi): ближайший источник в досягаемости (равные — меньший номер), −1 — ничей.
func _owner_band(
	lo: int,
	hi: int,
	nx: int,
	nz: int,
	dx: float,
	k1s: PackedInt32Array,
	land: PackedFloat32Array,
	chosen: PackedInt32Array,
	reach: PackedFloat32Array,
	s_start: PackedInt32Array,
	s_list: PackedInt32Array,
	nbx: int,
	nby: int,
	ring_max: int
) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(hi - lo)
	out.fill(-1)
	var has_land := not land.is_empty()
	for c in range(lo, hi):
		if k1s[c] >= nz or (has_land and land[c] <= 0.0):
			continue
		var ci := c % nx
		var cj := c / nx
		var bi := ci / _B
		var bj := cj / _B
		var best := -1
		var bd := INF
		for ring_n in ring_max + 1:
			# после кольца ring_n всё ближе ring_n·B·dx уже просмотрено
			if best >= 0 and bd <= pow(maxf(ring_n - 1, 0) * _B * dx, 2.0):
				break
			for dj in range(-ring_n, ring_n + 1):
				var jj := bj + dj
				if jj < 0 or jj >= nby:
					continue
				for di in range(-ring_n, ring_n + 1):
					if maxi(absi(di), absi(dj)) != ring_n:
						continue
					var ii := bi + di
					if ii < 0 or ii >= nbx:
						continue
					var kb := jj * nbx + ii
					for q in range(s_start[kb], s_start[kb + 1]):
						var s2 := s_list[q]
						var sc := chosen[s2]
						var ddx := float(sc % nx - ci) * dx
						var ddy := float(sc / nx - cj) * dx
						var d2 := ddx * ddx + ddy * ddy
						if d2 <= reach[s2] * reach[s2] and (d2 < bd or (d2 == bd and s2 < best)):
							bd = d2
							best = s2
		out[c - lo] = best
	return out


## Параметры источников [lo, hi): [pos, top, depth, w*, M, A, радиус, w0, несут, чистый, кольцо, снос].
func _src_band(
	lo: int,
	hi: int,
	f: WindField,
	cfg: Dictionary,
	chosen: PackedInt32Array,
	picked: Dictionary,
	hcs: PackedFloat32Array,
	k1s: PackedInt32Array,
	c_top: PackedFloat32Array,
	c_zl: PackedFloat32Array,
	cb: float,
	z_i: float,
	hsum: PackedFloat64Array,
	m_i: PackedFloat64Array,
	o_i: PackedFloat64Array,
	a_i: PackedFloat64Array,
	vel: PackedFloat32Array,
	ring_int: float
) -> Array:
	var nx := f.nx
	var nz := f.nz
	var dx := f.dx
	var dz := f.dz
	var x0 := f.x0
	var y0 := f.y0
	var z_bot := f.z_bot
	var nxy := nx * f.ny
	var nb := hi - lo
	var b_pos := PackedVector3Array()
	b_pos.resize(nb)
	var b_drift := PackedVector2Array()
	b_drift.resize(nb)
	var b_top := PackedFloat32Array()
	var b_depth := PackedFloat32Array()
	var b_wstar := PackedFloat32Array()
	var b_flux := PackedFloat32Array()
	var b_area := PackedFloat32Array()
	var b_radius := PackedFloat32Array()
	var b_w0 := PackedFloat32Array()
	var b_carried := PackedFloat32Array()
	var b_net := PackedFloat32Array()
	var b_ring := PackedFloat32Array()
	var zero := PackedFloat32Array()
	zero.resize(nb)
	zero.fill(0.0)
	b_top = zero.duplicate()
	b_depth = zero.duplicate()
	b_wstar = zero.duplicate()
	b_flux = zero.duplicate()
	b_area = zero.duplicate()
	b_radius = zero.duplicate()
	b_w0 = zero.duplicate()
	b_carried = zero.duplicate()
	b_net = zero.duplicate()
	b_ring = zero.duplicate()
	var height_fn: Callable = cfg.get("height_fn", Callable())
	for s in range(lo, hi):
		var l := s - lo
		var c := chosen[s]
		var i := c % nx
		var j := c / nx
		var hc := hcs[c]
		var p := Vector2(x0 + (i + 0.5) * dx, -(y0 + (j + 0.5) * dx))
		if picked.has(c):
			p = picked[c]
		var y := hc
		if height_fn.is_valid():
			y = float(height_fn.call(p.x, p.y))
		b_pos[l] = Vector3(p.x, y, p.y)
		b_top[l] = c_top[c]
		var d_top := maxf(minf(c_top[c], cb) - hc, ZI_MIN)
		b_depth[l] = d_top
		b_wstar[l] = _wstar(hsum[s] / maxf(a_i[s], 1.0), z_i, hc)
		b_flux[l] = m_i[s]
		b_area[l] = a_i[s]
		b_radius[l] = allen_r2(1.0, c_zl[c])
		var kbar := CORE_FLUX * PI * b_radius[l] * b_radius[l] * _shape_mean(d_top, cfg) * life_mean
		b_w0[l] = K_ALLEN * b_wstar[l]
		b_carried[l] = b_w0[l] * kbar
		# Чистый поток пузыря — организованная доля того, что несут ядра; подсеточная доля
		# возвращается кольцом у самого пузыря: ρ = (1 − O/M)·e⁻¹/|кольцо|.
		var org := clampf(o_i[s] / maxf(m_i[s], 1.0e-9), 0.0, 1.0)
		b_net[l] = b_carried[l] * org
		b_ring[l] = (1.0 - org) * CORE_FLUX / ring_int
		# снос: средний ветер столба источника от земли до потолка
		var k1 := k1s[c]
		var su := 0.0
		var sv := 0.0
		var n := 0
		for k in range(k1, nz):
			var zk := z_bot + (k + 0.5) * dz
			if zk > hc + d_top:
				break
			var ix := (k * nxy + c) * 3
			su += vel[ix]
			sv += vel[ix + 1]
			n += 1
		b_drift[l] = Vector2(su / n, -sv / n) if n > 0 else Vector2.ZERO
	return [
		b_pos,
		b_top,
		b_depth,
		b_wstar,
		b_flux,
		b_area,
		b_radius,
		b_w0,
		b_carried,
		b_net,
		b_ring,
		b_drift
	]


## Термик источника s (ThermalField): точка, потолок min(частица, кромка cb), сила, кольцо, радиус
## (Аллен по толщине слоя), редкий очень сильный — как у клетки (радиус не меньше пресета).
## −1 — столб ниже ZI_MIN (термика нет), 0 — обычный, 1 — очень сильный.
func fill(th: AtmoThermal, s: int, rng: RandomNumberGenerator, w: Dictionary, cb: float) -> int:
	th.src = pos[s]
	th.top = minf(top[s], cb)
	if th.top - th.src.y < ZI_MIN:
		return -1
	th.strength = w0[s]
	th.ring = ring[s]
	var rr: Array = w.thermal_radius_m
	th.radius = radius[s]
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


## Доля суши по столбцам уровня f (ny·nx), water_fn(x, z) мира -> true — вода. Сначала углы (общие у
## соседей) и центр столбца: все пять одно — столбец целиком вода (0) или суша (1); иначе (берег) —
## доля из _LAND_N² центров подклеток. Вода/суша мельче столбца, не задевшая ни угла, ни центра, —
## не видна (её точку источника всё равно отсеет pick_in_column). Столбцы в земле — 1.
static func land_fraction(f: WindField, water_fn: Callable) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(f.nx * f.ny)
	out.fill(1.0)
	var k1s := f.raw_k1()
	var cw := f.nx + 1
	var corner := PackedByteArray()
	corner.resize(cw * (f.ny + 1))
	for j in f.ny + 1:
		for i in cw:
			corner[j * cw + i] = 1 if water_fn.call(f.x0 + i * f.dx, -(f.y0 + j * f.dx)) else 0
	var step := f.dx / _LAND_N
	var inv := 1.0 / (_LAND_N * _LAND_N)
	for j in f.ny:
		for i in f.nx:
			var c := j * f.nx + i
			if k1s[c] >= f.nz:
				continue
			var x0 := f.x0 + i * f.dx
			var y0 := f.y0 + j * f.dx
			var nc := (
				corner[j * cw + i] + corner[j * cw + i + 1] + corner[(j + 1) * cw + i]
				+ corner[(j + 1) * cw + i + 1]
			)
			nc += 1 if water_fn.call(x0 + 0.5 * f.dx, -(y0 + 0.5 * f.dx)) else 0
			if nc == 0 or nc == 5:
				out[c] = 0.0 if nc == 5 else 1.0
				continue
			var nw := 0
			for b in _LAND_N:
				var z := -(y0 + (b + 0.5) * step)
				for a in _LAND_N:
					if water_fn.call(x0 + (a + 0.5) * step, z):
						nw += 1
			out[c] = 1.0 - nw * inv
	return out


## Признак «в столбце источника нет» (pick_fn / pick_in_column): лучшая точка с силой 0 (вода).
const NO_SOURCE := Vector2(INF, INF)


## Точка источника в столбце (i, j) уровня f: лучшая по освещённости земли (скалы, опушки —
## GroundField.sun) из candidates точек столбца, не на воде (GroundField.is_water); сид — столбец и
## сид мира (у всех клиентов одна).
static func pick_in_column(
	i: int, j: int, f: WindField, ground: GroundField, seed_value: int, candidates: int
) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(seed_value, i, j))
	# поля — в локальные (зовётся из потоков сборки: обращения к объектам — общий замок движка)
	var x0 := f.x0
	var y0 := f.y0
	var dx := f.dx
	var best := Vector2(x0 + (i + 0.5) * dx, -(y0 + (j + 0.5) * dx))
	var best_s := -1.0
	var has_g := ground != null and ground.has_ground
	var sun_fn: Callable = ground.sun_fn if has_g else Callable()
	for k in candidates:
		var x := x0 + (i + rng.randf_range(0.1, 0.9)) * dx
		var z := -(y0 + (j + rng.randf_range(0.1, 0.9)) * dx)
		# = ground.sun(x, z)
		var s := 0.0
		if has_g:
			s = clampf(float(sun_fn.call(x, z)), 0.0, 1.0) if sun_fn.is_valid() else 1.0
		# над водой источника нет, как бы ни грела вода (тёплое море — H > 0)
		if s > maxf(best_s, 0.0) and ground.is_water(x, z):
			s = 0.0
		if s > best_s:
			best_s = s
			best = Vector2(x, z)
	# все кандидаты без силы источника или на воде — столбец не источник
	if has_g and best_s <= 0.0:
		return NO_SOURCE
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
	var xi := (p.y - _hcs[c]) / _src_depth[c]
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
	alive_frac = (g + m + d) / (g + m + d + gap) * float(cfg.get("duty", 1.0))
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


static func _mid(v: Variant) -> float:
	if v is Array:
		return 0.5 * (float(v[0]) + float(v[1]))
	return float(v)
