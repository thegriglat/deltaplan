extends Node3D
## Стенд приборов: синтетическая телеметрия (кружение в термике с синусом вариометра),
## прибор на 3D-корпусе, картинка в углу, звук вариометра, крупный экран слева.
## Клавиши: 1–5 — страница, Tab — следующая, ↑/↓ — вариометр вручную ±1 м/с, 0 — снова синус.
## Аргументы (после --): --screenshot=путь.png  --page=N
##   --warmup_s=С (прогнать телеметрию до кадра)
##   --quit_after_s=С  --skips_report (печатать пропуски звука)
##   --screenshot также сохраняет *_screen.png (планшет) и *_vario90s.png (вариометр 90-х)
##   --race (синтетическое состояние соревнования для страниц 3–4)
##   --pages_prefix=путь (сохранить экран всех страниц в путь_p1.png … путь_p5.png).
## Параметры синусоиды — не конфиг прибора, а сценарий стенда (только для предпросмотра).

const SCENARIO := {
	"vario_mean_ms": 0.8,
	"vario_amp_ms": 3.2,
	"vario_period_s": 16.0,
	"airspeed_kmh": 36.0,
	"turn_period_s": 22.0,
	"wind_ms": Vector2(2.0, -1.0),
	"start_alt_m": 1850.0,
	"ground_m": 1100.0,
	"glide_leg_s": 60.0,
	"core_offset_m": Vector2(20.0, 30.0),
	"core_lift_ms": 3.5,
	"core_radius_m": 60.0,
}

var t := Telemetry.new()
var _time := 0.0
var _manual := NAN
var _core := Vector2.ZERO
var _core_set := false
var _args := {}
var _elapsed := 0.0
var _shot_done := false
var _skips_at_1s := -1

@onready var instrument3d: Instrument3D = $Instrument3D
@onready var overlay: InstrumentOverlay = $InstrumentOverlay
@onready var audio: VarioAudio = $VarioAudio
@onready var big_view: TextureRect = $UI/BigView
@onready var vario90s: VarioDisplay90s = $VarioDisplay90s
@onready var vario90s_view: TextureRect = $UI/Vario90sView


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	# Один прибор на всё: оверлей и крупный вид показывают экран 3D-корпуса.
	overlay.use_instrument(instrument3d.instrument)
	big_view.texture = instrument3d.instrument.get_texture()
	vario90s_view.texture = vario90s.get_texture()
	var tps: Array = [
		{"name": "ТП1 Чуй", "position": Vector3(2500, 1150, -1800), "radius_m": 400.0},
		{"name": "ТП2 Белый", "position": Vector3(-1500, 1300, -4000), "radius_m": 1000.0},
		{"name": "Гоул", "position": Vector3(-6000, 1000, -9000), "radius_m": 400.0},
	]
	instrument3d.instrument.set_task(tps, 0)
	if _args.has("race"):
		# Синтетическое состояние TaskTracker: идёт гонка, первый пункт взят.
		instrument3d.instrument.set_task(tps, 1)
		var race := {
			"phase": "racing",
			"instrument_active": 1,
			"next_name": "ТП2 Белый",
			"remaining_distance_m": 9800.0,
			"required_glide": 11.2,
			"elapsed_s": 1834.0,
		}
		instrument3d.instrument.set_task_state(race)
	instrument3d.instrument.set_sound_settings(audio.get_settings())
	t.position = Vector3(0, SCENARIO.start_alt_m, 0)
	t.on_ground = false
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var warm := float(_args.get("warmup_s", "0"))
	var steps := int(warm / dt)
	for i in steps:
		_step(dt)
	if _args.has("page"):
		instrument3d.set_page(int(_args.page))


func _physics_process(delta: float) -> void:
	_step(delta)


