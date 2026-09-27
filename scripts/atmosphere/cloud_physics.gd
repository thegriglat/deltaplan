class_name CloudPhysics
extends RefCounted
## Облака в физике (FR-14b): облачный подсос и поток внутри облака, «в облаке ли точка».
##
## Под крупным растущим/зрелым кучевым подъём у основания УСИЛИВАЕТСЯ: выше уровня конденсации
## воздух получает скрытое тепло, его плавучесть растёт, и сходимость потока под облаком тянет
## воздух к основанию («cloud suck»). В облаке восходящий поток сохраняется почти до верхушки.
## Под мелкими, молодыми и распадающимися облаками подсоса нет — подъём у кромки слабеет.
## Сила подсоса — от размера и стадии облака (CloudModel), параметры — thermal.suck_* в конфиге.
## Форма облака для «в облаке ли» — упрощённая (купол с плоским основанием), дешёвая.

## Меньше этого подсоса нет (иначе крошечный подсос отменяет спад подъёма у кромки).
const _MIN_K := 0.02

## Модель облаков (общая с CloudLayer): стадии и размеры.
var model: CloudModel = CloudModel.new()

var _boost: float = 0.6
var _size_min: float = 700.0
var _size_full: float = 1600.0
var _in_cloud_frac: float = 0.8
var _cell: float = 2000.0
## Облака рядом: [cx, cz, кромка, мощность, rx, rz, плотность, ax.x, ax.z] по сетке.
var _grid: Dictionary = {}
var _count: int = 0
## Ниже самой низкой кромки и выше самой высокой верхушки облаков нет — быстрый отсев.
var _y_min: float = 1.0e9
var _y_max: float = -1.0e9


func setup(clouds_cfg: Dictionary, thermal_cfg: Dictionary, size_factor: float) -> void:
	model.setup(clouds_cfg, size_factor)
	_boost = float(thermal_cfg.suck_boost)
	_size_min = float(thermal_cfg.suck_size_m[0])
	_size_full = float(thermal_cfg.suck_size_m[1])
	_in_cloud_frac = float(thermal_cfg.in_cloud_frac)
	_cell = float(clouds_cfg.width_max_m)


## Подсос термика в момент t: Vector2(усиление подъёма у основания 0.., высота потока в облаке, м).
func suck(th: AtmoThermal, t: float) -> Vector2:
	var st := model.stage(th, t)
	if st.x < 0.0:
		return Vector2(th.suck, 0.0)
	var sz := model.size(th, st)
	var diam := 2.0 * minf(sz.x, sz.y)
	# Растущее и зрелое, пока термик жив; не молодое, не распадающееся, не мелкое.
	var k := smoothstep(_size_min, _size_full, diam) * smoothstep(0.3, 0.8, st.x)
	k *= 1.0 - smoothstep(0.0, 0.35, st.y)
	k *= st.z
	if k < _MIN_K:
		return Vector2(th.suck, 0.0)
	return Vector2(_boost * k + th.suck, sz.z * _in_cloud_frac * k)


## Пересобрать облака рядом с фокусом (раз в refresh).
func refresh(thermals: Dictionary, t: float, focus: Vector3, radius: float) -> void:
	_grid.clear()
	_count = 0
	_y_min = 1.0e9
	_y_max = -1.0e9
	var r2 := radius * radius
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		var st := model.stage(th, t)
		if st.x < 0.0:
			continue
		var c := model.center(th, t)
		if Vector2(focus.x, focus.z).distance_squared_to(c) > r2:
			continue
		var sz := model.size(th, st)
		var dens := st.x * (1.0 - st.y * st.y)
		var ax := th.drift_vel.normalized() if th.drift_vel.length_squared() > 1.0e-6 else Vector2(1, 0)
		var rec := PackedFloat32Array([c.x, c.y, th.top, sz.z, sz.x, sz.y, dens, ax.x, ax.y])
		var rmax := maxf(sz.x, sz.y)
		_y_min = minf(_y_min, th.top)
		_y_max = maxf(_y_max, th.top + sz.z)
		for gz in range(floori((c.y - rmax) / _cell), floori((c.y + rmax) / _cell) + 1):
			for gx in range(floori((c.x - rmax) / _cell), floori((c.x + rmax) / _cell) + 1):
				var key := Vector2i(gx, gz)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(rec)
		_count += 1


func cloud_count() -> int:
	return _count


## Плотность облака в точке 0..1 (0 — ясно). Упрощённый купол: для «белой мглы» у камеры
## и оценки «пилот в облаке». Дёшево: только облака своей клетки сетки.
func density_at(pos: Vector3) -> float:
	return sample(pos).x


## Vector3(плотность 0..1, направление к краю облака x, z) — в облаке поток «выкидывает» к краю.
func sample(pos: Vector3) -> Vector3:
	if pos.y < _y_min or pos.y > _y_max:
		return Vector3.ZERO
	var arr: Variant = _grid.get(Vector2i(floori(pos.x / _cell), floori(pos.z / _cell)))
	if arr == null:
		return Vector3.ZERO
	var best := Vector3.ZERO
	for rec: PackedFloat32Array in arr:
		var hn := (pos.y - rec[2]) / rec[3]
		if hn < 0.0 or hn > 1.0:
			continue
		var dx := pos.x - rec[0]
		var dz := pos.z - rec[1]
		var u := (dx * rec[7] + dz * rec[8]) / rec[4]
		var v := (-dx * rec[8] + dz * rec[7]) / rec[5]
		var q := 1.0 - Vector2(sqrt(u * u + v * v) / 0.85, hn).length()
		if q > 0.0:
			var d := smoothstep(0.0, 0.15, q) * rec[6]
			if d > best.x:
				var r := sqrt(dx * dx + dz * dz)
				best = Vector3(d, dx / r, dz / r) if r > 1.0 else Vector3(d, 1.0, 0.0)
	return best
