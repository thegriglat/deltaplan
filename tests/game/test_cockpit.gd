extends Node
## Приёмка кабины (docs/archive/plan/game/01-priemka-kabiny.md, VR-11, FR-25a, VR-6): что попадает в кадр
## кабинной камеры при разных поворотах головы. Кадр — 16:9 (1920×1080), как на скриншотах
## tools/shots/cockpit.sh; вид считается по геометрии (без рендера), поэтому тест идёт headless.
## Трапеция и парус — точки на рёбрах треугольников мешей, руки — кости рук скелета пилота.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const WINGS: Array[String] = ["training", "sport", "laminar"]
const ASPECT := 16.0 / 9.0
## Через сколько секунд полёта снимать (пилот лёг в кокон — поза prone).
## Поле зрения в приёмке A3.3, ° по вертикали.
const VIEW_FOV_DEG := 75.0
const MIN_AIR_S := 12.0
## Шаг выборки точек по рёбрам треугольников мешей, м (тросы тонкие и длинные: в угол кадра
## попадает кусок в десятки сантиметров).
const EDGE_STEP_M := 0.05

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Взгляд вперёд — только простор мира; вверх — парус; тень крыла включена.
func test_cockpit_view_by_head_angle() -> void:
	for wing in WINGS:
		var main := await _fly(wing)
		_use_eye_mode("eyes")  # проверки A3.3 — для камеры в глазах (вариант А)
		if main == null:
			continue
		var game: Game = main.get_node("Game")
		var v := game.glider.visual
		var cam := game.camera
		# Точки мешей — в мировых координатах, поэтому берутся заново после каждого поворота
		# головы (планер за это время пролетел вперёд). Вперёд — три момента через 1 с.
		for k in 3:
			_look(game, 0.0, 0.0)
			var frame := _meshes(v, ["ControlFrame", "Frame"])
			var sail := _meshes(v, ["Sail"])
			var instruments := _meshes(v, ["Body", "Screen"])
			var arms := _arm_points(v)
			check(
				not frame.is_empty() and not sail.is_empty(), "%s: есть Sail и ControlFrame" % wing
			)
			check(not arms.is_empty(), "%s: у пилота есть кости рук" % wing)
			var in_f := [
				_count_in_view(cam, frame),
				_count_in_view(cam, sail),
				_count_in_view(cam, arms),
				_count_in_view(cam, instruments)
			]
			if k == 0:
				print(
					(
						"         %s F: точек в кадре — трапеция %d, парус %d, руки %d, приборы %d"
						% ([wing] + in_f)
					)
				)
			check(in_f[1] == 0, "%s F: парус в кадре" % wing)
			check(in_f[2] == 0, "%s F: руки в кадре" % wing)
			check(in_f[3] == 0, "%s F: приборы в кадре" % wing)

		_look(game, 0.0, 55.0)
		check(_count_in_view(cam, _meshes(v, ["Sail"])) > 0, "%s U: парус в кадре" % wing)

		for g: GeometryInstance3D in v.find_children("*", "GeometryInstance3D", true, false):
			if g.name in ["Sail", "ControlFrame", "Frame", "PilotBody"]:
				check(
					g.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
					"%s: %s отбрасывает тень" % [wing, g.name]
				)
		await _finish(main)


