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
var _job := {}  ## постройка меша порциями: {cell, j, verts}
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
	var tn: Array = cfg.get("tint", [1.4, 1.42, 1.36])
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
	_work(ctx, int(float(_cfg.get("budget_ms", 0.45)) * 1000.0))
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


## Новый обход участков вокруг точки: ряды ставятся в очередь и разбираются в бюджете budget_ms за кадр,
## меш участка строится порциями строк в том же бюджете.
func _scan(_ctx: EggContext, at: Vector2) -> void:
	var vis := float(_cfg.get("visible_m", 7000.0))
	var sy := _plots.size_m.y
	_rows.clear()
	_scan_origin = at
	for iy in range(int(floorf((at.y - vis) / sy)), int(floorf((at.y + vis) / sy)) + 1):
		_rows.append(iy)


## Дообработать очередь целиком (тесты и первый кадр).
func settle(ctx: EggContext) -> void:
	while not _rows.is_empty() or not _todo.is_empty() or not _job.is_empty():
		_work(ctx, 1 << 60)


func _work(ctx: EggContext, budget_us: int) -> void:
	var t_end := Time.get_ticks_usec() + budget_us
	var vis := float(_cfg.get("visible_m", 7000.0))
	var p := float(_cfg.get("probability", 0.0015))
	var sx := _plots.size_m.x
	var at := _scan_origin
	while not _rows.is_empty() and Time.get_ticks_usec() < t_end:
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
	while Time.get_ticks_usec() < t_end and (not _job.is_empty() or not _todo.is_empty()):
		if _job.is_empty():
			_start_mesh(_todo.pop_front())
		_step_mesh(ctx, t_end)


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


func _start_mesh(cell: Vector2i) -> void:
	var r: Rect2 = circles[cell].rect
	var step := float(_cfg.get("mesh_step_m", 10.0))
	_job = {
		"cell": cell,
		"j": 0,
		"nx": maxi(int(ceilf(r.size.x / step)), 1),
		"nz": maxi(int(ceilf(r.size.y / step)), 1),
		"verts": PackedVector3Array(),
	}


## Строки вершин сетки — пока есть время; в конце собрать меш и узел.
func _step_mesh(ctx: EggContext, t_end: int) -> void:
	var cell: Vector2i = _job.cell
	var r: Rect2 = circles[cell].rect
	var mc := r.get_center()
	var nx: int = _job.nx
	var nz: int = _job.nz
	var lift := float(_cfg.get("lift_m", 0.15))
	var verts: PackedVector3Array = _job.verts
	while _job.j <= nz and Time.get_ticks_usec() < t_end:
		var z := r.position.y + r.size.y * float(_job.j) / float(nz)
		for i in nx + 1:
			var x := r.position.x + r.size.x * float(i) / float(nx)
			verts.append(Vector3(x - mc.x, float(ctx.height_at.call(x, z)) + lift, z - mc.y))
		_job.j += 1
	_job.verts = verts
	if _job.j > nz:
		_finish_mesh(cell, verts, nx, nz)
		_job = {}


func _finish_mesh(cell: Vector2i, verts: PackedVector3Array, nx: int, nz: int) -> void:
	var ci: Dictionary = circles[cell]
	var r: Rect2 = ci.rect
	var mc := r.get_center()
	var mi := MeshInstance3D.new()
	mi.position = Vector3(mc.x, 0.0, mc.y)
	var idx := PackedInt32Array()
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
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := _mat_base.duplicate() as ShaderMaterial
	m.set_shader_parameter("center", ci.center)
	m.set_shader_parameter("radius", ci.radius)
	m.set_shader_parameter("rot", ci.rot)
	m.set_shader_parameter("pattern", ci.pattern)
	mi.material_override = m
	add_child(mi)
	_items[cell] = mi