func _step(dt: float) -> void:
	_time += dt
	var v: float
	if not is_nan(_manual):
		v = _manual
	elif _time < SCENARIO.glide_leg_s:
		v = (
			SCENARIO.vario_mean_ms
			+ SCENARIO.vario_amp_ms * sin(TAU * _time / SCENARIO.vario_period_s)
		)
	else:
		# Кружение: термик сносится ветром, ядро смещено от центра круга (для страницы 5).
		if not _core_set:
			_core_set = true
			_core = Vector2(t.position.x, t.position.z) + SCENARIO.core_offset_m
		var core: Vector2 = _core + SCENARIO.wind_ms * (_time - SCENARIO.glide_leg_s)
		var d2 := Vector2(t.position.x, t.position.z).distance_squared_to(core)
		v = SCENARIO.core_lift_ms * exp(-d2 / pow(SCENARIO.core_radius_m, 2.0)) - 0.5
	# Первую минуту — прямой полёт от старта (для следа), дальше кружение.
	var hdg: float
	if _time < SCENARIO.glide_leg_s:
		hdg = 40.0
	else:
		hdg = fposmod(40.0 + 360.0 * (_time - SCENARIO.glide_leg_s) / SCENARIO.turn_period_s, 360.0)
	var air_h := Units.kmh(SCENARIO.airspeed_kmh)
	var a := deg_to_rad(hdg)
	var air := Vector2(sin(a), -cos(a)) * air_h
	var ground: Vector2 = air + SCENARIO.wind_ms
	t.time_s = _time
	t.vario = v
	t.position += Vector3(ground.x, v, ground.y) * dt
	t.velocity = Vector3(ground.x, v, ground.y)
	t.airspeed = air_h
	t.groundspeed = ground.length()
	t.altitude_msl = t.position.y
	t.altitude_agl = t.position.y - SCENARIO.ground_m
	t.heading_deg = hdg
	t.track_deg = fposmod(rad_to_deg(atan2(ground.x, -ground.y)), 360.0)
	t.bank_deg = 0.0 if _time < SCENARIO.glide_leg_s else 30.0
	instrument3d.update(t, dt)
	vario90s.update(t, dt)
	audio.set_vario(instrument3d.instrument.get_vario().vario_ms)


func _process(delta: float) -> void:
	_elapsed += delta
	instrument3d.rotation.y = 0.25 * sin(_elapsed * 0.4)
	if _args.has("screenshot") and not _shot_done and _elapsed > 0.6:
		_shot_done = true
		await RenderingServer.frame_post_draw
		var path: String = _args.screenshot
		get_viewport().get_texture().get_image().save_png(path)
		instrument3d.instrument.get_texture().get_image().save_png(
			path.get_basename() + "_screen.png"
		)
		vario90s.get_texture().get_image().save_png(path.get_basename() + "_vario90s.png")
		print("скриншот: ", path)
	if _args.has("pages_prefix") and not _shot_done and _elapsed > 0.6:
		_shot_done = true
		var fi := instrument3d.instrument
		for i in fi.page_count():
			fi.set_page(i)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var out := "%s_p%d.png" % [String(_args.pages_prefix), i + 1]
			fi.get_texture().get_image().save_png(out)
			print("страница ", i + 1, ": ", out)
	if _skips_at_1s < 0 and _elapsed >= 1.0:
		_skips_at_1s = audio.get_skips()
	var q := float(_args.get("quit_after_s", "0"))
	if q > 0.0 and _elapsed >= q:
		if _args.has("skips_report"):
			print(
				"пропуски звука (skips) после 1-й секунды: ",
				audio.get_skips() - _skips_at_1s,
				" (всего ",
				audio.get_skips(),
				") за ",
				_elapsed,
				" с, кадров/с ≈ ",
				Engine.get_frames_per_second()
			)
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				instrument3d.instrument.next_page()
			KEY_0:
				_manual = NAN
			KEY_UP:
				_manual = (0.0 if is_nan(_manual) else _manual) + 1.0
			KEY_DOWN:
				_manual = (0.0 if is_nan(_manual) else _manual) - 1.0
			_:
				if event.keycode >= KEY_1 and event.keycode <= KEY_5:
					instrument3d.set_page(event.keycode - KEY_1)
