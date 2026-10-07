extends Node
## Профиль кадра (PF-1, docs/perf/frame_profile.md). Не игровой код: инстанцирует scenes/main.tscn
## как probe.gd (--autostart --autopilot), на отметках симуляционного времени полёта ставит игру
## на паузу (кадр тот же, рисуется дальше) и по очереди меряет «опыты» — временные переключения
## рендера поверх пресета (тени, облака, деревья, масштаб 3D …), каждый раз возвращая всё назад.
## Код игры и конфиги не трогает: переключает свойства узлов и окна только в этом процессе.
##
##   godot --path . --audio-driver Dummy --disable-vsync --fullscreen --resolution 1920x1080 \
##     --gpu-profile res://tools/bench/frame_profile.tscn -- --location=ongudai --tag=medium \
##     --marks=2:cockpit,30:chase,60:chase --sample=2 --out=build/perf/x.jsonl \
##     [--exps=base,scale50,noshadow,...] [--air=60]
##   --gpu-profile   нужен для разбивки GPU по проходам (метки RenderingDevice движка)
##   --air=T         после отметок (без паузы): на сим.времени T запросить пересчёт поля воздуха
##                   (AirRuntime.request_recompute) и мерить кадры, пока он идёт (не дольше 40 с)
## Пишет по строке JSON на опыт в --out (кадр CPU/GPU средн. и 1%-худших, проходы GPU,
## мониторы Performance), печатает «PROFILE …» и «frame_profile: OK».

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 900.0
const WARMUP_S := 0.6
const AIR_MAX_S := 40.0

const ALL_EXPS := [
	"base", "scale50", "scale75", "nomsaa", "noshadow", "shadow1k", "noglow", "nocloudfx",
	"noclouds", "notrees", "notreeshadow", "noimpostors", "nograss", "noscatter", "noobjects",
	"nohaze", "noterrain", "cloudres33", "cloudres25", "cloudit64", "cloudlight3", "clouddetail0",
	"base2"
]
## Опыты облаков: [свойство эффекта или ключ params, значение].
const CLOUD_EXPS := {
	"cloudres33": ["resolution_scale", 0.33],
	"cloudres25": ["resolution_scale", 0.25],
	"cloudit64": ["max_iterations", 64],
	"cloudlight3": ["light_steps", 3],
	"clouddetail0": ["detail_enabled", 0],
}
## Кадр дольше этого — в журнал рывков (мс).
const HITCH_MS := 50.0

## Узлы по классу скрипта (Script.get_global_name) — для опытов «спрятать».
const HIDE_CLASSES := {
	"noclouds": ["CloudLayer", "CirrusLayer"],
	"notrees": ["TerrainTreeModels", "TerrainTrees", "ForestImpostors"],
	"noimpostors": ["ForestImpostors"],
	"nograss": ["GrassField"],
	"noscatter": ["ShrubScatter", "RockScatter"],
	"noterrain": ["TerrainRenderer"],
}

