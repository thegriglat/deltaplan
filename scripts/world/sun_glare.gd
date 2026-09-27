class_name SunGlare
extends CanvasLayer
## Ослепление солнцем, как у глаза, и каска пилота поверх кадра (sun_glare.gdshader).
## Параметры — configs/world.json → sun_glare (глаз), configs/helmet.json (каска).
##
## Ослепление: солнце у направления взгляда — засвет вокруг солнца и потемнение остального кадра;
## сила — sun_glare.strength × time.light.glare (вечером слабее), цвет — цвет солнца.
## Закрыто ли солнце:
##   рельеф — лучи на процессоре из глаза по диску с ореолом (центр + кольцо ray_ring лучей
##   на ray_radius_deg) через CameraRig.ground_fn; доля сглаживается во времени (привыкание
##   глаза, adapt_time_s);
##   облака — пока солнце в кадре, в шейдере по яркости пикселей диска (точный край
##   нарисованного облака); за краем кадра — те же лучи через Atmosphere.cloud_density_at
##   (упрощённый купол);
##   крыло (парус, трубы) — тоже по пикселям: доля светлых проб, каждая — максимум в крестике
##   probe_wire_px, поэтому тонкие тросы и стропы не закрывают и засвет на них не дёргается;
##   козырёк каски — в шейдере по положению солнца на экране.
##
## Каска (helmet.json → mode) — только в виде из кабины (CameraRig.mode == "cockpit"):
## "open" — кромка козырька, "visor"/"visor_dark" — ещё и стекло с бликами против солнца.
## Кромка задана долями кадра — при любом поле зрения стоит у края; углы засвета — от
## настоящего направления каждого пикселя (по fov камеры).
##
## Создаёт SkyEnvironment; направление и цвет солнца — SkyEnvironment._apply_sun → set_sun().
## Камера — текущая камера окна; облака — у её родителя свойство air (Game.air) или
## occlusion_fn, если задан.

const SHADER := preload("res://scripts/world/sun_glare.gdshader")
const HELMET_MODES := ["none", "open", "visor", "visor_dark"]

## Каска: "none" | "open" | "visor" | "visor_dark" (helmet.json → mode, --helmet=…).
var helmet_mode := "none"
## Луч из точки p по направлению dir: (p: Vector3, dir: Vector3) -> Vector2(рельеф 0/1,
## пропускание облаков 0..1).
## Не задан — рельеф по CameraRig.ground_fn и облака по air.cloud_density_at родителя камеры.
var occlusion_fn: Callable = Callable()
## Видимость солнца по лучам (сглаженная), 0..1 — для тестов и отладки: рельеф × облака.
var ray_visibility := 1.0
## То же по отдельности (сглаженные): не закрыто рельефом и пропускание облаков, 0..1.
var terrain_visibility := 1.0
var cloud_visibility := 1.0
## Первый кадр — без сглаживания (иначе на старте засвет «наплывает»).
var _fresh := true

var _rect: ColorRect
var _mat: ShaderMaterial
var _cfg: Dictionary = {}
var _to_sun := Vector3.UP
var _sun_color := Color.WHITE
var _time_k := 1.0
var _cmd_helmet := ""
var _cmd_checked := false


func _ready() -> void:
	if _rect == null:
		apply_config()
	if not Config.reloaded.is_connected(_on_config_reloaded):
		Config.reloaded.connect(_on_config_reloaded)


