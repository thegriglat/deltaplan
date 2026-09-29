class_name EggGloria
extends EasterEgg
## Глория (брокенский призрак): цветные кольца вокруг антисолнечной точки на верхней кромке
## облака, когда облако под наблюдателем, а солнце за спиной. Геометрия честная: направление
## a = −to_sun от камеры; луч по a входит в облако на расстоянии d; кольцо стоит там, лицом к
## камере, угловой размер постоянен. Локальная по смыслу (К4): от камеры.
## Рисуется квадратом на экране (CanvasLayer под интерфейсом, умножение на кадр), а не мешем:
## облака рисует компоситор после прозрачных мешей и стирает всё, что нарисовано до него.

const SHADER := preload("res://scripts/world_objects/easter_eggs/gloria.gdshader")

var _cfg: Dictionary = {}
var _dist := NAN
var _next_check := 0.0
var _fade := 0.0
var _last_t := NAN
var _shown_dist := NAN
var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial


## Точка наблюдения: камера, а без неё (тесты) — положение игрока.
static func _origin(ctx: EggContext) -> Vector3:
	if ctx.camera != null and ctx.camera.is_inside_tree():
		return ctx.camera.global_position
	return ctx.pilot_pos


## Расстояние до входа луча в облако по антисолнечному направлению, м; NAN — условия нет.
static func find_entry(ctx: EggContext, cfg: Dictionary) -> float:
	var min_alt := deg_to_rad(float(cfg.get("min_sun_alt_deg", 1.0)))
	if ctx.to_sun.y < sin(min_alt):
		return NAN
	var thr := float(cfg.get("density_threshold", 0.3))
	var o := _origin(ctx)
	if float(ctx.cloud_density_at.call(o)) > thr:
		return NAN
	var a := -ctx.to_sun.normalized()
	var step := float(cfg.get("probe_step_m", 50.0))
	var d := float(cfg.get("min_range_m", 60.0))
	var far := float(cfg.get("max_range_m", 2500.0))
	while d <= far:
		if float(ctx.cloud_density_at.call(o + a * d)) > thr:
			return d
		d += step
	return NAN


static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	return not is_nan(find_entry(ctx, cfg))


func begin(ctx: EggContext, cfg: Dictionary, _rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter(&"red_r", float(cfg.get("red_ring_deg", 2.5)) / _outer_deg())
	_mat.set_shader_parameter(&"opacity", 0.0)
	_layer = CanvasLayer.new()
	_layer.layer = -1  # над 3D-кадром, под интерфейсом
	_rect = ColorRect.new()
	_rect.material = _mat
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.visible = false
	_layer.add_child(_rect)
	add_child(_layer)
	_dist = find_entry(ctx, cfg)
	_shown_dist = _dist
	_next_check = ctx.t + float(cfg.get("check_s", 0.5))


func _outer_deg() -> float:
	return float(_cfg.get("outer_deg", 5.0))


func update(ctx: EggContext) -> bool:
	if lifetime_s > 0.0 and ctx.t - t0 > lifetime_s:
		return false
	var check_s := float(_cfg.get("check_s", 0.5))
	var dt := 0.0 if is_nan(_last_t) else clampf(ctx.t - _last_t, 0.0, 1.0)
	_last_t = ctx.t
	if ctx.t >= _next_check:
		_next_check = ctx.t + check_s
		_dist = find_entry(ctx, _cfg)
		if not is_nan(_dist):
			_shown_dist = _dist
	elif is_nan(_shown_dist) and not is_nan(_dist):
		_shown_dist = _dist
	var have := not is_nan(_dist)
	var fade_s := maxf(float(_cfg.get("fade_s", 0.4)), 0.01)
	_fade = clampf(_fade + (1.0 if have else -1.0) * dt / fade_s, 0.0, 1.0)
	if not have and _fade <= 0.0 and ctx.t - t0 > 2.0 * check_s:
		return false  # условие пропало и кольцо погасло
	if is_nan(_shown_dist):
		return true
	var o := _origin(ctx)
	var a := -ctx.to_sun.normalized()
	var d := _shown_dist - maxf(float(_cfg.get("pull_m", 10.0)), _shown_dist * 0.01)
	position = o + a * d  # мировая точка кольца (для тестов и отладки)
	_place_on_screen(ctx, o, a)
	return true


## Квадрат на экране вокруг антисолнечной точки: угловой радиус постоянен, в пикселях —
## outer_deg по вертикальному полю зрения камеры.
func _place_on_screen(ctx: EggContext, o: Vector3, a: Vector3) -> void:
	var cam := ctx.camera
	if cam == null or not cam.is_inside_tree() or cam.is_position_behind(o + a * 100.0):
		_rect.visible = false
		return
	var vp := cam.get_viewport().get_visible_rect().size
	var px_per_tan := vp.y * 0.5 / tan(deg_to_rad(cam.fov) * 0.5)
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		px_per_tan = vp.x * 0.5 / tan(deg_to_rad(cam.fov) * 0.5)
	var r := tan(deg_to_rad(_outer_deg())) * px_per_tan
	var c := cam.unproject_position(o + a * 100.0)
	_rect.size = Vector2(r, r) * 2.0
	_rect.position = c - Vector2(r, r)
	_mat.set_shader_parameter(&"opacity", _fade * float(_cfg.get("strength", 1.0)))
	_rect.visible = _fade > 0.0
