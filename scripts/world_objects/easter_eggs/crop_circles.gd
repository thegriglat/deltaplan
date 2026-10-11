class_name EggCropCircles
extends EasterEgg
## Рисунки НЛО на полях (чисто картинка): на участке спелых колосьев изредка лежит геометрический узор из
## примятых колосьев — чуть светлее и серебристее поля, сверху ясно, с земли почти не читается.
## ИСКЛЮЧЕНИЕ из К4 (решение пользователя 11.10): розыгрыш заново на каждый полёт и к координатам не привязан
## (в сети у каждого свой). Внутри — собственный RandomNumberGenerator с зерном полёта (часы системы при begin),
## решение по участку — хэш(зерно полёта, участок) < p: в пределах полёта одно и то же. Глобальный генератор
## не используется (К3); rng планировщика не берётся.
## Пасхалка живёт до reset() (per_flight, lifetime_s 0) и лениво проверяет участки вокруг камеры: найденные
## в пределах visible_m получают меш по рельефу (сетка участка, узор — SDF в шейдере, клип по участку).
## Участки — FieldPlots (К10), только STANDING с запасом от порога; весь участок — класс CROP (центр и углы).

const SHADER := preload("res://scripts/world_objects/easter_eggs/crop_circles.gdshader")
const PATTERNS := 6

## Зерно полёта; ненулевое значение до begin() задаёт тест (иначе — часы системы).
var fixed_seed := 0
## Найденные рисунки для тестов: участок → {center, radius, rot, pattern}
var circles := {}

var _cfg: Dictionary = {}
var _seed := 0
var _flight_rng := RandomNumberGenerator.new()
var _plots: FieldPlots
var _scan_at := Vector2(1.0e9, 1.0e9)
var _rows: Array[int] = []
var _scan_origin := Vector2.ZERO
var _todo: Array[Vector2i] = []
var _items := {}  ## участок → MeshInstance3D
var _mat_base: ShaderMaterial


## Условия: день не нужен (рисунок виден и в сумерках); нужен мир с покровом (иначе поля не определить).
static func can_appear(_ctx: EggContext, _cfg: Dictionary) -> bool:
	return true


## Целочисленный хэш (зерно, участок, соль) → [0, 1).
static func lottery(seed_i: int, cell: Vector2i, salt := 0) -> float:
	var h := seed_i + salt * 0x2545F4914F6CDD1D
	h += cell.x * 0x632BE59BD9B4E019
	h = (h ^ ((h >> 30) & 0x3FFFFFFFF)) * 0x3F58476D1CE4E5B9
	h += cell.y * 0x27D4EB2F165667C5
	h = (h ^ ((h >> 27) & 0x1FFFFFFFFF)) * 0x14D049BB133111EB
	h ^= (h >> 31) & 0x1FFFFFFFF
	return float(h & 0xFFFFFF) / 16777216.0


## Годится ли участок: спелые колосья с запасом от порога, весь участок — CROP (центр и углы).
## place == null (тесты без мира) — только по тону.
static func plot_ok(plots: FieldPlots, place: EggPlace, cell: Vector2i, cfg: Dictionary) -> bool:
	if plots.tone(cell) >= float(cfg.get("standing_tone_max", 0.4)):
		return false
	if place == null:
		return true
	var r := plots.rect(cell)
	var pts: Array[Vector2] = [r.get_center(), r.position, r.end, Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.position.y)]
	for p in pts:
		if place.surface_at(p.x, p.y) != SurfaceLayer.CROP:
			return false
	return true


