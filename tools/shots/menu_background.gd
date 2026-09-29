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
var _cam: Camera3D = null
var _target: Node3D = null
var _heading_rad := 0.0
var _locked := false


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
	if _cfg.has("clock_hour"):
		# только освещение: атмосфера (облака) остаётся как есть
		game.sky.clock.set_hour(float(_cfg.clock_hour))
	var t_end := float(_cfg.get("sim_time_s", 5.0))
	while game.sim_time_s < t_end and main.state == main.State.FLYING:
		await get_tree().physics_frame
	game.overlay.visible = false
	# сим замирает на sim_time_s: число физических шагов за прогрев не зависит от частоты кадров
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = true
	_cam = game.camera
	_target = _cam.target
	_cam.process_mode = Node.PROCESS_MODE_DISABLED
	_locked = true
	_place_camera()
	# прогрев: облака, трава, шейдеры, тени — как в обычном кадре
	var warm := int(_cfg.get("warmup_frames", 30))
	for i in warm:
		_place_camera()
		await RenderingServer.frame_post_draw
	_place_camera()
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var q := float(_cfg.get("jpeg_quality", 0.91))
	var err := (
		img.save_jpg(_out, q) if _out.get_extension().to_lower() in ["jpg", "jpeg"] else img.save_png(_out)
	)
	print("menu_background: %s %dx%d (%s), sim t=%.2f с" % [_out, img.get_width(), img.get_height(), error_string(err), game.sim_time_s])
	print("menu_background: планер %s, курс %.1f°, камера %s" % [_target.global_position, rad_to_deg(_heading_rad), _cam.global_position])
	get_tree().quit(0 if err == OK else 1)


## Камера: смещение в осях курса планера (курс — только рыскание, без крена/тангажа).
func _place_camera() -> void:
	var c: Dictionary = _cfg.camera
	var fwd := -_target.global_transform.basis.z
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
	var basis_now := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, deg_to_rad(float(c.pitch_deg)))
	_cam.global_transform = Transform3D(basis_now, pos)
	_cam.fov = float(c.fov_deg)