## Перечитать world.json → sun_glare и helmet.json.
func apply_config() -> void:
	_cfg = Config.get_config("world").get("sun_glare", {})
	layer = int(_cfg.get("layer", -1))
	if _rect == null:
		_rect = ColorRect.new()
		_rect.name = "Overlay"
		_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_rect.material = _mat
		add_child(_rect)
	if not _cmd_checked:
		_cmd_checked = true
		_cmd_helmet = LaunchOptions.parse(OS.get_cmdline_user_args()).helmet
	var h: Dictionary = Config.get_config("helmet")
	helmet_mode = _cmd_helmet if _cmd_helmet != "" else String(h.get("mode", "none"))
	if not HELMET_MODES.has(helmet_mode):
		helmet_mode = "none"
	var m := _mat
	m.set_shader_parameter("veil_core", float(_cfg.get("veil_core", 0.5)))
	m.set_shader_parameter("veil_core_deg", float(_cfg.get("veil_core_deg", 3.0)))
	m.set_shader_parameter("veil_wide", float(_cfg.get("veil_wide", 0.3)))
	m.set_shader_parameter("veil_wide_deg", float(_cfg.get("veil_wide_deg", 12.0)))
	m.set_shader_parameter("veil_flat", float(_cfg.get("veil_flat", 0.05)))
	var b: Dictionary = h.get("brim", {})
	m.set_shader_parameter("brim_height", float(b.get("height", 0.07)))
	m.set_shader_parameter("brim_curve", float(b.get("curve", 0.05)))
	m.set_shader_parameter("brim_softness", float(b.get("softness", 0.08)))
	m.set_shader_parameter("brim_opacity", float(b.get("opacity", 0.8)))
	m.set_shader_parameter("brim_color", _color(b.get("color", [0.03, 0.03, 0.03])))
	m.set_shader_parameter("side_width", float(b.get("side_width", 0.06)))
	m.set_shader_parameter("side_opacity", float(b.get("side_opacity", 0.3)))
	m.set_shader_parameter("brim_sun_block", float(b.get("sun_block", 0.9)))
	var v: Dictionary = h.get("visor", {})
	m.set_shader_parameter("distortion", float(v.get("distortion", 0.01)))
	m.set_shader_parameter("distortion_start", float(v.get("distortion_start", 0.35)))
	m.set_shader_parameter("edge_tint", float(v.get("edge_tint", 0.08)))
	m.set_shader_parameter("glass_veil", float(v.get("veil", 0.25)))
	m.set_shader_parameter("glass_veil_deg", float(v.get("veil_deg", 25.0)))
	m.set_shader_parameter("streaks", float(v.get("streaks", 0.5)))
	m.set_shader_parameter("streak_width", float(v.get("streak_width", 0.004)))
	m.set_shader_parameter("streak_length", float(v.get("streak_length", 0.35)))
	var sa: Array = v.get("streak_angles_deg", [20.0, 100.0])
	m.set_shader_parameter(
		"streak_angles",
		Vector2(deg_to_rad(float(sa[0])), deg_to_rad(float(sa[1] if sa.size() > 1 else sa[0])))
	)
	m.set_shader_parameter("scratches", float(v.get("scratches", 0.6)))
	m.set_shader_parameter("scratch_density", float(v.get("scratch_density", 7.0)))
	m.set_shader_parameter("dust", float(v.get("dust", 0.5)))
	m.set_shader_parameter("dust_density", float(v.get("dust_density", 26.0)))
	m.set_shader_parameter("lit_deg", float(v.get("lit_deg", 35.0)))


## Каска: "none" | "open" | "visor" | "visor_dark" (до следующего apply_config — из конфига,
## если не задана --helmet при запуске).
func set_helmet(mode: String) -> void:
	helmet_mode = mode if HELMET_MODES.has(mode) else "none"


## Направление НА солнце, цвет солнца и множитель ослепления по времени суток (time.light.glare).
func set_sun(to_sun: Vector3, color: Color, time_k: float) -> void:
	_to_sun = to_sun.normalized()
	_sun_color = color
	_time_k = time_k


## Каска, которую сейчас видно: только в кабине.
func active_helmet(cam: Camera3D) -> String:
	if cam == null or not (cam is CameraRig) or (cam as CameraRig).mode != "cockpit":
		return "none"
	return helmet_mode


func _on_config_reloaded() -> void:
	_cmd_helmet = ""  # пилот поменял настройку — она главнее параметра запуска
	apply_config()


