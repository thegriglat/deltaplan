extends Node
## Приёмка кабины (docs/plan/game/01-priemka-kabiny.md, VR-11, FR-25a, VR-6): что попадает в кадр
## кабинной камеры при разных поворотах головы. Кадр — 16:9 (1920×1080), как на скриншотах
## tools/shots/cockpit.sh; вид считается по геометрии (без рендера), поэтому тест идёт headless.
## Трапеция и парус — точки на рёбрах треугольников мешей, руки — кости рук скелета пилота.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const WINGS: Array[String] = ["training", "sport", "kingpost"]
const ASPECT := 16.0 / 9.0
## Через сколько секунд полёта снимать (пилот лёг в кокон — поза prone).
const MIN_AIR_S := 12.0
## Шаг выборки точек по рёбрам треугольников мешей, м (тросы тонкие и длинные: в угол кадра
## попадает кусок в десятки сантиметров).
const EDGE_STEP_M := 0.05

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Взгляд вперёд — только простор мира; вниз — планшет; вверх — парус; тень крыла включена.
func test_cockpit_view_by_head_angle() -> void:
	for wing in WINGS:
		var main := await _fly(wing)
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
			check(in_f[0] == 0, "%s F: трапеция в кадре" % wing)
			check(in_f[1] == 0, "%s F: парус в кадре" % wing)
			check(in_f[2] == 0, "%s F: руки в кадре" % wing)
			check(in_f[3] == 0, "%s F: приборы в кадре" % wing)

		_look(game, 0.0, -60.0)
		var tablet := game.glider.get_marker("InstrumentMount")
		check(
			_in_view(cam, tablet.global_position), "%s DF: планшет (InstrumentMount) в кадре" % wing
		)
		# Вариометр 90-х — на штанге слева от планшета (карточка models/01): оба в кадре DF.
		var vario := game.glider.get_marker("VarioMount")
		if vario != null:
			check(_in_view(cam, vario.global_position), "%s DF: вариометр 90-х в кадре" % wing)

		_look(game, 0.0, 55.0)
		check(_count_in_view(cam, _meshes(v, ["Sail"])) > 0, "%s U: парус в кадре" % wing)

		for g: GeometryInstance3D in v.find_children("*", "GeometryInstance3D", true, false):
			if g.name in ["Sail", "ControlFrame", "Frame", "PilotBody"]:
				check(
					g.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
					"%s: %s отбрасывает тень" % [wing, g.name]
				)
		await _finish(main)


## Крен A→D→A: тело ездит под крылом, а голова — долей смещения со сглаживанием: планшет
## в кадре смещается плавно и не больше ~15 % ширины; без ввода — стоит на месте.
func test_tablet_steady_on_roll() -> void:
	var main := await _fly("training")
	if main == null:
		return
	var game: Game = main.get_node("Game")
	game.autopilot.release_all()
	game.autopilot = null
	_look(game, 0.0, -60.0)
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


# ---------------------------------------------------------------- помощники


## Главная сцена, автостарт с синтетическим пилотом, шаги вручную до позы prone в полёте.
func _fly(wing: String) -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	var args := PackedStringArray(["--autostart", "--autopilot", "--wing=" + wing])
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


func _finish(main: Node) -> void:
	for a in ["roll_left", "roll_right"]:
		Input.action_release(a)
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