var _location := ""
var _tag := ""
var _sample_s := 2.0
var _marks: Array = []
var _exps: Array = ALL_EXPS.duplicate()
var _air_t := -1.0
var _pause := true
var _cpu_t := -1.0
var _keep: Array = []  # опыты, включённые на весь замер отметки (фон для остальных)
var _out_path := ""
var _main: Node
var _game: Node
var _restore: Array = []  # [[obj, prop, value], ...]
var _t_last := 0
var _hitches: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--location="):
			_location = a.substr(11)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--sample="):
			_sample_s = float(a.substr(9))
		elif a.begins_with("--out="):
			_out_path = a.substr(6)
		elif a.begins_with("--air="):
			_air_t = float(a.substr(6))
		elif a.begins_with("--keep="):
			_keep = Array(a.substr(7).split(","))
		elif a.begins_with("--cpu="):
			_cpu_t = float(a.substr(6))
		elif a.begins_with("--pause="):
			_pause = a.substr(8) != "0"
		elif a.begins_with("--exps="):
			_exps = Array(a.substr(7).split(","))
		elif a.begins_with("--marks="):
			for part in a.substr(8).split(","):
				var kv := part.split(":")
				if kv.size() == 2:
					_marks.append([float(kv[0]), kv[1]])
	if _location == "" or _out_path == "":
		push_error("frame_profile: нужны --location= и --out=")
		get_tree().quit(1)
		return
	get_tree().create_timer(TIMEOUT_S, true).timeout.connect(_fail.bind("таймаут"))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var args := PackedStringArray(["--autostart", "--autopilot", "--location=" + _location])
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	for i in 6000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING")
		return
	_game = _main.get_node("Game")
	_no_vsync()
	_print_env()

	for m in _marks:
		var t_mark: float = m[0]
		var cam: String = m[1]
		while _game.sim_time_s < t_mark and int(_main.get("state")) == 2:
			await get_tree().physics_frame
		if int(_main.get("state")) != 2:
			if _marks.size() == 1:
				_fail("сел раньше отметки %s" % t_mark)
				return
			print("PROFILE %s %s: сел раньше отметки %s — дальше без отметок" % [_location, _tag, t_mark])
			break
		_game.camera.set_mode(cam)
		_no_vsync()
		for i in 5:
			await get_tree().process_frame
		# полёт без паузы (настоящая нагрузка CPU: физика, боты, атмосфера)
		var fly := await _sample()
		fly.merge({loc = _location, tag = _tag, cam = cam, t = t_mark, exp = "fly"})
		_write(fly)
		print("PROFILE %s %s %s@%s fly: cpu %.2f ms (1%%: %.2f) gpu %.2f ms process %.2f physics %.2f" % [
			_location, _tag, cam, t_mark, fly.frame_ms, fly.frame_ms_1pct, fly.gpu_ms,
			fly.process_ms, fly.physics_ms
		])
		get_tree().paused = _pause
		for k in _keep:
			_apply(k)
		_restore.clear()  # фон не откатывается
		for e in _exps:
			if e == "none":
				continue
			_apply(e)
			await _wait(WARMUP_S)
			var row := await _sample()
			_undo()
			row.merge({loc = _location, tag = _tag + ("+" + "+".join(PackedStringArray(_keep)) if not _keep.is_empty() else ""),
				cam = cam, t = t_mark, exp = e})
			_write(row)
			print("PROFILE %s %s %s@%s %s: cpu %.2f ms (1%%: %.2f) gpu %.2f ms (1%%: %.2f) dc %d" % [
				_location, _tag, cam, t_mark, e, row.frame_ms, row.frame_ms_1pct, row.gpu_ms,
				row.gpu_ms_1pct, row.draw_calls
			])
		get_tree().paused = false

	if _air_t >= 0.0:
		await _air_run()
	if _cpu_t >= 0.0:
		await _micro_run()
		await _cpu_run()
	_write({loc = _location, tag = _tag, exp = "_hitches", hitches = _hitches,
		cloud_build_ms = CloudCompositorEffect.build_ms})
	print("PROFILE cloud_build_ms %s %s: %.0f" % [_location, _tag, CloudCompositorEffect.build_ms])
	print("PROFILE hitches %s %s: %s" % [_location, _tag, JSON.stringify(_hitches)])
	print("frame_profile: OK %s" % _location)
	await _quit(0)


## Игра ставит VSync и предел кадров из game.json → display (QL-13) поверх --disable-vsync —
## для замера снимаем оба.
func _no_vsync() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0


## Журнал рывков за весь прогон (кадр > HITCH_MS): сим.время, стадия AirRuntime.
func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _t_last > 0 and _game != null:
		var ms := (now - _t_last) / 1000.0
		if ms > HITCH_MS:
			var rt: Node = _game.get("air_runtime")
			_hitches.append({
				ms = snappedf(ms, 0.1), sim_t = snappedf(_game.sim_time_s, 0.01),
				paused = get_tree().paused,
				air_stage = int(rt.get("_stage")) if rt != null else -1,
			})
	_t_last = now


