class_name CloudFieldSources
extends RefCounted
## Входы CloudField → по столбцам сетки (docs/research/cloud_field.md, §2): доля площади подъёма,
## дошедшего до основания (a_u), целевая мощность D* (м), снос на высоте основания (м/с),
## рельеф столбцов. Три источника подъёма:
##   конвекция поля (AirThermals): Φ(LCL) = 2Φ̄(1 − ζ_L), ζ_L = (LCL − hc)/(c_top − hc) — доля потока
##     массы, доходящая до основания (профиль Холтслага–Бовилля F(ζ) ∝ 1 − ζ, тот же, что в поле);
##     a_u = Φ(LCL)/w_u, w_u = max(k·w*, w_min) — скорость ядра у основания; «между» (Φ без доли ядер
##     водосбора) — ровным полем, ядра источников — в столбце «источник + снос за время подъёма»;
##   подъём склоном (WindField): w_mech у поверхности на наветренном склоне; воздух, вынесенный
##     к z = hc + w⁺·τ_oro ≥ LCL — в облаке. Прогретая вершина выше LCL — через конвекцию: ζ_L ≤ 0,
##     до основания доходит весь приземный поток 2Φ̄ (воздух у склона сам по себе не насыщен —
##     LCL считан по долине, а свободный воздух наверху суше);
##   аналитика (air == null): живые термики ThermalField — площадь ядра у верха на клетку.
## D*: k_moist·(c_top − LCL) — влажная частица над LCL плавучее сухой (θ вдоль влажной адиабаты
## растёт на Γ_d − Γ_m ≈ 3,8 К/км), k_moist = gam/(gam − GAM_MOIST) по устойчивости над LCL
## (gam поля на высоте основания или N² погоды), не больше k_moist_max.

const G := 9.81
const THETA0 := 300.0
## Наклон θ вдоль влажной адиабаты, К/м: Γ_d − Γ_m ≈ 9,8 − 6,0 К/км (Γ_m при 0…10 °C и 700 гПа,
## Emanuel 1994, табл.).
const GAM_MOIST := 0.0038
## Высота выборки ветра над землёй у склона (слой склонового потока), м.
const SURF_AGL := 100.0