func begin(ctx: EggContext, cfg: Dictionary, _rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	_plots = FieldPlots.from_world_config()
	if fixed_seed != 0:
		_seed = fixed_seed
	else:
		_flight_rng.seed = Time.get_ticks_usec() ^ int(Time.get_unix_time_from_system() * 1000.0)
		_seed = _flight_rng.randi() | 1
	_mat_base = ShaderMaterial.new()
	_mat_base.shader = SHADER
	var fv := float(cfg.get("visible_m", 7000.0))
	_mat_base.set_shader_parameter("fade_start_m", fv * float(cfg.get("fade_start", 0.7)))
	_mat_base.set_shader_parameter("fade_end_m", fv)
	_mat_base.set_shader_parameter("strength", float(cfg.get("strength", 1.0)))
	var tn: Array = cfg.get("tint", [1.2, 1.22, 1.18])
	_mat_base.set_shader_parameter("tint", Vector3(float(tn[0]), float(tn[1]), float(tn[2])))
	var vs: Array = cfg.get("view_sin", [0.08, 0.5])
	_mat_base.set_shader_parameter("view_sin", Vector2(float(vs[0]), float(vs[1])))
	update(ctx)


func update(ctx: EggContext) -> bool:
	if _plots == null:
		return true
	var o := ctx.pilot_pos
	if ctx.camera != null and ctx.camera.is_inside_tree():
		o = ctx.camera.global_position
	var here := Vector2(o.x, o.z)
	if here.distance_to(_scan_at) >= float(_cfg.get("rescan_m", 400.0)):
		_scan_at = here
		_scan(ctx, here)
	_work(ctx)
	var vis := float(_cfg.get("visible_m", 7000.0))
	for cell in _items.keys():
		var mi: MeshInstance3D = _items[cell]
		var c: Dictionary = circles[cell]
		var far: bool = here.distance_to(c.center) > vis * 1.15
		if far:
			mi.queue_free()
			_items.erase(cell)
		else:
			mi.visible = here.distance_to(c.center) < vis + 400.0
	return true


## Новый обход участков вокруг точки: ряды ставятся в очередь и разбираются по _rows_per_update штук за кадр,
## найденные участки получают меш по одному за кадр (без рывка на одном кадре).
func _scan(_ctx: EggContext, at: Vector2) -> void:
	var vis := float(_cfg.get("visible_m", 7000.0))
	var sy := _plots.size_m.y
	_rows.clear()
	_scan_origin = at
	for iy in range(int(floorf((at.y - vis) / sy)), int(floorf((at.y + vis) / sy)) + 1):
		_rows.append(iy)


## Дообработать очередь целиком (тесты и первый кадр).
func settle(ctx: EggContext) -> void:
	while not _rows.is_empty() or not _todo.is_empty():
		_work(ctx)


func _work(ctx: EggContext) -> void:
	var vis := float(_cfg.get("visible_m", 7000.0))
	var p := float(_cfg.get("probability", 0.0015))
	var sx := _plots.size_m.x
	var at := _scan_origin
	var budget := int(_cfg.get("rows_per_update", 8))
	while budget > 0 and not _rows.is_empty():
		budget -= 1
		var iy: int = _rows.pop_back()
		var shift := floorf(float(iy) / FieldPlots.BAND_ROWS) * FieldPlots.ROW_SHIFT
		var ix0 := int(floorf((at.x - vis) / sx + shift)) - 1
		var ix1 := int(floorf((at.x + vis) / sx + shift)) + 1
		for ix in range(ix0, ix1 + 1):
			var cell := Vector2i(ix, iy)
			if lottery(_seed, cell) >= p:
				continue
			var r := _plots.rect(cell)
			if r.get_center().distance_to(at) > vis:
				continue
			if circles.has(cell):  # уже находили: меш мог быть убран, когда камера уехала
				if not _items.has(cell) and not _todo.has(cell):
					_todo.append(cell)
				continue
			if plot_ok(_plots, ctx.place, cell, _cfg):
				_make_info(cell, r)
				_todo.append(cell)
	if not _todo.is_empty():
		var cell: Vector2i = _todo.pop_front()
		_make_mesh(ctx, cell)


func _make_info(cell: Vector2i, r: Rect2) -> void:
	var rr := RandomNumberGenerator.new()  # свой, из зерна полёта и участка
	rr.seed = hash(Vector3i(_seed & 0x7FFFFFFF, cell.x, cell.y))
	var rad_rng: Array = _cfg.get("radius_m", [25.0, 100.0])
	var radius := rr.randf_range(float(rad_rng[0]), float(rad_rng[1]))
	var pat := rr.randi() % PATTERNS
	var rot := rr.randf() * TAU
	var c := r.get_center()
	var room := (r.size * 0.5 - Vector2(radius, radius)).max(Vector2.ZERO)  # центр так, чтобы узор вмещался
	c += Vector2(rr.randf_range(-1.0, 1.0) * room.x, rr.randf_range(-1.0, 1.0) * room.y)
	circles[cell] = {"center": c, "radius": radius, "rot": rot, "pattern": pat, "rect": r}


func _make_mesh(ctx: EggContext, cell: Vector2i) -> void:
	var ci: Dictionary = circles[cell]
	var r: Rect2 = ci.rect
	var c: Vector2 = ci.center
	var radius: float = ci.radius
	var rot: float = ci.rot
	var pat: int = ci.pattern
	var mi := MeshInstance3D.new()
	var mc := r.get_center()
	mi.position = Vector3(mc.x, 0.0, mc.y)
	mi.mesh = _grid_mesh(ctx, r, mc)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := _mat_base.duplicate() as ShaderMaterial
	m.set_shader_parameter("center", c)
	m.set_shader_parameter("radius", radius)
	m.set_shader_parameter("rot", rot)
	m.set_shader_parameter("pattern", pat)
	mi.material_override = m
	add_child(mi)
	_items[cell] = mi


## Сетка участка на рельефе; вершины относительно центра участка (y — абсолютная высота).
func _grid_mesh(ctx: EggContext, r: Rect2, mc: Vector2) -> ArrayMesh:
	var step := float(_cfg.get("mesh_step_m", 10.0))
	var nx := maxi(int(ceilf(r.size.x / step)), 1)
	var nz := maxi(int(ceilf(r.size.y / step)), 1)
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var lift := float(_cfg.get("lift_m", 0.15))
	for j in nz + 1:
		for i in nx + 1:
			var x := r.position.x + r.size.x * float(i) / float(nx)
			var z := r.position.y + r.size.y * float(j) / float(nz)
			verts.append(Vector3(x - mc.x, float(ctx.height_at.call(x, z)) + lift, z - mc.y))
	for j in nz:
		for i in nx:
			var a := j * (nx + 1) + i
			idx.append_array([a, a + 1, a + nx + 1, a + 1, a + nx + 2, a + nx + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