func _print_env() -> void:
	var vp := get_viewport()
	var env: Environment = vp.world_3d.environment if vp.world_3d else null
	var we := _find_class(_main, "WorldEnvironment")
	if we != null:
		env = (we as WorldEnvironment).environment
	var info := {
		adapter = RenderingServer.get_video_adapter_name(),
		driver = RenderingServer.get_video_adapter_api_version(),
		size = DisplayServer.window_get_size(),
		vsync = DisplayServer.window_get_vsync_mode(), max_fps = Engine.max_fps,
		scale_3d = vp.scaling_3d_scale, scaling_mode = vp.scaling_3d_mode, msaa_3d = vp.msaa_3d,
	}
	if env != null:
		info.merge({
			ssao = env.ssao_enabled, ssil = env.ssil_enabled, sdfgi = env.sdfgi_enabled,
			ssr = env.ssr_enabled, glow = env.glow_enabled, fog = env.fog_enabled,
			volumetric_fog = env.volumetric_fog_enabled, tonemap = env.tonemap_mode,
		})
	var sun := _find_class(_main, "DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		info.merge({
			shadow = sun.shadow_enabled, shadow_mode = sun.directional_shadow_mode,
			shadow_max_m = sun.directional_shadow_max_distance,
			splits = [sun.directional_shadow_split_1, sun.directional_shadow_split_2,
				sun.directional_shadow_split_3],
			shadow_blur = sun.shadow_blur,
		})
	print("PROFILE_ENV %s %s %s" % [_location, _tag, JSON.stringify(info)])
	_write({loc = _location, tag = _tag, exp = "_env", env = info})


# ------------------------------------------------------------------ опыты


func _ovr(obj: Object, prop: String, value: Variant) -> void:
	_restore.append([obj, prop, obj.get(prop)])
	obj.set(prop, value)


func _undo() -> void:
	for i in range(_restore.size() - 1, -1, -1):
		var r: Array = _restore[i]
		if r[0] is Dictionary:
			r[0][r[1]] = r[2]
		elif is_instance_valid(r[0]):
			(r[0] as Object).set(r[1], r[2])
	_restore.clear()


func _apply(e: String) -> void:
	var vp := get_viewport()
	match e:
		"scale50":
			_ovr(vp, "scaling_3d_scale", 0.5)
		"scale75":
			_ovr(vp, "scaling_3d_scale", 0.75)
		"nomsaa":
			_ovr(vp, "msaa_3d", Viewport.MSAA_DISABLED)
		"noshadow":
			for n in _all_of(_main, "DirectionalLight3D"):
				_ovr(n, "shadow_enabled", false)
		"shadow1k":
			# разрешение атласа направленных теней — глобально в RenderingServer (не откатывается
			# свойством: возвращаем вручную в _undo через запись ниже)
			RenderingServer.directional_shadow_atlas_set_size(1024, true)
			_restore.append([self, "_shadow_restore", 0])
		"noglow":
			for we in _all_of(_main, "WorldEnvironment"):
				_ovr((we as WorldEnvironment).environment, "glow_enabled", false)
		"nocloudfx":
			_cloud_fx_off()
		"noclouds":
			_cloud_fx_off()
			_hide_classes(HIDE_CLASSES[e])
		"notreeshadow":
			for n in _nodes_of_classes(_main, ["TerrainTreeModels", "TerrainTrees"]):
				for g in _geoms(n):
					_ovr(g, "cast_shadow", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		"noobjects":
			for n in _nodes_by_script_dir(_main, "res://scripts/world_objects/"):
				if n is Node3D:
					_ovr(n, "visible", false)
		"nohaze":
			for g in _all_of(_main, "GeometryInstance3D"):
				if _uses_shader(g as GeometryInstance3D, "haze"):
					_ovr(g, "visible", false)
		_:
			if CLOUD_EXPS.has(e):
				var kv: Array = CLOUD_EXPS[e]
				for fx in _cloud_effects():
					if kv[0] in fx:
						_ovr(fx, kv[0], kv[1])
					else:
						var d: Dictionary = fx.get("params")
						_restore.append([d, kv[0], d.get(kv[0])])
						d[kv[0]] = kv[1]
			elif HIDE_CLASSES.has(e):
				_hide_classes(HIDE_CLASSES[e])


## Сеттер-заглушка для отката shadow1k (см. _apply).
var _shadow_restore: int:
	set(_v):
		var sz := int(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/size", 4096
		))
		RenderingServer.directional_shadow_atlas_set_size(sz, true)
	get:
		return 0