## Собрать входы по столбцам поля cf: {au, ds, vx, vz, hc, mean_v}.
static func prepare(cf: CloudField, inp: Dictionary, cfg: Dictionary) -> Dictionary:
	var nx := cf.nx
	var ny := cf.ny
	var n := nx * ny
	var dx := cf.dx
	var base := cf.base_msl
	var au := PackedFloat32Array()
	au.resize(n)
	au.fill(0.0)
	var ds := PackedFloat32Array()
	ds.resize(n)
	ds.fill(0.0)
	var vx := PackedFloat32Array()
	vx.resize(n)
	var vz := PackedFloat32Array()
	vz.resize(n)
	var hc := PackedFloat32Array()
	hc.resize(n)
	var air: AirThermals = inp.get("air")
	var wf: WindField = inp.get("wind_field")
	if wf == null and air != null:
		wf = air.level
	var weather: Dictionary = inp.get("weather", {}) if inp.get("weather") is Dictionary else {}
	var ground_ref := float(inp.get("ground_ref", base - 1000.0))
	var same_grid := wf != null and wf.nx == nx and wf.ny == ny and wf.dx == dx
	# --- рельеф столбцов
	if same_grid:
		hc = wf.raw_hc().duplicate()
	else:
		hc.fill(ground_ref)
	# --- снос на высоте основания и ветер у склона
	var mean_v := Vector2.ZERO
	var w_surf := PackedFloat32Array()
	var u_surf := PackedFloat32Array()
	if same_grid:
		w_surf.resize(n)
		u_surf.resize(n)
		for j in ny:
			for i in nx:
				var c := j * nx + i
				var x := wf.x0 + (i + 0.5) * dx
				var z := -(wf.y0 + (j + 0.5) * dx)
				var h := hc[c]
				var vb := wf.sample(Vector3(x, maxf(base, h + 50.0), z), h)
				vx[c] = vb.x
				vz[c] = vb.z
				var vs := wf.sample(Vector3(x, h + SURF_AGL, z), h)
				w_surf[c] = vs.y
				u_surf[c] = Vector2(vs.x, vs.z).length()
				mean_v += Vector2(vb.x, vb.z)
		mean_v /= n
	else:
		var wind_at: Callable = inp.get("wind_at", Callable())
		var v := Vector2.ZERO
		if wind_at.is_valid():
			v = wind_at.call(base)
		vx.fill(v.x)
		vz.fill(v.y)
		mean_v = v
	# --- устойчивость над основанием → k_moist
	var gam := _gam_at_base(wf, weather, base)
	var k_max := float(cfg.get("k_moist_max", 3.0))
	var k_moist := k_max
	if gam > GAM_MOIST + 1.0e-4:
		k_moist = clampf(gam / (gam - GAM_MOIST), 1.0, k_max)
	var w_k := float(cfg.get("w_updraft_k", 0.5))
	var w_min := float(cfg.get("w_updraft_min_ms", 0.3))
	var depth_day := float(weather.get("cloud_depth_m", cfg.get("depth_day_default_m", 800.0)))
	# --- конвекция поля: «между» ровным полем
	if air != null and air.phi.size() == n and air.c_top.size() == n:
		var phi := air.phi
		var ctop := air.c_top
		var wst := air.col_wstar
		var owner := air.owner
		var carried := air.carried
		var area := air.area
		var z_i := wf.z_i() if wf != null else NAN
		# z_i над столбцом: с опусканием горно-равнинной циркуляции — AirThermals.col_zi (CLF-10,
		# одно место с потолком частицы и w*), иначе столбцы поля (CLF-К6) той же сетки, иначе скаляр
		var zic := air.col_zi if air.col_zi.size() == n else (
			wf.z_i_col() if wf != null and same_grid else PackedFloat32Array()
		)
		var eps := float(cfg.get("overshoot_flux_frac", 0.2))
		for c in n:
			var top := ctop[c]
			if is_nan(top) or top <= base:
				continue
			var h := hc[c]
			var pen := penetration(base, h, zic[c] if not zic.is_empty() else z_i, top, eps)
			var share := 0.0
			var o := owner[c]
			if o >= 0 and o < carried.size():
				share = carried[o] / maxf(area[o], 1.0)
			var between := maxf(phi[c] - share, 0.0)
			var w_u := maxf(w_k * wst[c], w_min)
			au[c] += pen * between / w_u
			ds[c] = maxf(ds[c], k_moist * (top - base))
		# ядра источников — над точкой «источник + снос за время подъёма до основания»
		var rise_k := float(cfg.get("rise_w_k", 0.5))
		for s in air.count():
			var top := air.top[s]
			var p := air.pos[s]
			if is_nan(top) or top <= base:
				continue
			var w0 := air.w0[s]
			var t_rise := maxf(base - p.y, 0.0) / maxf(rise_k * w0, 0.3)
			var dr := air.drift[s]
			var px := p.x + dr.x * t_rise
			var pz := p.z + dr.y * t_rise
			var i := int(floor((px - cf.x0) / dx))
			var j := int(floor((-pz - cf.y0) / dx))
			if i < 0 or i >= nx or j < 0 or j >= ny:
				continue
			var c := j * nx + i
			var zi_s := z_i
			if zic.size() == n and air.col[s] < n:
				zi_s = zic[air.col[s]]
			elif wf != null:
				zi_s = wf.z_i_at(p)
			var pen := penetration(base, p.y, zi_s, top, eps)
			var w_u := maxf(w_k * air.wstar[s], w_min)
			au[c] += pen * air.carried[s] / (dx * dx * w_u)
			ds[c] = maxf(ds[c], k_moist * (top - base))
	elif inp.get("thermals") is Array:
		# аналитика: живые термики — площадь ядра у верха (огибающая) на клетку
		for th: AtmoThermal in inp.thermals:
			if th == null or th.strength <= 0.0 or th.env <= 0.0:
				continue
			var top := th.top
			var y := th.src.y
			if top <= base - 1.0:
				continue
			var ax := th.axis_at(base)
			var i := int(floor((ax.x - cf.x0) / dx))
			var j := int(floor((-ax.y - cf.y0) / dx))
			if i < 0 or i >= nx or j < 0 or j >= ny:
				continue
			var c := j * nx + i
			var pen := 2.0 * clampf(1.0 - (base - y) / maxf(top - y, 1.0), 0.0, 1.0)
			au[c] += pen * PI * th.radius * th.radius * th.env / (dx * dx)
			var d := th.cloud_depth if th.cloud_depth > 0.0 else depth_day
			ds[c] = maxf(ds[c], d * (1.0 + th.overdevelop))
	# --- подъём склоном (нужен ветер у поверхности)
	if same_grid:
		var tau_oro := float(cfg.get("oro_rise_s", 120.0))
		var ramp := maxf(float(cfg.get("oro_ramp_m", 150.0)), 1.0)
		var w_ref := maxf(float(cfg.get("oro_w_ref_ms", 1.0)), 1.0e-3)
		for c in n:
			var wp := maxf(w_surf[c], 0.0)
			if wp <= 0.0:
				continue
			var z_reach := hc[c] + wp * tau_oro
			var reach := clampf((z_reach - base + ramp) / ramp, 0.0, 1.0)
			if reach <= 0.0:
				continue
			var a_oro := reach * clampf(wp / w_ref, 0.0, 1.0)
			if a_oro <= 0.0:
				continue
			au[c] += a_oro
			ds[c] = maxf(ds[c], z_reach - base + ramp)
	for c in n:
		au[c] = minf(au[c], 1.0)
	return {au = au, ds = ds, vx = vx, vz = vz, hc = hc, mean_v = mean_v}