## Первое лицо (A3.3 v5). Взгляд вперёд: трапеция позади глаз (числа — в печать). Взгляд вниз 85–90°: штанга и руки в кадре.
## Ленточки: при взгляде вверх-вперёд
## (наклон ≤ 55°) обе в кадре; углы от оси взгляда вперёд — в печать.
func test_trapezoid_and_telltales() -> void:
	for wing in ["apogee", "training", "sport", "laminar"]:
		var main := await _fly(wing)
		_use_eye_mode("eyes")  # проверки A3.3 — для камеры в глазах (вариант А)
		if main == null:
			continue
		var game: Game = main.get_node("Game")
		var v := game.glider.visual
		var cam := game.camera
		cam.fov = VIEW_FOV_DEG
		_look(game, 0.0, 0.0)
		print(
			(
				"         %s FOV %.0f вперёд: от оси, °: %s; ленточки %s"
				% [wing, VIEW_FOV_DEG, _bar_angles(v, cam), _telltale_angles(v, cam)]
			)
		)
		# взгляд вниз: штанга и руки в кадре
		_look(game, 0.0, -90.0)
		var bl := game.glider.get_marker("UprightBottomL").global_position
		var br := game.glider.get_marker("UprightBottomR").global_position
		var bar_in := 0
		for i in 41:
			if _in_view(cam, bl.lerp(br, i / 40.0)):
				bar_in += 1
		check(bar_in > 0, "%s: взгляд вниз 90° — штанга в кадре (%d из 41 точек)" % [wing, bar_in])
		check(_count_in_view(cam, _arm_points(v)) > 0, "%s: взгляд вниз 90° — руки в кадре" % wing)
		print("         %s: взгляд вниз 90°: штанга в кадре %d/41, угол до центра штанги %.1f°" % [wing, bar_in, _axis_angle(cam, game.glider.get_marker("BaseBar").global_position)])
		# ленточки: найти наклон головы вверх ≤ 55°, при котором обе в кадре
		var seen_pitch := -1.0
		for pit in [10.0, 20.0, 30.0, 40.0, 50.0, 55.0]:
			_look(game, 0.0, pit)
			var n := 0
			for t in v.telltales:
				if _in_view(cam, t.global_position):
					n += 1
			if n == 2:
				seen_pitch = pit
				break
		check(seen_pitch > 0.0, "%s: обе ленточки в кадре при взгляде вверх ≤ 55° (%.0f)" % [wing, seen_pitch])
		print("         %s: ленточки в кадре при наклоне головы вверх %.0f°" % [wing, seen_pitch])
		await _finish(main)


## A3.3 v8: камера в глазах без смещения, взгляд 10° вниз, FOV 90° (configs/camera.json). Для
## каждого крыла (взгляд прямо = по умолчанию): углы от оси до центра штанги и до ближайшей
## точки носовых тросов, видны ли они в кадре; затем наклон головы вниз (от горизонта), при
## котором центр штанги в кадре (≤ 90° — предел головы). Все числа — в печать (отчёт).
func test_bar_center_and_nose_cables_v8() -> void:
	var cc: Dictionary = Config.get_config("camera")
	check(float(cc.fov_deg) == 90.0, "fov_deg по умолчанию 90 (%s)" % cc.fov_deg)
	check(float(cc.cockpit.look_down_deg) == 10.0, "взгляд по умолчанию 10° вниз")
	var off: Array = cc.cockpit.offset_m
	check(float(off[0]) == 0.0 and float(off[1]) == 0.0 and float(off[2]) == 0.0, "cockpit.offset_m = 0")
	check(String(cc.cockpit.eye_mode) == "back_hands", "камера по умолчанию — сзади, видны руки (Б1)")
	for wing in ["apogee", "training", "sport", "laminar", "ww_sport3", "bautek_kite", "condor_crex3"]:
		var main := await _fly(wing)
		if main == null:
			continue
		var game: Game = main.get_node("Game")
		var v := game.glider.visual
		var cam := game.camera
		check(is_equal_approx(cam.fov, 90.0), "%s: FOV камеры 90" % wing)
		_look(game, 0.0, 0.0)
		var bar := game.glider.get_marker("BaseBar").global_position
		var a_bar := _axis_angle(cam, bar)
		var bar_in_now := _in_view(cam, bar)
		var cables := _nose_cable_points(v)
		var best := 180.0
		var n_in := 0
		for p in cables:
			best = minf(best, _axis_angle(cam, p))
			if _in_view(cam, p):
				n_in += 1
		var down_need := -1.0
		for d in range(0, 91, 1):
			_look_fast(game, -float(d))
			if _in_view(cam, game.glider.get_marker("BaseBar").global_position):
				down_need = 10.0 + d
				break
		print(
			(
				"         %s v8: взгляд прямо (10° вниз, FOV 90): центр штанги %.1f° от оси (%s), носовые тросы: ближайшая точка %.1f° от оси, в кадре %d из %d точек; "
				+ "центр штанги в кадре при наклоне головы вниз %.0f° от горизонта"
			)
			% [wing, a_bar, "в кадре" if bar_in_now else "вне кадра", best, n_in, cables.size(), down_need]
		)
		if wing in ["apogee", "training"]:
			check(bar_in_now, "%s: при взгляде по умолчанию центр штанги в кадре (%.1f° от оси)" % [wing, a_bar])
		check(down_need > 0.0 and down_need <= 90.0, "%s: центр штанги в кадре при наклоне головы ≤ 90° (%.0f)" % [wing, down_need])
		await _finish(main)