func _cloud_effects() -> Array:
	var out := []
	for c in _all_of(_main, "Camera3D"):
		var comp: Compositor = (c as Camera3D).compositor
		if comp == null:
			continue
		for fx in comp.compositor_effects:
			if fx != null and fx.get_script() != null and fx.get("cloud_count") != null:
				out.append(fx)
	return out


func _cloud_fx_off() -> void:
	for c in _all_of(_main, "Camera3D"):
		var comp: Compositor = (c as Camera3D).compositor
		if comp == null:
			continue
		for fx in comp.compositor_effects:
			if fx != null:
				_ovr(fx, "enabled", false)


func _hide_classes(classes: Array) -> void:
	for n in _nodes_of_classes(_main, classes):
		if n is Node3D:
			_ovr(n, "visible", false)


func _uses_shader(g: GeometryInstance3D, sub: String) -> bool:
	var mats: Array = [g.material_override]
	if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
		var mi := g as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			mats.append(mi.get_active_material(s))
	for m in mats:
		if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
			if (m as ShaderMaterial).shader.resource_path.contains(sub):
				return true
	return false


func _geoms(n: Node) -> Array:
	var out := []
	if n is GeometryInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_geoms(c))
	return out


static func _class_of(n: Node) -> String:
	var s: Script = n.get_script()
	while s != null:
		var g := String(s.get_global_name())
		if g != "":
			return g
		s = s.get_base_script()
	return ""


func _nodes_of_classes(root: Node, classes: Array) -> Array:
	var out := []
	if _class_of(root) in classes:
		out.append(root)
	for c in root.get_children():
		out.append_array(_nodes_of_classes(c, classes))
	return out


func _nodes_by_script_dir(root: Node, dir: String) -> Array:
	var out := []
	var s: Script = root.get_script()
	if s != null and s.resource_path.begins_with(dir):
		out.append(root)
	for c in root.get_children():
		out.append_array(_nodes_by_script_dir(c, dir))
	return out


func _all_of(root: Node, cls: String) -> Array:
	var out := []
	if root.is_class(cls):
		out.append(root)
	for c in root.get_children():
		out.append_array(_all_of(c, cls))
	return out


func _find_class(root: Node, cls: String) -> Node:
	var a := _all_of(root, cls)
	return a[0] if not a.is_empty() else null


# ------------------------------------------------------------------ замер


func _wait(s: float) -> void:
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) < s * 1e6:
		await RenderingServer.frame_post_draw


