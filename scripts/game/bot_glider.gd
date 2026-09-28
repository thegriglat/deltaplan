class_name BotGlider
extends Node3D
## Вид бота (BotPilots): та же модель крыла и пилота, что у игрока (GliderVisual — руки на
## трапеции, PilotAnimator — стоит, идёт, бежит, в кокон, выравнивание), парус своей расцветки
## (configs/bots.json → visual.sail_schemes), шаги на земле — объёмный звук. Дальше visual.full_m —
## упрощённая модель (треугольник крыла цвета паруса), дальше visual.hide_m — не видно.
## Над ботом — имя (NameTag, bots.json → names): постоянного размера на экране, гаснет вдали,
## за рельефом не видно (проверка глубины).
## Сам не считает физику: BotPilots шагает BotAgent и зовёт on_step(); между шагами бота
## (они реже шагов игрока) положение интерполируется.

const NAME_FONT := "res://assets/fonts/NotoSans-CondensedBold.ttf"

var agent: BotAgent
var visual: GliderVisual
var animator := PilotAnimator.new()
var impostor: MeshInstance3D
var steps: AudioStreamPlayer3D
var name_tag: Label3D
## Сейчас показана полная модель (false — дальняя или скрыт).
var full := true

var _cfg: Dictionary = {}
var _prev := Transform3D.IDENTITY
var _cur := Transform3D.IDENTITY
var _since := 0.0
var _step_dt := 1.0 / 30.0
var _step_timer := 0.0
var _streams: Array[AudioStream] = []
var _rng := RandomNumberGenerator.new()
var _run_cfg: Dictionary = {}
var _names: Dictionary = {}
var _hang_h := 2.0


## a — бот; vis_cfg — bots.json → visual.
func setup(a: BotAgent, vis_cfg: Dictionary) -> void:
	agent = a
	_cfg = vis_cfg
	_rng.seed = a.id * 7919 + 13
	var fv: Dictionary = Config.get_config("flight").visual
	var path := String(fv.get("scene", ""))
	var ps: PackedScene = load(path) if path != "" and ResourceLoader.exists(path) else null
	visual = ps.instantiate() as GliderVisual if ps != null else null
	if visual == null:
		visual = GliderVisual.new()
	visual.name = "Visual"
	add_child(visual)
	visual.build(a.model.wing, a.model.pilot, fv)
	_recolor()
	animator.bind(visual, Config.get_config("game").get("pilot_animation", {}))
	_hang_h = float(fv.get("hang_height_m", 2.0))
	_build_impostor(_hang_h)
	_build_steps()
	_build_name_tag()
	snap()


## Сразу на место (новый полёт, «Ещё раз»).
func snap() -> void:
	_cur = _xform()
	_prev = _cur
	_since = 0.0
	transform = _cur
	var t := agent.telemetry()
	animator.update(t.phase, t.altitude_agl, t.vario, agent.model.flare_amount(), 0.0)


## Бот сделал шаг физики длиной h.
func on_step(h: float) -> void:
	_prev = _cur
	_cur = _xform()
	_step_dt = maxf(h, 1.0e-3)
	_since = 0.0
	var t := agent.telemetry()
	if full:
		animator.update(t.phase, t.altitude_agl, t.vario, agent.model.flare_amount(), h)
	_update_steps(t, h)


## Прошёл шаг физики игрока dt (для интерполяции между шагами бота).
func advance(dt: float) -> void:
	_since += dt