func _process(dt: float) -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null or _mat == null:
		if _rect != null:
			_rect.visible = false
		return
	var helmet := active_helmet(cam)
	var sun_view := cam.global_basis.inverse() * _to_sun  # в осях камеры: −Z — вперёд
	var center_deg := rad_to_deg(acos(clampf(-sun_view.z, -1.0, 1.0)))
	# Ослепление заметно, пока солнце не дальше ~ поля зрения + засвета от центра взгляда.
	var near_view := center_deg < cam.fov + float(_cfg.get("veil_wide_deg", 12.0)) * 3.0
	var k := float(_cfg.get("strength", 1.0)) * _time_k
	if near_view and k > 0.0:
		_update_ray_visibility(cam, dt)
	else:
		_fresh = true
	var show_glare := near_view and k > 0.0 and terrain_visibility > 0.001
	_rect.visible = (show_glare or helmet != "none")
	if not _rect.visible:
		return
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	var tan_v := tan(deg_to_rad(cam.fov) * 0.5)
	var tan_half := Vector2(tan_v * aspect, tan_v)
	var sun_uv := Vector2(
		0.5 + 0.5 * (sun_view.x / maxf(-sun_view.z, 1e-3)) / tan_half.x,
		0.5 - 0.5 * (sun_view.y / maxf(-sun_view.z, 1e-3)) / tan_half.y
	)
	var hk := 1.0
	if helmet == "visor_dark":
		hk = float(Config.value("helmet", "visor.dark_glare", 0.55))
	var dark := (
		float(_cfg.get("darken", 0.4))
		* exp(-pow(center_deg / maxf(float(_cfg.get("darken_deg", 28.0)), 1e-3), 2.0))
	)
	var m := _mat
	m.set_shader_parameter("tan_half", tan_half)
	m.set_shader_parameter("aspect", aspect)
	m.set_shader_parameter("sun_view", sun_view)
	m.set_shader_parameter("sun_uv", sun_uv)
	m.set_shader_parameter("sun_vis", terrain_visibility)
	m.set_shader_parameter("cloud_vis", cloud_visibility)
	m.set_shader_parameter("on_screen", _on_screen(cam))
	var pr := tan(deg_to_rad(float(_cfg.get("probe_radius_deg", 0.6)))) * 0.5
	m.set_shader_parameter("probe_uv", Vector2(pr / tan_half.x, pr / tan_half.y))
	var wire := float(_cfg.get("probe_wire_px", 3.0))
	m.set_shader_parameter("probe_px", Vector2(wire / maxf(vp.x, 1.0), wire / maxf(vp.y, 1.0)))
	var vl: Array = _cfg.get("visible_luma", [0.45, 0.93])
	m.set_shader_parameter("visible_luma", Vector2(float(vl[0]), float(vl[1])))
	m.set_shader_parameter("glare", k * hk if show_glare else 0.0)
	m.set_shader_parameter("darken", dark)
	m.set_shader_parameter("sun_color", _sun_color)
	var tint := Color.WHITE
	if helmet == "visor":
		tint = _color(Config.value("helmet", "visor.tint", [1, 1, 1]))
	elif helmet == "visor_dark":
		tint = _color(Config.value("helmet", "visor.tint_dark", [0.5, 0.5, 0.5]))
	m.set_shader_parameter("helmet", HELMET_MODES.find(helmet))
	m.set_shader_parameter("visor_tint", tint)


## Можно ли пробовать пиксели диска: 1 — солнце в кадре, 0 — за краем (с полосой
## offscreen_margin у края) или позади.
func _on_screen(cam: Camera3D) -> float:
	var p := cam.global_position + _to_sun * 1000.0
	if cam.is_position_behind(p):
		return 0.0
	var vp := get_viewport().get_visible_rect().size
	var s := cam.unproject_position(p)
	var edge := minf(minf(s.x, vp.x - s.x), minf(s.y, vp.y - s.y)) / maxf(vp.y, 1.0)
	var margin := float(_cfg.get("offscreen_margin", 0.03))
	return clampf(edge / maxf(margin, 1e-4), 0.0, 1.0)