## Кадры --sample= с: время кадра по стене (между frame_post_draw), CPU/GPU отрисовки окна
## (viewport measured render time), проходы GPU по меткам движка (--gpu-profile), мониторы.
func _sample(dur := -1.0, track_air := false) -> Dictionary:
	var vp_rid := get_viewport().get_viewport_rid()
	var rd := RenderingServer.get_rendering_device()
	var frame := PackedFloat64Array()
	var gpu := PackedFloat64Array()
	var cpu := PackedFloat64Array()
	var setup := PackedFloat64Array()
	var passes := {}
	var gpu_frames := 0
	var last_ts_frame := -1
	var mon := {
		draw_calls = Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME,
		primitives = Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME,
		objects = Performance.RENDER_TOTAL_OBJECTS_IN_FRAME,
		process_ms = Performance.TIME_PROCESS,
		physics_ms = Performance.TIME_PHYSICS_PROCESS,
	}
	var mon_sum := {}
	for k in mon:
		mon_sum[k] = 0.0
	var air_busy := PackedByteArray()
	var rt: Node = _game.get("air_runtime") if track_air else null
	var t0 := Time.get_ticks_usec()
	var t_prev := t0
	var limit := (_sample_s if dur < 0.0 else dur) * 1e6
	while (Time.get_ticks_usec() - t0) < limit:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		frame.append((now - t_prev) / 1000.0)
		t_prev = now
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
		setup.append(RenderingServer.get_frame_setup_time_cpu())
		for k in mon:
			var v := Performance.get_monitor(mon[k])
			mon_sum[k] += v * 1000.0 if k.ends_with("_ms") else v
		if rt != null:
			air_busy.append(1 if rt.call("busy") else 0)
		if rd != null:
			var n := rd.get_captured_timestamps_count()
			var f := rd.get_captured_timestamps_frame()
			if n > 1 and f != last_ts_frame:
				last_ts_frame = f
				gpu_frames += 1
				for i in n - 1:
					var nm := rd.get_captured_timestamp_name(i)
					var d := (
						rd.get_captured_timestamp_gpu_time(i + 1)
						- rd.get_captured_timestamp_gpu_time(i)
					) / 1e6
					passes[nm] = float(passes.get(nm, 0.0)) + d
				passes["_total"] = float(passes.get("_total", 0.0)) + (
					rd.get_captured_timestamp_gpu_time(n - 1) - rd.get_captured_timestamp_gpu_time(0)
				) / 1e6
	var row := {
		frames = frame.size(),
		frame_ms = _mean(frame), frame_ms_1pct = _worst1(frame),
		gpu_ms = _mean(gpu), gpu_ms_1pct = _worst1(gpu),
		cpu_render_ms = _mean(cpu), setup_ms = _mean(setup),
	}
	for k in mon_sum:
		row[k] = mon_sum[k] / maxf(1.0, frame.size())
	if gpu_frames > 0:
		var p := {}
		for k: String in passes:
			p[k] = snappedf(passes[k] / gpu_frames, 0.001)
		row.passes = p
	var cfx := _cloud_effects()
	if not cfx.is_empty():
		row.cloud_count = cfx[0].get("cloud_count")
		row.cloud_res = cfx[0].get("resolution_scale")
	if _game != null:
		row.sim_t = _game.sim_time_s
	if track_air:
		row.frames_list = frame
		row.gpu_list = gpu
		row.air_busy = Array(air_busy)
	return row


static func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


