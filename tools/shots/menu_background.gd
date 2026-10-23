extends Node
## Фон главного меню (assets/ui/menu_background.jpg): кадр из самой игры — вечер над Онгудаем,
## дельтаплан в воздухе. Все параметры — tools/shots/menu_background.json (читает menu_background.sh:
## поле "flags" уходит в главную сцену как аргументы игры, остальное читает этот скрипт).
## Запуск — tools/shots/menu_background.sh [--size=3840x2160] [--out=файл.jpg].
## Скрипт: пресет графики и «Масштаб рендера» 100 % (до запуска мира) → главная сцена с флагами
## → ждёт полёта и sim_time_s → камера: смещение от планера в осях его курса (назад/вправо/вверх),
## рыскание/тангаж от курса, FOV → прогрев кадрами → JPEG.
## Аргументы (после «--»): --mb-config=<json> --mb-out=<файл>.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 240.0

var _cfg: Dictionary = {}
var _out := ""
var _main: Node = null
var _game: Game
var _cam: Camera3D = null
var _target: Node3D = null
var _heading_rad := 0.0
var _locked := false
var _pose_mode := "fixed"
var _rates := Vector3.ZERO  ## p, q, r, °/с


func _ready() -> void:
	var cfg_path := "res://tools/shots/menu_background.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mb-config="):
			cfg_path = a.substr(12)
		elif a.begins_with("--mb-out="):
			_out = a.substr(9)
	var txt := FileAccess.get_file_as_string(cfg_path)
	var parsed: Variant = JSON.parse_string(txt)
	if _out == "" or not parsed is Dictionary:
		push_error("menu_background: нужны --mb-out= и читаемый --mb-config= (%s)" % cfg_path)
		get_tree().quit(1)
		return
	_cfg = parsed
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("menu_background: FAIL (%s)" % why)
	get_tree().quit(1)


func _run() -> void:
	# Графика: максимальный пресет и 100 % без FSR — в временный профиль до старта мира.
	var gfx := String(_cfg.get("graphics", "high"))
	GraphicsPresets.select(gfx)
	UserSettings.save_patch("game", {"render_scale_auto": false, "render_scale_pct": 100.0})
	Config.reload()
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	# camera_rig после старта полёта: ждём FLYING и нужного времени симуляции
	for i in 6000:
		if main.state == main.State.FLYING and main.game.sim_time_s > 0.0:
			break
		await get_tree().process_frame
	if main.state != main.State.FLYING:
		_fail("полёт не начался")
		return
	var game: Game = main.game
	if _cfg.has("date"):
		# дата кадра (menu_art.py --date=MM-DD): солнце по дате и сезон scene-look; погода как есть
		var md: Array = _cfg.date
		game.sky.clock.month = int(md[0])
		game.sky.clock.day = int(md[1])
		game.terrain.set_flight_date(int(md[0]), int(md[1]))
	if _cfg.has("clock_hour"):
		# только освещение: атмосфера (облака) остаётся как есть
		game.sky.clock.set_hour(float(_cfg.clock_hour))
	elif _cfg.has("date"):
		game.sky.clock.set_hour(game.sky.clock.hour)
	var t_end := float(_cfg.get("sim_time_s", 5.0))
	while game.sim_time_s < t_end and main.state == main.State.FLYING:
		await get_tree().physics_frame
	game.overlay.visible = false
	_hide_texts(main)
	# сим замирает на sim_time_s: число физических шагов за прогрев не зависит от частоты кадров
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = true
	_cam = game.camera
	_game = game
	_target = _cam.target
	# камера по умолчанию — кабина: тело скрыто (видны только руки/ноги) и маска слоёв кабинная;
	# кадр снаружи — режим chase (маска) и тело целиком
	_cam.set_mode("chase")
	_game.glider.visual.set_cockpit_body("full")
	_game.overlay.visible = false  # смена режима камеры возвращает прибор (game._update_overlay)
	_cam.process_mode = Node.PROCESS_MODE_DISABLED
	_locked = true
	_apply_pose()
	_place_camera()
	# прогрев: облака, трава, шейдеры, тени — как в обычном кадре
	var warm := int(_cfg.get("warmup_frames", 30))
	for i in warm:
		_settle_pilot()
		_place_camera()
		await RenderingServer.frame_post_draw
	_settle_pilot()
	_place_camera()
	await RenderingServer.frame_post_draw
	print(_pose_line())
	var img := get_viewport().get_texture().get_image()
	var q := float(_cfg.get("jpeg_quality", 0.91))
	var err := (
		img.save_jpg(_out, q) if _out.get_extension().to_lower() in ["jpg", "jpeg"] else img.save_png(_out)
	)
	print("menu_background: %s %dx%d (%s), sim t=%.2f с" % [_out, img.get_width(), img.get_height(), error_string(err), game.sim_time_s])
	print("menu_background: планер %s, курс %.1f°, камера %s" % [_target.global_position, rad_to_deg(_heading_rad), _cam.global_position])
	get_tree().quit(0 if err == OK else 1)


