class_name AirZiTerrain
extends RefCounted
## Верх слоя перемешивания по столбцам (CLF-К6, docs/contracts/cloud-field.md): z_i частично следует
## рельефу — один на всю модель воздуха (случай, фазы, w*, термики, облака).
##
##   z_i(x) = z_i_ref + α·(h̃(x) − h_ref),  z_i(x) ≥ h(x) + ZI_MIN
##
## z_i_ref — верх слоя дня над долиной (AirPlace.day: частица от уровня долины ctx.valley_msl_m против
## профиля θ̄), h_ref — та же высота долины; h̃ — рельеф, сглаженный гауссом с σ = L (zi_terrain_smooth_m):
## над узкими гребнями и ущельями слой не успевает подстроиться (горизонтальное перемешивание и
## адвекция за время роста слоя), над широкими — следует рельефу с убавленной долей α
## (De Wekker & Kossmann 2015, Front. Earth Sci. 3:77, «Convective boundary layer heights over
## mountainous terrain — a review of concepts»: наблюдения над хребтами Альп, Скалистых гор, Шварцвальда
## — верх слоя «следует рельефу в приглушённом виде», доля порядка ⅓; идеализированные расчёты De Wekker
## 2008 — сглаживание рельефа на масштабе ≈ 5–10 км). Числа — configs/atmosphere.json → air_model
## (zi_terrain_alpha, zi_terrain_smooth_m) с _doc. α = 0 — столбцы ≡ z_i_ref (поведение до правки, без
## нижней границы: её, как и раньше, кладут потребители через max(z_i − hc, ZI_MIN)).
##
## Уровни: область 400 м считает столбцы от своего рельефа (columns); окна клипмапа берут z_i области
## билинейно в центрах своих столбцов (from_parent) — одна формула от одного h̃, окно = регион в точке
## с точностью до интерполяции и до нижней границы по своему (более подробному) рельефу.

## Мин. толщина слоя перемешивания над рельефом, м — как AirThermals.ZI_MIN / WindField.ZI_MIN.
const ZI_MIN := 300.0


## Параметры из конфига: {alpha, smooth_m}. Нет конфига — α = 0 (как до правки).
static func params() -> Dictionary:
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	return {
		alpha = float(ac.get("zi_terrain_alpha", 0.0)),
		smooth_m = float(ac.get("zi_terrain_smooth_m", 5000.0)),
	}


## z_i по столбцам сетки ny·nx (м над морем, float32) от рельефа hc (м над морем, блочное среднее).
## z_i_ref = NAN → пусто (нет конвекции). α = 0 → все столбцы = z_i_ref.
static func columns(
	hc: PackedFloat64Array,
	nx: int,
	ny: int,
	dx: float,
	z_i_ref: float,
	h_ref: float,
	alpha: float,
	smooth_m: float,
	zi_min := ZI_MIN
) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if is_nan(z_i_ref) or hc.size() != nx * ny or nx * ny == 0:
		return out
	out.resize(nx * ny)
	if alpha == 0.0:
		out.fill(z_i_ref)
		return out
	var hs := AirCase.gauss2d(hc, nx, ny, smooth_m / dx)
	for c in nx * ny:
		out[c] = maxf(z_i_ref + alpha * (hs[c] - h_ref), hc[c] + zi_min)
	return out


## z_i по столбцам сетки окна (x0, y0, dx, nx × ny в осях решателя) от уровня-родителя: билинейно
## по его столбцам в центрах клеток окна; при α > 0 у родителя — не ниже hc + zi_min по своему рельефу.
## У родителя нет столбцов — по его скаляру z_i (пусто, если и его нет).
static func from_parent(
	parent: WindField,
	hc: PackedFloat64Array,
	nx: int,
	ny: int,
	dx: float,
	x0: float,
	y0: float,
	zi_min := ZI_MIN
) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if parent == null or hc.size() != nx * ny or nx * ny == 0:
		return out
	var zic := parent.z_i_col()
	if zic.is_empty():
		var zi := parent.z_i()
		if is_nan(zi):
			return out
		out.resize(nx * ny)
		out.fill(zi)
		return out
	var floor_on := parent.zi_alpha() > 0.0
	out.resize(nx * ny)
	for j in ny:
		var y := y0 + (j + 0.5) * dx
		for i in nx:
			var x := x0 + (i + 0.5) * dx
			var c := j * nx + i
			var v := parent.z_i_at(Vector3(x, 0.0, -y))
			out[c] = maxf(v, hc[c] + zi_min) if floor_on else v
	return out