## Перебор камеры (A3.3 v8, запрос координатора): точка камеры (глаза / между плечами) × взгляд по
## умолчанию 0…20° вниз × FOV 75/90/100 → угол центра штанги от оси и виден ли он в кадре — на
## разбеге (анимация run) и в полёте лёжа (prone). Только печать (таблица в отчёт); горизонт
## впереди в кадре при L < FOV/2 (при всех этих сочетаниях).
func test_camera_sweep_v8() -> void:
	for wing in ["apogee", "training"]:
		var main: Node = MAIN_SCENE.instantiate()
		main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--autopilot", "--wing=" + wing])))
		add_child(main)
		var game: Game = main.get_node("Game")
		for i in 600:
			if main.get("state") == 2:
				break
			await get_tree().process_frame
		game.process_mode = Node.PROCESS_MODE_DISABLED
		game.camera.set_mode("cockpit")
		var done_run := false
		var air := 0.0
		for i in int(60.0 / DT):
			_step(game)
			var cur: String = game.get("_animator").current()
			if not done_run and cur == "run" and game.glider.phase() != "flying":
				for k in 120:
					_step(game)
				_sweep(game, wing, "разбег")
				done_run = true
			if game.glider.phase() == "flying":
				air += DT
			if air >= MIN_AIR_S and cur == "prone":
				break
		check(done_run, "%s: разбег пройден для перебора" % wing)
		_sweep(game, wing, "полёт")
		await _finish(main)


func _sweep(game: Game, wing: String, stage: String) -> void:
	var cam := game.camera
	var cc: Dictionary = Config.get_config("camera").cockpit
	var old_mode: String = cc.eye_mode
	var old_down: float = cc.look_down_deg
	for mode in ["eyes", "between_shoulders"]:
		for down in [0.0, 5.0, 10.0, 15.0, 20.0]:
			cc.eye_mode = mode
			cc.look_down_deg = down
			game.camera.set_look(0.0, 0.0)
			for i in 90:
				_step(game)
			var bar := game.glider.get_marker("BaseBar").global_position
			var ang := _axis_angle(cam, bar)
			var row := ""
			var old_fov := cam.fov
			for fov in [75.0, 90.0, 100.0]:
				cam.fov = fov
				row += " FOV %.0f: %s;" % [fov, "виден" if _in_view(cam, bar) else "нет"]
			cam.fov = old_fov
			print("         [перебор] %s %s камера=%s вниз %.0f°: центр штанги %.1f° от оси;%s" % [wing, stage, mode, down, ang, row])
	cc.eye_mode = old_mode
	cc.look_down_deg = old_down
	# камера назад от глаз (Б1/Б2): смещение (вверх, назад) × FOV → центр штанги, носовые тросы в кадре
	var old_off: Array = cc.offset_m
	cc.eye_mode = "eyes"
	cc.look_down_deg = 10.0
	for up in [0.0, 0.1]:
		for back in [0.2, 0.3, 0.4, 0.5, 0.6, 0.8]:
			cc.offset_m = [0.0, up, back]
			game.camera.set_look(0.0, 0.0)
			for i in 90:
				_step(game)
			var bar := game.glider.get_marker("BaseBar").global_position
			var cab := _nose_cable_points(game.glider.visual)
			var row := ""
			var old_fov := cam.fov
			for fov in [75.0, 90.0, 100.0]:
				cam.fov = fov
				var n := 0
				for p in cab:
					if _in_view(cam, p):
						n += 1
				row += " FOV %.0f: штанга %s, тросы %d%%;" % [fov, "да" if _in_view(cam, bar) else "нет", 100 * n / maxi(cab.size(), 1)]
			cam.fov = old_fov
			print("         [назад] %s %s вверх %.1f назад %.1f: центр штанги %.1f° от оси;%s" % [wing, stage, up, back, _axis_angle(cam, bar), row])
	cc.offset_m = old_off
	cc.eye_mode = old_mode
	cc.look_down_deg = old_down