## Доля потока массы столбца, доходящая до высоты z (0..2): профиль Холтслага–Бовилля F = 2F̄(1 − ζ),
## ζ = (z − hc)/(z_i − hc), не меньше eps в слое; выше z_i — хвост проникающих частиц: eps у z_i,
## 0 у потолка частицы c_top (eps — отношение потока на верху слоя к приземному, как
## entrainment ratio A ≈ 0,2, Stull 1988).
static func penetration(z: float, hc: float, z_i: float, top: float, eps: float) -> float:
	if is_nan(top) or z >= top:
		return 0.0
	var zi := maxf(z_i, hc + 300.0) if not is_nan(z_i) else top
	if z <= zi:
		return 2.0 * maxf(1.0 - (z - hc) / maxf(zi - hc, 1.0), eps)
	return 2.0 * eps * clampf((top - z) / maxf(top - zi, 1.0), 0.0, 1.0)


## dθ̄/dz на высоте основания, К/м: gam поля на уровне LCL, иначе N² погоды (N² = g/θ₀·dθ/dz),
## иначе 0,0058 (4 К/км по T — умеренно устойчивый воздух хорошей погоды, weather_model.json).
static func _gam_at_base(wf: WindField, weather: Dictionary, base: float) -> float:
	if wf != null:
		var g := wf.gam()
		if g.size() == wf.nz and wf.nz > 0:
			# устойчивость, в которую растёт облако: над верхом слоя перемешивания (или над LCL)
			var z := base if is_nan(wf.z_i()) else maxf(base, wf.z_i())
			var k := clampi(int(floor((z - wf.z_bot) / wf.dz)), 0, wf.nz - 1)
			return maxf(g[k], 0.0)
	if weather.has("stability_n_per_s"):
		var nbv := float(weather.stability_n_per_s)
		return nbv * nbv * THETA0 / G
	return 0.0058