## MSP-К1 v2: поза планера на кадре. fixed (по умолчанию) — крен bank_deg и тангаж pitch_deg (по умолчанию 0),
## курс текущий, пилот висит под подвеской, ω = 0; physics — как дала симуляция.
func _apply_pose() -> void:
	var pose: Dictionary = _cfg.get("pose", {})
	_pose_mode = String(pose.get("mode", "fixed"))
	var g: Glider = _game.glider
	var m: PendulumModel = g.model
	var w: Vector3 = m.get("_w")
	var r: Basis = m.get("_R")
	var wb := r.transposed() * w  # оси тела NED: x вперёд, y вправо, z вниз
	_rates = Vector3(rad_to_deg(wb.x), rad_to_deg(wb.y), rad_to_deg(wb.z))
	print(
		(
			"menu_background: диагностика скорость=%.1f м/с, сорвано=%s, курс модели=%.1f°, команда_крена=%.2f, вертикальная=%.1f м/с"
			% [m.telemetry.airspeed, m.stalled, rad_to_deg(m.heading), _ap_roll(), m.telemetry.vario]
		)
	)
	if _pose_mode != "fixed":
		return
	_rates = Vector3.ZERO
	var bank := float(pose.get("bank_deg", 0.0))
	var pitch := float(pose.get("pitch_deg", 0.0))
	# пилот в вертикали под подвеской (цепь ставит set_kinematic), крыло — в заданных крене и тангаже, курс текущий
	m.set_kinematic(m.position, Vector3.ZERO, m.heading, deg_to_rad(bank), deg_to_rad(pitch))
	FlightTelemetry.fill(m, g.air_fn, g.ground_fn)
	g._teleport()
	_settle_pilot()


## Пилот и парус в фиксированной позе: зовётся перед каждым кадром прогрева (сим на паузе, _process планера стоит).
func _ap_roll() -> float:
	return _game.autopilot.roll_command if _game.autopilot != null else 0.0


func _settle_pilot() -> void:
	if _pose_mode == "fixed":
		_game.glider._update_pilot(1.0 / 60.0)


## Строка позы MSP-К1 по фактической трансформации узла планера.
func _pose_line() -> String:
	var b: Basis = _game.glider.global_transform.basis
	var fwd := -b.z
	var pitch := rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0)))
	var cp := maxf(cos(deg_to_rad(pitch)), 1.0e-3)
	var bank := rad_to_deg(atan2(-b.x.y, b.y.y / cp))
	var hdg := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	return (
		"menu_background: поза режим=%s крен=%.1f тангаж=%.1f курс=%.1f p=%.1f q=%.1f r=%.1f"
		% [_pose_mode, bank, pitch, hdg, _rates.x, _rates.y, _rates.z]
	)


## Чистый кадр: без подписей в мире (имена ботов, вершины) и без интерфейса поверх.
## Сим на паузе — подписи и интерфейс не возвращаются сами.
func _hide_texts(node: Node) -> void:
	for ch in node.get_children():
		if ch is Label3D:
			ch.visible = false
		elif ch is CanvasLayer:
			ch.visible = false
		else:
			_hide_texts(ch)


## Камера: смещение в осях курса планера (курс — только рыскание, без крена/тангажа).
## camera.peak = [lat, lon] — оси не по курсу, а по направлению с планера на вершину (гора за планером).
func _place_camera() -> void:
	var c: Dictionary = _cfg.camera
	var fwd := -_target.global_transform.basis.z
	if c.has("peak"):
		var p: Vector2 = _game.terrain.latlon_to_local(float(c.peak[0]), float(c.peak[1]))
		fwd = Vector3(p.x, 0.0, p.y) - _target.global_position
	fwd.y = 0.0
	fwd = fwd.normalized()
	_heading_rad = atan2(-fwd.x, -fwd.z)
	var right := fwd.cross(Vector3.UP)
	var pivot: Vector3 = _target.global_position
	var pos := (
		pivot
		- fwd * float(c.back_m)
		+ right * float(c.right_m)
		+ Vector3.UP * float(c.up_m)
	)
	# рыскание > 0 — влево от курса (как в игре), тангаж > 0 — вверх
	var yaw := atan2(-fwd.x, -fwd.z) + deg_to_rad(float(c.yaw_deg))
	var pitch := deg_to_rad(float(c.pitch_deg))
	if bool(c.get("aim", false)):
		# aim: yaw/pitch — смещение от направления на планер (планер не по центру кадра)
		var to := pivot - pos
		yaw = atan2(-to.x, -to.z) + deg_to_rad(float(c.yaw_deg))
		pitch = atan2(to.y, Vector2(to.x, to.z).length()) + deg_to_rad(float(c.pitch_deg))
	var basis_now := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	_cam.global_transform = Transform3D(basis_now, pos)
	_cam.fov = float(c.fov_deg)