## Точки носовых тросов: рёбра ControlFrame/Frame впереди нижних углов трапеции (вдоль курса) и выше них.
func _nose_cable_points(v: GliderVisual) -> PackedVector3Array:
	var bl := v.get_marker("UprightBottomL").global_position
	var br := v.get_marker("UprightBottomR").global_position
	var fwd := (v.global_transform.basis * Vector3.FORWARD).normalized()
	var base := (bl + br) * 0.5
	var out := PackedVector3Array()
	for p in _meshes(v, ["ControlFrame", "Frame"]):
		if (p - base).dot(fwd) > 0.15 and p.y > base.y + 0.05:
			out.append(p)
	return out


## Быстрая смена наклона головы (одна секунда симуляции вместо двух — только сглаживание головы).
func _look_fast(game: Game, pitch_deg: float) -> void:
	game.camera.set_look(0.0, pitch_deg)
	for i in 12:
		_step(game)


## Углы от оси взгляда камеры до ближайших точек стоек и штанги (по отрезкам маркеров), °.
func _bar_angles(v: Node3D, cam: Camera3D) -> Dictionary:
	var m := {}
	for k in ["UprightTopL", "UprightTopR", "UprightBottomL", "UprightBottomR"]:
		m[k] = v.get_marker(k).global_position
	return {
		"upL": snappedf(_seg_min_angle(cam, m.UprightTopL, m.UprightBottomL), 0.1),
		"upR": snappedf(_seg_min_angle(cam, m.UprightTopR, m.UprightBottomR), 0.1),
		"bar": snappedf(_seg_min_angle(cam, m.UprightBottomL, m.UprightBottomR), 0.1),
	}


func _telltale_angles(v: Node3D, cam: Camera3D) -> Array:
	var out := []
	for t in v.telltales:
		out.append(snappedf(_axis_angle(cam, t.global_position), 0.1))
	return out


func _axis_angle(cam: Camera3D, p: Vector3) -> float:
	var l := cam.global_transform.affine_inverse() * p
	return rad_to_deg(l.angle_to(Vector3(0, 0, -1)))


func _seg_min_angle(cam: Camera3D, a: Vector3, b: Vector3) -> float:
	var best := 180.0
	for i in 101:
		best = minf(best, _axis_angle(cam, a.lerp(b, i / 100.0)))
	return best


## Крен A→D→A: тело ездит под крылом, а голова — долей смещения со сглаживанием: планшет
## в кадре смещается плавно и не больше ~15 % ширины; без ввода — стоит на месте.
func test_tablet_steady_on_roll() -> void:
	var main := await _fly("training")
	if main == null:
		return
	var game: Game = main.get_node("Game")
	game.autopilot.release_all()
	game.autopilot = null
	game.camera.set_look(0.0, -80.0)  # взгляд вниз на приборы на штанге
	for i in 120:
		_step(game)
	var tablet := game.glider.get_marker("InstrumentMount")
	var xs := PackedFloat32Array()
	# Резкие перекладки: тело проходит весь ход вбок, крыло не успевает уйти в глубокий крен.
	for step in [["", 1.5], ["roll_left", 0.4], ["roll_right", 0.8], ["roll_left", 0.4], ["", 2.0]]:
		var action := String(step[0])
		if action != "":
			Input.action_press(action)
		for i in int(float(step[1]) / DT):
			_step(game)
			xs.append(_screen_x(game.camera, tablet.global_position))
		if action != "":
			Input.action_release(action)
	var calm := xs.slice(0, int(1.5 / DT))
	var x0 := calm[calm.size() - 1]
	var amp := 0.0
	var max_jump := 0.0
	for i in xs.size():
		amp = maxf(amp, absf(xs[i] - x0))
		if i > 0:
			max_jump = maxf(max_jump, absf(xs[i] - xs[i - 1]))
	print(
		(
			"         планшет по x кадра: без ввода %.3f, A→D→A амплитуда %.3f (размах %.3f), скачок %.4f"
			% [_span(calm), amp, _span(xs), max_jump]
		)
	)
	check(_span(calm) < 0.02, "без ввода планшет стоит (%.3f)" % _span(calm))
	check(amp <= 0.15, "амплитуда планшета при A→D→A ≤ 15 %% ширины (%.3f)" % amp)
	check(max_jump < 0.01, "планшет смещается плавно (скачок %.4f за шаг)" % max_jump)
	await _finish(main)