func _process(dt: float) -> void:
	if agent == null:
		return
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var f := clampf(
		(_since + Engine.get_physics_interpolation_fraction() * tick) / _step_dt, 0.0, 1.0
	)
	transform = _prev.interpolate_with(_cur, f)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var d := cam.global_position.distance_to(global_position) if cam != null else 0.0
	var want_full := d < float(_cfg.get("full_m", 500.0))
	var shown := d < float(_cfg.get("hide_m", 7000.0))
	if want_full != full:
		full = want_full
		visual.process_mode = Node.PROCESS_MODE_INHERIT if full else Node.PROCESS_MODE_DISABLED
		if full:
			var t := agent.telemetry()
			animator.update(t.phase, t.altitude_agl, t.vario, agent.model.flare_amount(), 0.0)
	visual.visible = shown and full
	impostor.visible = shown and not full
	_update_name_tag(cam, d, shown)
	if not (shown and full):
		return
	var c := agent.control
	visual.set_pose(c.roll, c.pitch, agent.model.mode == FlightModel.Mode.AIR, dt)
	var full_g := float(Config.value("sail", "turbulence_full_g"))
	visual.set_flight(
		agent.telemetry().airspeed, agent.model.stall_amount(), agent.model.load.jitter / full_g
	)


## Вид имени (bots.json → names; BotPilots зовёт при перечитывании настроек).
func set_name_config(nc: Dictionary) -> void:
	_names = nc
	if name_tag == null:
		return
	var c: Array = nc.get("color", [1.0, 1.0, 1.0])
	name_tag.modulate = Color(float(c[0]), float(c[1]), float(c[2]))
	name_tag.outline_size = int(nc.get("outline_px", 6))
	if not bool(nc.get("show", true)):
		name_tag.visible = false


func _build_name_tag() -> void:
	name_tag = Label3D.new()
	name_tag.name = "NameTag"
	name_tag.top_level = true
	name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_tag.fixed_size = true
	name_tag.no_depth_test = false
	name_tag.shaded = false
	name_tag.double_sided = true
	# Непрозрачное (отсечка по альфе) — пишет глубину: иначе дымка и облака (haze, cloud_volume
	# — по буферу глубины) рисуются поверх имени, и его не видно.
	name_tag.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	name_tag.font_size = 48
	name_tag.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
	name_tag.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	name_tag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if ResourceLoader.exists(NAME_FONT):
		name_tag.font = load(NAME_FONT)
	name_tag.visible = false
	add_child(name_tag)
	set_name_config(Config.get_config("bots").get("names", {}))


## Имя: над ботом, размер на экране постоянный (с учётом поля зрения камеры), гаснет вдали
## (на земле — раньше).
func _update_name_tag(cam: Camera3D, d: float, shown: bool) -> void:
	if name_tag == null:
		return
	if cam == null or not shown or not bool(_names.get("show", true)) or agent.pilot_name == "":
		name_tag.visible = false
		return
	var end := float(_names.get("fade_end_m", 900.0))
	var start := float(_names.get("fade_start_m", 250.0))
	if agent.state != BotAgent.State.FLY:
		end = minf(end, float(_names.get("ground_fade_end_m", 120.0)))
		start = minf(start, end * 0.5)
	var a := 1.0 - smoothstep(start, end, d)
	if a <= 0.01:
		name_tag.visible = false
		return
	name_tag.visible = true
	if name_tag.text != agent.pilot_name:
		name_tag.text = agent.pilot_name
	var up := _hang_h + float(_names.get("height_m", 3.2))
	name_tag.global_position = global_position + Vector3.UP * up
	var frac := float(_names.get("font_px", 22.0)) / 1080.0
	name_tag.pixel_size = frac * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / float(name_tag.font_size)
	var k := float(_names.get("alpha", 0.85)) * a
	name_tag.modulate.a = k
	name_tag.outline_modulate.a = 0.8 * k


func _xform() -> Transform3D:
	var t := agent.telemetry()
	return Transform3D(t.basis, t.position)


## Парус в цвет схемы: поворот тона от основного цвета текстуры крыла к тону схемы.
func _recolor() -> void:
	var mat := visual.sail_material
	if mat == null or agent.scheme.is_empty():
		return
	var base := float(_cfg.get("wing_base_hue_deg", {}).get(agent.wing_id, 0.0))
	var hue := float(agent.scheme.get("hue_deg", base))
	mat.set_shader_parameter("hue_shift_rad", deg_to_rad(wrapf(hue - base, -180.0, 180.0)))
	mat.set_shader_parameter("sat_scale", float(agent.scheme.get("sat", 1.0)))
	mat.set_shader_parameter("value_scale", float(agent.scheme.get("value", 1.0)))


