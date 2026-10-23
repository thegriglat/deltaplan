class_name SnowPlume
extends Node3D
## Снежные флаги в игре (SNW-К4 v2, docs/contracts/snow-plume.md): модель (SNW-2) + отрисовка (SNW-3)
## у Terrain. Ветер — air.mean_wind_at, температура — temp_fn(высота_м), снег — SnowCover.
## В headless и при enabled == false не создаётся.

var terrain: Terrain
var model: SnowPlumeModel
var render: SnowPlumeRender
var _air: Node
var _temp_fn: Callable


## Поставить (или обновить) узел под terrain. null — headless, выключено или у воздуха нет mean_wind_at.
## Повторный attach (новое место) пересоздаёт модель под новый рельеф.
static func attach(t: Terrain, air: Node, temp_fn: Callable) -> SnowPlume:
	if DisplayServer.get_name() == "headless" or t == null:
		return null
	var cfg: Dictionary = Config.get_config("snow_plume")
	if not bool(cfg.get("enabled", false)) or air == null or not air.has_method("mean_wind_at"):
		return null
	var n := t.get_node_or_null("SnowPlume") as SnowPlume
	if n == null:
		n = SnowPlume.new()
		n.name = "SnowPlume"
		n.terrain = t
		t.add_child(n)
	n.setup(t, air, temp_fn, cfg)
	return n


## Собрать модель и отрисовку заново (рельеф сменился).
func setup(t: Terrain, air: Node, temp_fn: Callable, cfg: Dictionary) -> void:
	terrain = t
	_air = air
	_temp_fn = temp_fn
	if render != null:
		render.queue_free()
	render = SnowPlumeRender.new(cfg.get("render", {}))
	add_child(render)
	model = make_model(t, air, temp_fn, cfg.get("model", {}))


## Модель под рельеф t: высота — t.height_at, снег — SnowCover, ветер — air.mean_wind_at.
static func make_model(t: Terrain, air: Node, temp_fn: Callable, cfg: Dictionary) -> SnowPlumeModel:
	return SnowPlumeModel.new(
		cfg, t.height_at, func(x: float, z: float) -> float: return SnowCover.snow_fraction(t, x, z),
		Callable(air, "mean_wind_at"), temp_fn
	)


func _process(delta: float) -> void:
	if model == null or render == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	render.set_emitters(model.update(cam.global_position, delta))