## A3.3 v9: планшет и вариометр — на нижней перекладине между хватами (маркер на оси штанги,
## 3 см допуск на изгиб PV3), руки на хватах линию взгляда не перекрывают. Углы — в печать:
## от оси взгляда по умолчанию и наклон головы вниз, при котором прибор в кадре (FOV по умолчанию
## и 75°) — в полёте и на разбеге. Наклон ≤ 90° (предел головы).
func test_instruments_on_bar() -> void:
	for wing in ["training", "sport", "laminar", "apogee"]:
		for stage in ["flight", "run"]:
			var main := await _fly(wing, stage == "run")
			if main == null:
				continue
			var game: Game = main.get_node("Game")
			var cam := game.camera
			var tablet := game.glider.get_marker("InstrumentMount")
			var vario := game.glider.get_marker("VarioMount")
			var cfg_fov := cam.fov
			for pair in [["планшет", tablet], ["вариометр", vario]]:
				var m: Node3D = pair[1]
				# позиции берём заново после каждого _look: планер за это время пролетел вперёд
				var gl := game.glider.get_marker("BarGripL").global_position
				var gr := game.glider.get_marker("BarGripR").global_position
				var bar := game.glider.get_marker("BaseBar").global_position
				var o := m.global_position
				var d := minf(_dist_seg(o, gl, bar), _dist_seg(o, bar, gr))
				var lx: float = (game.glider.global_basis.inverse() * (o - game.glider.global_position)).x
				check(d < 0.03, "%s %s: %s на оси штанги (%.3f м)" % [wing, stage, pair[0], d])
				check(absf(lx) < 0.29, "%s %s: %s между хватами (|x| %.2f)" % [wing, stage, pair[0], absf(lx)])
				_look(game, 0.0, 0.0)
				var a0 := _axis_angle(cam, m.global_position)
				var line := "         %s %s: %s %.1f° от оси по умолчанию;" % [wing, stage, pair[0], a0]
				for fov in [cfg_fov, VIEW_FOV_DEG]:
					cam.fov = fov
					var seen := -999.0
					for pit in range(0, 91, 5):
						_look(game, 0.0, -float(pit))
						if _in_view(cam, m.global_position):
							seen = float(pit)
							break
					if seen > -900.0:
						var clear := _min_dist_to_sight(cam.global_position, m.global_position, _arm_points(game.glider.visual))
						check(clear > 0.03, "%s %s: рука не перекрывает %s (%.3f м)" % [wing, stage, pair[0], clear])
						line += " FOV %.0f: в кадре при наклоне головы вниз %.0f° (просвет до руки %.2f м);" % [fov, seen, clear]
					else:
						line += " FOV %.0f: не в кадре до 90°;" % fov
				cam.fov = cfg_fov
				print(line)
			await _finish(main)


func _dist_seg(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return p.distance_to(a + ab * t)


# ---------------------------------------------------------------- помощники


## Главная сцена, автостарт с синтетическим пилотом, шаги вручную до позы prone в полёте.
func _fly(wing: String, on_run := false) -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	var args := PackedStringArray(["--autostart", "--wing=" + wing])
	if not on_run:
		args.append("--autopilot")
	main.set("opts", LaunchOptions.parse(args))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "%s: автостарт — в полёте" % wing)
	if main.get("state") != 2:
		await _finish(main)
		return null
	game.process_mode = Node.PROCESS_MODE_DISABLED  # шагаем сами
	game.camera.set_mode("cockpit")
	if on_run:
		game.autopilot = Autopilot.new()
	if on_run:  # разбег: ждём фазу running и 0,6 с бега (руки на стойках/штанге, пилот стоя)
		var run_t := 0.0
		for i in int(60.0 / DT):
			_step(game)
			if game.glider.phase() == "running":
				run_t += DT
			if run_t >= 0.6 or game.glider.phase() == "flying":
				break
		check(game.glider.phase() == "running", "%s: разбег — фаза running (%s)" % [wing, game.glider.phase()])
		return main
	var air := 0.0
	for i in int(60.0 / DT):
		_step(game)
		if game.glider.phase() == "flying":
			air += DT
		if air >= MIN_AIR_S and game.get("_animator").current() == "prone":
			break
	check(game.get("_animator").current() == "prone", "%s: пилот лёг (prone)" % wing)
	return main