## Видимость солнца лучами из глаза (рельеф, облака), сглаженная как привыкание глаза.
func _update_ray_visibility(cam: Camera3D, dt: float) -> void:
	var want := sun_visibility(cam.global_position)
	var at: Array = _cfg.get("adapt_time_s", [0.25, 0.35])
	terrain_visibility = _adapt(terrain_visibility, want.x, at, dt)
	cloud_visibility = _adapt(cloud_visibility, want.y, at, dt)
	ray_visibility = terrain_visibility * cloud_visibility
	_fresh = false


func _adapt(cur: float, want: float, at: Array, dt: float) -> float:
	var tau := float(at[0]) if want > cur else float(at[1])
	return lerpf(cur, want, 1.0 if tau <= 0.0 or _fresh else 1.0 - exp(-dt / tau))


## Доля света солнца (диск с ореолом), дошедшая до точки p, среднее по лучам — центр и кольцо
## ray_ring лучей на угле ray_radius_deg: Vector2(не закрыто рельефом, пропускание облаков).
func sun_visibility(p: Vector3) -> Vector2:
	var fn := occlusion_fn
	if not fn.is_valid():
		var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
		var ground: Callable = cam.ground_fn if cam is CameraRig else Callable()
		var parent := cam.get_parent() if cam != null else null
		var air: Variant = parent.get("air") if parent != null else null
		var dens: Callable = Callable()
		if air is Object and is_instance_valid(air) and (air as Object).has_method("cloud_density_at"):
			dens = Callable(air, "cloud_density_at")
		fn = func(q: Vector3, dir: Vector3) -> Vector2: return trace_sun(q, dir, ground, dens, _cfg)
	var dirs := ray_directions(
		_to_sun, int(_cfg.get("ray_ring", 8)), float(_cfg.get("ray_radius_deg", 1.0))
	)
	var sum := Vector2.ZERO
	for d in dirs:
		sum += fn.call(p, d) as Vector2
	return sum / dirs.size()


## Центр и кольцо из n направлений на угле radius_deg вокруг to_sun (единичные векторы).
static func ray_directions(to_sun: Vector3, n: int, radius_deg: float) -> Array[Vector3]:
	var out: Array[Vector3] = [to_sun]
	var up := Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.RIGHT
	var a := to_sun.cross(up).normalized()
	var b := to_sun.cross(a)
	var r := tan(deg_to_rad(radius_deg))
	for i in n:
		var t := TAU * i / n
		out.append((to_sun + (a * cos(t) + b * sin(t)) * r).normalized())
	return out


## Луч от p вдоль to_sun (шаги гуще у начала): Vector2(рельеф: 0 — ground(x, z) выше луча,
## иначе 1; пропускание облаков e^(−Σ density(q)·cloud_opacity_per_m·шаг)). Тестируется headless.
static func trace_sun(
	p: Vector3, to_sun: Vector3, ground: Callable, density: Callable, cfg: Dictionary
) -> Vector2:
	var n := maxi(int(cfg.get("ray_steps", 24)), 1)
	var dist := float(cfg.get("ray_distance_m", 12000.0))
	var k := float(cfg.get("cloud_opacity_per_m", 0.004))
	var tau := 0.0
	var prev := 0.0
	for i in range(1, n + 1):
		var d := dist * pow(float(i) / n, 2.0)
		var q := p + to_sun * d
		if ground.is_valid() and float(ground.call(q.x, q.z)) > q.y:
			return Vector2(0.0, exp(-tau))
		if density.is_valid():
			tau += float(density.call(q)) * k * (d - prev)
		prev = d
	return Vector2(1.0, exp(-tau))


static func _color(a: Variant) -> Color:
	var arr: Array = a
	return Color(float(arr[0]), float(arr[1]), float(arr[2]))