## Среднее 1 % худших значений.
static func _worst1(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	var n1 := maxi(1, int(ceil(s.size() * 0.01)))
	return _mean(s.slice(s.size() - n1, s.size()))


## CPU по поддеревьям (без паузы): узлы со скриптом в Game на глубине 1–2 по очереди
## выключаются (process_mode = DISABLED: ни _process, ни _physics_process поддерева) на --sample= с.
## Разница кадра к соседним замерам base — цена поддерева на CPU (грубо: полёт идёт дальше).
func _cpu_run() -> void:
	while _game.sim_time_s < _cpu_t and int(_main.get("state")) == 2:
		await get_tree().physics_frame
	_game.camera.set_mode("chase")
	_no_vsync()
	var cands: Array = []
	for c in _game.get_children():
		if c.get_script() != null and c != _game.get("camera"):
			cands.append(c)
		for c2 in c.get_children():
			if c2.get_script() != null and c2.get_child_count() >= 0 and c != _game.get("camera"):
				cands.append(c2)
	var b0 := await _sample()
	b0.merge({loc = _location, tag = _tag, cam = "chase", t = _cpu_t, exp = "cpu_base"})
	_write(b0)
	for n in cands:
		if not is_instance_valid(n) or int(_main.get("state")) != 2:
			continue
		var path := String(_game.get_path_to(n))
		var cls := _class_of(n)
		_ovr(n, "process_mode", Node.PROCESS_MODE_DISABLED)
		var r := await _sample()
		_undo()
		r.merge({loc = _location, tag = _tag, cam = "chase", t = _cpu_t, exp = "cpu_off",
			node = path, cls = cls})
		_write(r)
		print("PROFILE cpu %s %s off %s (%s): кадр %.2f мс" % [_location, _tag, path, cls, r.frame_ms])
		var b := await _sample(1.0)
		b.merge({loc = _location, tag = _tag, cam = "chase", t = _cpu_t, exp = "cpu_base"})
		_write(b)


## Цена периодических работ главного потока, мс на вызов (по 5 вызовов): обновление термиков
## атмосферы (раз в refresh_interval_s, на целых секундах сим.времени), выбор облаков и свет
## облаков (CloudLayer, раз в 1 с по своему таймеру). Зовёт те же методы, что игра.
func _micro_run() -> void:
	var atmo: Node = _main.find_child("Air", true, false)
	var clouds: Node = null
	for n in _nodes_of_classes(_main, ["CloudLayer"]):
		clouds = n
	var res := {}
	var cam := get_viewport().get_camera_3d()
	var eye: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var jobs := {}
	if atmo != null and atmo.has_method("refresh_now"):
		jobs["atmo.refresh_now"] = func() -> void: atmo.call("refresh_now")
		# то же после смены поля: ThermalField._update_air пересобирает AirThermals (build)
		jobs["atmo.refresh_now+AirThermals.build"] = func() -> void:
			var tf: Object = atmo.get("field")
			if tf != null:
				tf.set("_air_key", "frame_profile")
			atmo.call("refresh_now")
	if clouds != null:
		jobs["clouds._select"] = func() -> void: clouds.call("_select", float(atmo.get("time_s")), eye)
		jobs["clouds._update_light"] = func() -> void: clouds.call("_update_light")
		jobs["clouds._visible_records"] = func() -> void: clouds.call("_visible_records", cam)
	for k: String in jobs:
		var ts := PackedFloat64Array()
		for i in 5:
			var t0 := Time.get_ticks_usec()
			(jobs[k] as Callable).call()
			ts.append((Time.get_ticks_usec() - t0) / 1000.0)
			await RenderingServer.frame_post_draw
		res[k] = {mean = _mean(ts), max = ts[ts.size() - 1] if ts.is_empty() else _worst1(ts)}
		print("PROFILE micro %s %s %s: %.2f мс (макс %.2f)" % [_location, _tag, k, res[k].mean, res[k].max])
	_write({loc = _location, tag = _tag, exp = "_micro", micro = res})


## Пересчёт поля воздуха в полёте: кадры до начала (idle) и пока AirRuntime.busy().
func _air_run() -> void:
	var rt: Node = _game.get("air_runtime")
	if rt == null:
		print("PROFILE air: нет AirRuntime")
		return
	while _game.sim_time_s < _air_t and int(_main.get("state")) == 2:
		await get_tree().physics_frame
	_game.camera.set_mode("chase")
	var idle := await _sample(3.0, true)
	idle.merge({loc = _location, tag = _tag, cam = "chase", t = _air_t, exp = "air_idle"})
	_write(idle)
	rt.call("request_recompute", "frame_profile")
	var t0 := Time.get_ticks_usec()
	var busy := await _sample(1.0, true)
	var rows := [busy]
	while rt.call("busy") and (Time.get_ticks_usec() - t0) < AIR_MAX_S * 1e6:
		rows.append(await _sample(1.0, true))
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	for i in rows.size():
		var r: Dictionary = rows[i]
		r.merge({loc = _location, tag = _tag, cam = "chase", t = _air_t, exp = "air_busy", i = i,
			wall_s = wall})
		_write(r)
	print("PROFILE air %s %s: пересчёт %.1f с стены, %d окон замера" % [
		_location, _tag, wall, rows.size()
	])


func _write(row: Dictionary) -> void:
	var f := FileAccess.open(_out_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_out_path, FileAccess.WRITE)
	if f == null:
		push_error("frame_profile: не открыть %s" % _out_path)
		return
	f.seek_end()
	f.store_line(JSON.stringify(row))


func _fail(why: String) -> void:
	print("frame_profile: FAIL %s (%s)" % [_location, why])
	await _quit(1)


func _quit(code: int) -> void:
	get_tree().paused = false
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
