extends Node
## Кадры собаки у старта (DOG-3): покой у лагеря, разбег (срыв, бежит рядом, отрыв, лает у бровки,
## трусит назад) — из кабины и сбоку, и собака в движении по лагерю сверху. Игру не меняет.
## Запуск — tools/shots/start_dog_run.sh (окно нужно: настоящий рендер), аргументы после «--»:
##   --autostart --egg=start_dog:0 [--location=… --site=…] --out=<каталог>
## Пишет <out>/NN_<камера>_<момент>.jpg (JPEG q88). Моменты ловит по info() собаки и телеметрии
## бегущего, а не по секундам; ход времени мира замедлен (Engine.time_scale), чтобы успеть снять.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 900.0
const SLOW := 0.25  ## time_scale на разбеге
const SIDE_M := 15.0  ## боковая камера: расстояние от коридора, м
const SIDE_H := 2.2  ## и высота над землёй, м
const RUN_DIST: Array[float] = [14.0, 10.0, 7.0]  ## кадры «бежит рядом»: собака ближе к пилоту, м

var _out := ""
var _main: Node = null
var _game: Game
var _n := 0
var _cam_side: Camera3D
var _sx := 1.0  ## сторона боковой камеры: + вправо от курса старта
var _start := Vector3.ZERO
var _fwd := Vector3.FORWARD
var _right := Vector3.RIGHT
var _done := {}
var _tr_t := -1.0  ## диагностика: время мира и место собаки на прошлой строке трассы
var _tr_p := Vector2.ZERO
var _near_s := 0.0  ## собака у точки сбоку (≤ 4 м) на разбеге до отрыва, с


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if _out == "":
		push_error("start_dog_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("start_dog_shot: FAIL (%s)" % why)
	Engine.time_scale = 1.0
	await _quit(1)


func _quit(code: int) -> void:
	Engine.time_scale = 1.0
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


func _dog() -> EasterEgg:
	if _game.eggs == null:
		return null
	for e in _game.eggs.active():
		if e.id == "start_dog" and e.has_method("info"):
			return e
	return null


func _h(p: Vector3) -> Vector3:
	return Vector3(p.x, _game.terrain.height_at(p.x, p.z), p.z)


func _run() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	for i in 40000:
		if int(main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = main.get_node("Game")
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	_game.camera.set_mode("cockpit")
	var st: Dictionary = _game.get_start()
	_start = st.position
	_fwd = TerrainGeo.heading_vector(float(st.heading_deg))
	_right = Vector3(-_fwd.z, 0, _fwd.x)  # SC-K1: right = (cos h, sin h) по (x, z)
	_cam_side = Camera3D.new()
	add_child(_cam_side)
	SkyEnvironment.setup_camera(_cam_side)
	_cam_side.fov = 45.0
	# собаку ждём (ставит планировщик)
	for i in 600:
		if _dog() != null:
			break
		await get_tree().process_frame
	var dog := _dog()
	if dog == null or not bool(dog.call("has_dog")):
		_fail("собаки нет (лагеря у старта нет? другой --location/--site)")
		return
	var wo: WorldObjects = _game.world_link.objects as WorldObjects
	print("start_dog_shot: старт %s, палаток %d" % [_start, wo.camp.size() if wo != null else -1])
	await _phase_rest()
	await _phase_run()
	print("start_dog_shot: OK кадров %d" % _n)
	await _quit(0)


# ------------------------------------------------------------------ покой и вид сверху

func _phase_rest() -> void:
	var dog := _dog()
	# 1. собака до разбега (лежит/бродит у лагеря): из кабины с поворотом головы и сбоку
	await _cockpit_look("cockpit", "rest_до_разбега")
	_side_at_dog(8.0, 1.2)
	await _grab("side", "rest_до_разбега")
	# 2. ждём пробежки по лагерю (wander, speed > 2,5), ускорив время; не дольше ~3 мин —
	# иначе снимаем шаг (speed > 0,5)
	Engine.time_scale = 4.0
	var info: Dictionary = dog.call("info")
	var t_wait := Time.get_ticks_msec()
	var min_v := 2.5
	while not (info.state == "wander" and float(info.speed) > min_v):
		if min_v > 1.0 and Time.get_ticks_msec() - t_wait > 180000:
			print("start_dog_shot: WARN пробежки за 3 мин нет, снимаю шаг")
			min_v = 0.5
		if Time.get_ticks_msec() - t_wait > 300000:
			print("start_dog_shot: WARN wander не дождались, сверху снимаю как есть")
			break
		await get_tree().physics_frame
		info = dog.call("info")
	Engine.time_scale = 1.0
	for k in 3:
		info = dog.call("info")
		print("start_dog_shot: сверху #%d state=%s speed=%.1f anim=%s" % [k, info.state, info.speed, info.anim])
		var p: Vector3 = info.pos
		_cam_side.fov = 45.0
		_cam_side.look_at_from_position(_h(p) + Vector3(4, 30, 4), _h(p) + Vector3(0, 0, 0))
		_cam_side.current = true
		await _grab_cur("top", "wander_%s_%.1fмс" % [info.state, float(info.speed)])
		# и сбоку, с земли, пока бегает
		var dir := Vector3(sin(float(dog.get("_yaw"))), 0, cos(float(dog.get("_yaw"))))
		_cam_side.fov = 45.0
		if k == 1:
			_cam_side.look_at_from_position(_h(p) + Vector3(7, 1.4, 7), _h(p) + Vector3.UP * 0.4)
			await _grab_cur("side", "wander_%s" % info.state)
		for j in 90:
			await get_tree().physics_frame
		dir = dir


# ------------------------------------------------------------------ разбег

func _phase_run() -> void:
	var dog := _dog()
	_game.camera.snap()
	_game.autopilot = Autopilot.new()
	Engine.time_scale = SLOW
	var flown := false
	for i in 200000:
		await get_tree().physics_frame
		var info: Dictionary = dog.call("info")
		var tel := _game.glider.get_telemetry()
		var p: Vector3 = info.pos
		var dist := Vector2(tel.position.x - p.x, tel.position.z - p.z).length()
		var st := String(info.state)
		var sp := float(info.speed)
		var aim: Vector3 = info.aim
		var d_side := Vector2(aim.x - p.x, aim.z - p.z).length()
		if st == "chase" and tel.phase == "running":
			# время у своей точки сбоку (≤ 4 м) до отрыва, физ. секунды
			_near_s += get_physics_process_delta_time() if d_side <= 4.0 else 0.0
		if st == "chase" and i % 15 == 0:
			var vd: Vector2 = dog.get("_vel")
			var dp: Vector2 = dog.get("_pos")
			var rel := p - _start
			# диагностика: желаемая скорость перехвата, после обхода; путь собаки по времени мира
			var rv := Vector2(tel.velocity.x, tel.velocity.z)
			var amax := float((dog.get("_cfg") as Dictionary).get("accel_ms2", 8.0))
			var want: Vector2 = dog.call("_intercept", rv, amax)
			var av: Vector2 = dog.call("_avoid", want)
			var tw := float(dog.get("_last_t"))
			var v_real := 0.0
			if _tr_t > 0.0 and tw > _tr_t:
				v_real = dp.distance_to(_tr_p) / (tw - _tr_t)
			print("start_dog_shot: chase diag t=%.3f want=%.1f avoid=%.1f (av·vel %.2f) v_real=%.1f rv=(%.1f, %.1f) push=%.2f" % [
				tw, want.length(), av.length(), av.normalized().dot(vd.normalized()), v_real,
				Vector3(rv.x, 0, rv.y).dot(_fwd), Vector3(rv.x, 0, rv.y).dot(_right),
				(dog.call("_push_out", dp) as Vector2).distance_to(dp)])
			_tr_t = tw
			_tr_p = dp
			print(("start_dog_shot: chase trace phase=%s dog_v=%.1f (along %.1f) anim=%s scale=%.2f "
				+ "dist=%.1f to_side=%.1f pilot_v=%.1f pilot_along=%.1f dog_along=%.1f dog_lat=%.1f "
				+ "allowed=%.1f near_s=%.2f target=%d") % [
				tel.phase, sp, Vector3(vd.x, 0, vd.y).dot(_fwd), info.anim, info.anim_scale, dist, d_side,
				tel.groundspeed, (tel.position - _start).dot(_fwd), rel.dot(_fwd), rel.dot(_right),
				float(dog.call("_allowed_along", dp)), _near_s, int(info.target_id)])
		if st == "chase" and not _done.has("chase0") and sp > 0.5:
			await _both("срыв_chase", tel)
			_done["chase0"] = true
		elif st == "chase" and sp > 3.0 and tel.phase == "running" and int(_done.get("runs", 0)) < 3 \
				and (dist < RUN_DIST[int(_done.get("runs", 0))] or d_side <= 4.0):
			# бежит рядом: по мере сближения (дистанция до пилота ниже порога) или у своей точки сбоку
			_done["runs"] = int(_done.get("runs", 0)) + 1
			await _both("бежит_рядом_%d_%.0fмс_%.0fм" % [_done.runs, sp, dist], tel)
		if tel.phase == "flying" and not flown:
			flown = true
			print("start_dog_shot: отрыв: у точки сбоку ≤ 4 м %.2f с до отрыва, dist=%.1f to_side=%.1f" % [
				_near_s, dist, d_side])
		if flown and not _done.has("liftoff") and tel.altitude_agl > 0.8:
			await _both("отрыв", tel)
			_done["liftoff"] = true
		if st == "edge" and String(info.anim) == "bark" and not _done.has("edge"):
			_done["edge_t"] = _done.get("edge_t", 0) + 1
			if _done.edge_t > 20:
				await _both("лает_у_бровки", tel)
				_done["edge"] = true
		if st == "return" and sp > 1.5 and not _done.has("ret"):
			_done["ret_t"] = _done.get("ret_t", 0) + 1
			if _done.ret_t > 20:
				await _both("трусит_назад", tel)
				_done["ret"] = true
		if _done.has("ret") and not _done.has("ret2") and st == "return":
			_done["ret2t"] = _done.get("ret2t", 0) + 1
			if _done.ret2t > 120:
				await _both("трусит_назад_2", tel)
				_done["ret2"] = true
		if _done.has("ret") and (st != "return"):
			break
		if tel.phase in ["landed", "failed"] and i > 600:
			print("start_dog_shot: WARN пилот сел/сорвал раньше конца (state=%s)" % st)
			break
	Engine.time_scale = 1.0
	print("start_dog_shot: моменты: %s" % [_done.keys()])


# ------------------------------------------------------------------ камеры и кадры

func _both(moment: String, tel: Telemetry) -> void:
	var info: Dictionary = _dog().call("info")
	print("start_dog_shot: момент %s state=%s speed=%.1f anim=%s barks=%d phase=%s" % [
		moment, info.state, info.speed, info.anim, info.barks, tel.phase])
	await _cockpit_look("cockpit", moment)
	var p: Vector3 = info.pos
	var pil: Vector3 = tel.position
	var dog_far := Vector2(pil.x - p.x, pil.z - p.z).length() > 25.0
	if dog_far:
		# пилот улетел — камера за/сбоку от собаки, взгляд на собаку и пилота
		var eye := _h(p - _fwd * 6.0 + _right * _sx * 4.0) + Vector3.UP * 1.6
		_cam_side.look_at_from_position(eye, _h(p).lerp(pil, 0.12) + Vector3.UP * 1.0)
	else:
		var along := (pil - _start).dot(_fwd)
		var base := _h(_start + _fwd * along + _right * _sx * SIDE_M)
		var eye := base + Vector3.UP * SIDE_H
		_cam_side.look_at_from_position(eye, pil.lerp(_h(p) + Vector3.UP * 0.5, 0.5))
	_cam_side.fov = 55.0
	_cam_side.current = true
	await _grab_cur("side", moment)


## Камера пилота; голова повёрнута на собаку, если она не прямо впереди.
func _cockpit_look(cam: String, moment: String) -> void:
	var info: Dictionary = _dog().call("info")
	var tel := _game.glider.get_telemetry()
	var f := TerrainGeo.heading_vector(tel.heading_deg)
	var eye: Vector3 = _game.camera.global_position
	var d: Vector3 = (info.pos as Vector3) + Vector3.UP * 0.3 - eye
	var yaw := rad_to_deg(f.signed_angle_to(Vector3(d.x, 0, d.z), Vector3.UP))
	var hd := Vector2(d.x, d.z).length()
	var pitch := rad_to_deg(atan2(d.y, hd))
	var cfg: Dictionary = _game.camera.get("_cfg")
	var down := float(cfg.cockpit.get("look_down_deg", 0.0))
	yaw = clampf(yaw, -100.0, 100.0)
	_game.camera.set_look(yaw, pitch + down)
	_game.camera.current = true
	await _grab_cur(cam, moment + ("_взгляд_на_собаку_%.0f°" % yaw))
	_game.camera.snap()
	_game.camera.set_look(0.0, 0.0)
	await get_tree().process_frame
	await _grab_cur(cam, moment + "_взгляд_вперёд")
	_game.camera.snap()


func _side_at_dog(dist: float, h: float) -> void:
	var info: Dictionary = _dog().call("info")
	var p: Vector3 = info.pos
	_cam_side.fov = 45.0
	_cam_side.look_at_from_position(_h(p) + Vector3(dist, h, dist), _h(p) + Vector3.UP * 0.4)
	_cam_side.current = true


func _grab(cam: String, moment: String) -> void:
	await _grab_cur(cam, moment)


func _grab_cur(cam: String, moment: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	_n += 1
	var path := "%s/%02d_%s_%s.jpg" % [_out, _n, cam, moment]
	print("start_dog_shot: %s (%s)" % [path, error_string(img.save_jpg(path, 0.88))])