## Шаг физики + кадр визуала, анимации пилота и камеры (Game выключен — зовём сами,
## по времени симуляции: так сглаживания тела и головы сравнимы).
func _step(game: Game) -> void:
	game.tick(DT)
	var ap: AnimationPlayer = game.get("_animator").player
	if ap != null:
		ap.advance(DT)
	for sk: Skeleton3D in game.glider.visual.find_children("*", "Skeleton3D", true, false):
		sk.force_update_all_bone_transforms()
	for ba: BoneAttachment3D in game.glider.visual.find_children(
		"*", "BoneAttachment3D", true, false
	):
		ba.on_skeleton_update()
	game.glider.call("_process", DT)
	game.camera.call("_process", DT)


## Повернуть голову и дать камере встать (сглаживание головы и крена).
func _look(game: Game, yaw_deg: float, pitch_deg: float) -> void:
	game.camera.set_look(yaw_deg, pitch_deg)
	for i in 120:
		_step(game)


## Точка в кадре 16:9 с вертикальным углом камеры.
func _in_view(cam: Camera3D, p: Vector3) -> bool:
	var l := cam.global_transform.affine_inverse() * p
	var d := -l.z
	if d < cam.near:
		return false
	var ty := tan(deg_to_rad(cam.fov) * 0.5)
	return absf(l.y) <= d * ty and absf(l.x) <= d * ty * ASPECT


func _count_in_view(cam: Camera3D, pts: PackedVector3Array) -> int:
	var n := 0
	for p in pts:
		if _in_view(cam, p):
			n += 1
	return n


## Положение точки по ширине кадра 16:9: 0 — центр, ±0,5 — края.
func _screen_x(cam: Camera3D, p: Vector3) -> float:
	var l := cam.global_transform.affine_inverse() * p
	var ty := tan(deg_to_rad(cam.fov) * 0.5)
	return l.x / (maxf(-l.z, 1e-3) * ty * ASPECT) * 0.5


func _span(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var lo := a[0]
	var hi := a[0]
	for x in a:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return hi - lo


## Точки на рёбрах треугольников мешей с данными именами (мировые координаты).
func _meshes(root: Node, names: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if not names.has(String(mi.name)) or mi.mesh == null:
			continue
		var xf := mi.global_transform
		var f := mi.mesh.get_faces()
		for i in range(0, f.size(), 3):
			for e in 3:
				var a := xf * f[i + e]
				var b := xf * f[i + (e + 1) % 3]
				var n := clampi(ceili(a.distance_to(b) / EDGE_STEP_M), 1, 400)
				for s in n:
					out.append(a.lerp(b, float(s) / n))
	return out


## Руки пилота: кости с «Arm»/«Hand» в имени и середины отрезков до родителя.
func _arm_points(root: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	for sk: Skeleton3D in root.find_children("*", "Skeleton3D", true, false):
		for b in sk.get_bone_count():
			var bn := sk.get_bone_name(b).to_lower()
			if not (bn.contains("arm") or bn.contains("hand")):
				continue
			var p := sk.global_transform * sk.get_bone_global_pose(b).origin
			out.append(p)
			var parent := sk.get_bone_parent(b)
			if parent >= 0:
				var q := sk.global_transform * sk.get_bone_global_pose(parent).origin
				for s in range(1, 4):
					out.append(q.lerp(p, s / 4.0))
	return out


## Поворот взгляда относительно курса планера, ° (+ влево).
func _glider_yaw_deg(game: Game) -> float:
	var l := game.glider.global_basis.inverse() * (-game.camera.global_basis.z)
	return rad_to_deg(atan2(-l.x, -l.z))


## Наклон взгляда относительно планера, ° (+ вверх).
func _glider_pitch_deg(game: Game) -> float:
	var l := game.glider.global_basis.inverse() * (-game.camera.global_basis.z)
	return rad_to_deg(asin(clampf(l.y, -1.0, 1.0)))


## Наименьшее расстояние от точек до отрезка глаз → цель (точки дальше цели не считаем).
func _min_dist_to_sight(eye: Vector3, target: Vector3, pts: PackedVector3Array) -> float:
	var best := 1e9
	var d := target - eye
	for p in pts:
		var t := clampf((p - eye).dot(d) / d.length_squared(), 0.0, 1.0)
		if t >= 1.0:
			continue
		best = minf(best, p.distance_to(eye + d * t))
	return best


func _use_eye_mode(mode: String) -> void:
	Config.get_config("camera").cockpit.eye_mode = mode


func _finish(main: Node) -> void:
	_use_eye_mode("back_hands")
	for a in ["roll_left", "roll_right"]:
		Input.action_release(a)
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