func scheme_color() -> Color:
	var s := agent.scheme
	return Color.from_hsv(
		fposmod(float(s.get("hue_deg", 0.0)), 360.0) / 360.0,
		0.85 * float(s.get("sat", 1.0)),
		0.9 * float(s.get("value", 1.0))
	)


## Дальняя модель: треугольник крыла (размах и хорда крыла) и пилот-палочка под ним.
func _build_impostor(hang_h: float) -> void:
	var wing := agent.model.wing
	var wv: Dictionary = wing.get("visual", {})
	var half := float(wing.get("span_m", 10.0)) * 0.5
	var chord := float(wv.get("root_chord_m", 2.6))
	var sweep := float(wv.get("sweep_m", 1.6))
	var y := hang_h + 0.25
	var nose := Vector3(0, y, -chord * 0.6)
	var tail := nose + Vector3(0, 0.05, chord)
	var tip_l := nose + Vector3(-half, 0.1, sweep)
	var tip_r := nose + Vector3(half, 0.1, sweep)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri: Array in [[nose, tip_r, tail], [nose, tail, tip_l]]:
		for p: Vector3 in tri:
			st.add_vertex(p)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = scheme_color()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.8
	st.set_material(mat)
	var mesh := st.commit()
	var body := BoxMesh.new()
	body.size = Vector3(0.45, 0.35, 1.8)
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.15, 0.15, 0.17)
	body.material = bm
	impostor = MeshInstance3D.new()
	impostor.name = "Impostor"
	impostor.mesh = mesh
	impostor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	impostor.visible = false
	add_child(impostor)
	var bi := MeshInstance3D.new()
	bi.mesh = body
	bi.position = Vector3(0, hang_h - 1.3, 0.3)
	bi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	impostor.add_child(bi)


## Шаги: объёмный звук у бота, темп — по скорости (как у игрока, audio.json → flight.run).
func _build_steps() -> void:
	var fa: Dictionary = Config.get_config("audio").get("flight", {})
	_run_cfg = fa.get("run", {})
	for p: String in _run_cfg.get("files", {}).get("steps_grass", []):
		if ResourceLoader.exists(p):
			_streams.append(load(p) as AudioStream)
	steps = AudioStreamPlayer3D.new()
	steps.name = "Steps"
	steps.bus = String(fa.get("buses", {}).get("effects", "Master"))
	if AudioServer.get_bus_index(steps.bus) < 0:
		steps.bus = "Master"
	steps.max_distance = float(_cfg.get("steps_max_distance_m", 120.0))
	steps.unit_size = 4.0
	steps.volume_db = float(_cfg.get("steps_db", -4.0))
	add_child(steps)


func _update_steps(t: Telemetry, h: float) -> void:
	var running := t.phase == "running"
	if _streams.is_empty() or not (running or t.phase == "walking") or t.groundspeed < 0.2:
		_step_timer = 0.0
		return
	var stride := float(_run_cfg.get("stride_run_m" if running else "stride_walk_m", 1.0))
	var interval := clampf(
		stride / t.groundspeed,
		float(_run_cfg.get("min_step_interval_s", 0.22)),
		float(_run_cfg.get("max_step_interval_s", 1.2))
	)
	_step_timer += h
	if _step_timer < interval:
		return
	_step_timer = fmod(_step_timer, interval)
	if not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_to(global_position) > steps.max_distance:
		return
	steps.stream = _streams[_rng.randi() % _streams.size()]
	steps.pitch_scale = 1.0 + _rng.randf_range(-0.05, 0.05)
	steps.volume_db = float(_cfg.get("steps_db", -4.0)) + (0.0 if running else -6.0)
	steps.play()
