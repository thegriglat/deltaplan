extends Node
## Стенд cliff-look (контракт CL-К1, docs/contracts/cliff-look.md): ракурсы крутых склонов из
## tools/shots/cliff_look_views.json — кадры и диагноз членов раскраски скал. Грузит место
## как игра (--latlon, полёт с автопилотом), ставит свободную камеру по виду `pt` tools/shots/osm_place_shot.gd:
## цель (lat, lon), камера на dist_m от цели со стороны az_deg (° от севера), на cam_agl_m над землёй под
## камерой, смотрит на точку в 20 м над землёй цели; ждёт wait_s с.
##   XDG_DATA_HOME=build/cliff_look_xdg godot --path . --fullscreen --resolution 1920x1080 \
##     res://tools/shots/cliff_look_shot.tscn -- --views=tools/shots/cliff_look_views.json --place=<tag> \
##     --mode=shots|diag|find --label=<метка> --out=<каталог кадров> [--raw=<каталог>] [--only=<view,…>]
##     [--members=<член,…>] [--hint=lat,lon] [--debug]
## shots — кадры <out>/<label>_<tag>_<view>.jpg (JPEG q88).
## diag  — для каждого ракурса: маски (вес скал, уклон, экспозиция; фаза сетки слоя и высота) и кадры с
##         выключенными членами раскраски (DIAG_MEMBERS: uniform-ы материала рельефа или вариант шейдера,
##         собранный на лету из того же terrain_main.gdshaderinc — файлы шейдеров не меняются); кадры
##         <out>/diag_<tag>_<view>_<член>.jpg, сырые RGB8 — <raw>/<tag>_<view>_<член>.rgb (для
##         tools/research/cliff_look/diag_metrics.py).
## find  — станции канатных дорог (OSM aerialway) у ракурсов места: концы, высоты (подбор ракурсов).

## Кадр устоялся: средняя |разность| байтов двух снимков через 0,5 с меньше (трава и вода качаются и на паузе).
const STABLE_DIFF := 1.5
const MAIN_SCENE := preload("res://scenes/main.tscn")
const MAIN_INC := "res://scripts/terrain/terrain_main.gdshaderinc"
## Конец fragment() в terrain_main.gdshaderinc — сюда вставляется вывод маски.
const FRAG_END := "\n}\n\n// Встроенное освещение"
const HEADER := "shader_type spatial;\nrender_mode cull_back, diffuse_burley, specular_schlick_ggx;\n"
const HEADER_UNSHADED := "shader_type spatial;\nrender_mode cull_back, unshaded;\n"
## Маски диагноза (ALBEDO без света, тонмаппер линейный): m1 — вес скал rsw, уклон/90, экспозиция/360;
## m2 — фаза сетки слоя по x и z (узлы — 0), высота по модулю 32 м.
const MASKS := {
	"m1": "vec3(clamp(rsw, 0.0, 1.0), slope_deg / 90.0, mod(degrees(atan(n_class.x, -n_class.z)) + 360.0, 360.0) / 360.0)",
	"m2": "vec3(fract((wp.x - layer_origin.x) / layer_spacing), fract(wp.y / 32.0), fract((wp.z - layer_origin.y) / layer_spacing))",
	# фаза прежних слоёв strata/ledge (до CL-2): sy — высота + сдвиг fbm 250 м, шаги 7 · 3,7 = 25,9 и 7 м
	# (шейдер слоёв больше не рисует — шаги заданы числом, чтобы мерить «до/после» по одной фазе)
	"m3": "vec3(fract((wp.y + 10.0 * (fbm(wp.xz / 250.0, 2) - 0.5) * 2.0) / 25.9), fract((wp.y + 10.0 * (fbm(wp.xz / 250.0, 2) - 0.5) * 2.0) / 7.0), 0.5)",
}
## Члены раскраски скал, выключаемые в диагнозе: p — uniform-ы, def — #define, sub — замены текста тела
## шейдера (вариант на лету), shadows — тени солнца Godot. Пусто — исходный кадр.
const DIAG_MEMBERS := {
	"base": {},
	"cliff": {"p": {"cliff_tone": Vector2.ZERO, "cliff_tilt": Vector2.ZERO, "cliff_bulge": Vector2.ZERO, "cliff_crack_dark": Vector2.ZERO, "cliff_ao": Vector2.ZERO}},
	"cliff_fine": {"p": {"cliff_fine_keep": 1.0}},
	"ynoise": {"sub": [["fbm(wp.xz / 12.0 + vec2(wp.y / 8.0), 3)", "fbm(wp.xz / 12.0, 3)"],
			["fbm(wp.xz / 7.0 + vec2(wp.y / 5.0, 2.7), 3)", "fbm(wp.xz / 7.0 + vec2(0.0, 2.7), 3)"]]},
	"rock_detail": {"def": ["T_ROCK_DETAIL_OFF"]},
	"rock_tex": {"p": {"use_rock_tex": false}},
	"rock_normal": {"p": {"use_rock_normal": false}},
	"rock_macro": {"p": {"rock_macro_strength": 0.0, "rock_macro_normal": 0.0}},
	"rock_marks": {"p": {"rock_crack_dark": 0.0, "rock_scree_streaks": 0.0, "rock_tone_var": 0.0, "rock_curv_shade": 0.0}},
	"sl_rock": {"p": {"sl_rock_enabled": false}},
	"erosion": {"p": {"erosion_enabled": false}},
	"detail": {"def": ["T_DETAIL_OFF"]},
	"grid": {"sub": [["vec2 hg = height_grad(wp.xz, n_lod);", "vec2 hg = height_grad(wp.xz, n_lod + 1.0);"]]},
	"shadows": {"shadows": true, "p": {"relief_shadow_strength": 0.0}},
	"all_off": {"p": {"cliff_tone": Vector2.ZERO, "cliff_tilt": Vector2.ZERO, "cliff_bulge": Vector2.ZERO, "cliff_crack_dark": Vector2.ZERO, "cliff_ao": Vector2.ZERO, "use_rock_tex": false, "rock_crack_dark": 0.0,
			"rock_scree_streaks": 0.0, "rock_tone_var": 0.0, "rock_curv_shade": 0.0, "sl_rock_enabled": false,
			"erosion_enabled": false, "rock_macro_strength": 0.0, "rock_macro_normal": 0.0},
			"def": ["T_ROCK_DETAIL_OFF", "T_DETAIL_OFF"]},
}

var _main: Node
var _game: Node
var _args := {}
var _main_src := ""
var _saved_shaders := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		_args[kv[0].trim_prefix("--")] = kv[1] if kv.size() > 1 else ""
	var views: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(String(_args.get("views", "res://tools/shots/cliff_look_views.json"))))
	var place: Dictionary = {}
	for p: Dictionary in views.places:
		if p.tag == String(_args.get("place", "")):
			place = p
	if place.is_empty():
		print("cliff_look_shot: нет места ", _args.get("place", ""))
		get_tree().quit(1)
		return
	var gargs := PackedStringArray(["--autostart", "--autopilot", "--latlon=%s,%s" % [place.lat, place.lon],
			"--air-start=0,600", "--no-overlay", "--hour=%s" % views.hour, "--sky=clear", "--wind=2", "--bots=0", "--egg=none"])
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(gargs))
	add_child(_main)
	for i in 20000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		print("cliff_look_shot: не долетели до FLYING")
		get_tree().quit(1)
		return
	_game = _main.get_node("Game")
	get_window().mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	for i in 10:
		await get_tree().process_frame
	for cl in _main.find_children("*", "CanvasLayer", true, false):
		cl.visible = false
	for c in _main.find_children("*", "Control", true, false):
		if not c.get_parent() is Control:
			c.visible = false
	var sd: Vector3 = _game.terrain.sun_direction()
	print("cliff_look_shot: окно ", get_window().size, " место ", place.tag, " солнце %.1f° над горизонтом" % rad_to_deg(asin(clampf(sd.y, -1.0, 1.0))))
	var cam: CameraRig = _game.camera
	cam.set_mode("free")
	var only := PackedStringArray(String(_args.get("only", "")).split(",", false))
	var mode := String(_args.get("mode", "shots"))
	var out := String(_args.get("out", "/tmp"))
	DirAccess.make_dir_recursive_absolute(out)
	if mode == "find":
		_find(place)
		get_tree().quit(0)
		return
	for v: Dictionary in place.views:
		if not only.is_empty() and not String(v.name) in only:
			continue
		var geo := _view_geometry(v)
		await _settle(geo, float(v.wait_s))
		if mode == "diag":
			await _diag(place, v, geo)
		else:
			await _shot("%s/%s_%s_%s.jpg" % [out, _args.get("label", "before"), place.tag, v.name])
	get_tree().paused = false
	get_tree().quit(0)


## Камера и цель вида pt: {cpos, tgt3, az}.
func _view_geometry(v: Dictionary) -> Dictionary:
	var t: Terrain = _game.terrain
	var tgt := t.latlon_to_local(float(v.lat), float(v.lon))
	var az := deg_to_rad(float(v.az_deg))
	var dist := float(v.dist_m)
	var gy := t.height_at(tgt.x, tgt.y)
	var cx := tgt.x + sin(az) * dist
	var cz := tgt.y - cos(az) * dist
	var cpos := Vector3(cx, t.height_at(cx, cz) + float(v.cam_agl_m), cz)
	var tgt3 := Vector3(tgt.x, gy + 20.0, tgt.y)
	print("cliff_look_shot: вид %s цель %.0f,%.0f h %.0f камера %s (глаз − цель %+.0f м)" % [v.name, tgt.x, tgt.y, gy, cpos, cpos.y - gy])
	return {"cpos": cpos, "tgt3": tgt3, "az": az}


func _hold(geo: Dictionary) -> void:
	var az: float = geo.az
	var cpos: Vector3 = geo.cpos
	_game.glider.reset_in_air(cpos + Vector3(sin(az) * 60.0, 40.0, -cos(az) * 60.0), rad_to_deg(az) + 180.0)


## Ожидание wait_s (слои мира — вокруг планера у камеры), камера на месте.
func _settle(geo: Dictionary, wait_s: float) -> void:
	get_tree().paused = false
	var cam: CameraRig = _game.camera
	_hold(geo)
	var t_end := Time.get_ticks_msec() + int(wait_s * 1000.0)
	var t_reset := Time.get_ticks_msec()
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		if Time.get_ticks_msec() - t_reset > 700:
			_hold(geo)
			t_reset = Time.get_ticks_msec()
		cam.look_at_from_position(geo.cpos, geo.tgt3, Vector3.UP)
	for i in 4:
		await get_tree().process_frame
		cam.look_at_from_position(geo.cpos, geo.tgt3, Vector3.UP)


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _shot(path: String) -> void:
	var img := await _grab()
	img.save_jpg(path, 0.88)
	print("cliff_look_shot: кадр ", path, " ", img.get_size())


# ---------------------------------------------------------------- диагноз


func _materials() -> Array[ShaderMaterial]:
	return (_game.terrain.renderer as TerrainRenderer).materials()


## Вариант шейдера на лету: тело terrain_main с заменами, #define, маска (unshaded) или обычный свет.
func _runtime_shader(defs: Array, subs: Array, mask_expr: String) -> Shader:
	if _main_src == "":
		_main_src = FileAccess.get_file_as_string(MAIN_INC)
	var body := _main_src
	for s: Array in subs:
		var n := body.count(String(s[0]))
		if n != 1:
			push_error("cliff_look_shot: замена «%s» найдена %d раз" % [s[0], n])
		body = body.replace(String(s[0]), String(s[1]))
	if mask_expr != "":
		if body.count(FRAG_END) != 1:
			push_error("cliff_look_shot: не найден конец fragment()")
		body = body.replace(FRAG_END, "\n\tALBEDO = " + mask_expr + ";" + FRAG_END)
	var code := HEADER_UNSHADED if mask_expr != "" else HEADER
	for d: String in defs:
		code += "#define %s\n" % d
	var sh := Shader.new()
	sh.code = code + body
	return sh


## Шейдер на материалы ближнего варианта (full); вдали (вариант far) — как есть.
func _set_near_shader(sh: Shader) -> void:
	for m in _materials():
		if not _saved_shaders.has(m):
			_saved_shaders[m] = m.shader
		if (_saved_shaders[m] as Shader).resource_path == TerrainRenderer.SHADER.resource_path:
			m.shader = sh


func _restore_shaders() -> void:
	for m: ShaderMaterial in _saved_shaders:
		m.shader = _saved_shaders[m]
	_saved_shaders.clear()


func _set_params(p: Dictionary) -> Dictionary:
	var old := {}
	for m in _materials():
		for k: String in p:
			if not old.has(k):
				old[k] = m.get_shader_parameter(k)
			m.set_shader_parameter(k, p[k])
	return old


func _sun() -> DirectionalLight3D:
	for n in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		var l := n as DirectionalLight3D
		if l.visible and l.shadow_enabled:
			return l
	return null


func _env() -> Environment:
	var cam := get_viewport().get_camera_3d()
	if cam and cam.environment:
		return cam.environment
	var we := get_viewport().find_world_3d().environment
	if we:
		return we
	for n in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		return (n as WorldEnvironment).environment
	return null


## Кадр для масок: без света и постобработки, только рельеф.
func _mask_scene(on: bool, st: Dictionary) -> void:
	var env := _env()
	var renderer: Node = _game.terrain.renderer
	if on:
		st.hidden = []
		for n in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			var gi := n as GeometryInstance3D
			if gi.visible and not renderer.is_ancestor_of(gi):
				gi.visible = false
				st.hidden.append(gi)
		if env:
			st.env = env.duplicate()
			env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			env.tonemap_exposure = 1.0
			env.glow_enabled = false
			env.fog_enabled = false
			env.volumetric_fog_enabled = false
			env.ssao_enabled = false
			env.ssil_enabled = false
			env.sdfgi_enabled = false
			env.ssr_enabled = false
			env.adjustment_enabled = false
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0, 0, 0)
		print("cliff_look_shot: маска — окружение ", env, " скрыто ", st.hidden.size(), " объектов")
		var cam := get_viewport().get_camera_3d()
		if cam and cam.attributes:
			st.attr = cam.attributes
			cam.attributes = null
		# облака — эффект компоновщика (cloud_compositor_effect.gd), не геометрия
		st.comp = []
		for n in get_tree().root.find_children("*", "WorldEnvironment", true, false):
			var we := n as WorldEnvironment
			if we.compositor:
				st.comp.append([we, we.compositor])
				we.compositor = null
		if cam and cam.compositor:
			st.comp.append([cam, cam.compositor])
			cam.compositor = null
	else:
		for gi: GeometryInstance3D in st.get("hidden", []):
			gi.visible = true
		if env and st.has("env"):
			var e0: Environment = st.env
			for prop in ["tonemap_mode", "tonemap_exposure", "glow_enabled", "fog_enabled", "volumetric_fog_enabled",
					"ssao_enabled", "ssil_enabled", "sdfgi_enabled", "ssr_enabled", "adjustment_enabled",
					"background_mode", "background_color"]:
				env.set(prop, e0.get(prop))
		if st.has("attr"):
			get_viewport().get_camera_3d().attributes = st.attr
		for pc: Array in st.get("comp", []):
			pc[0].compositor = pc[1]


func _save_raw(path: String, img: Image) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(img.get_data())
	f.close()


## Ждать, пока кадр перестанет меняться (компиляция варианта шейдера на лету — секунды): снимки через
## 0,5 с, средняя |разность| яркости < 0,2 / 255 два раза подряд, не дольше 30 с. Возвращает последний кадр.
func _grab_stable(geo: Dictionary) -> Image:
	await _wait_frames(20, geo)
	var prev := await _grab()
	var calm := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000:
		var t1 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t1 < 500:
			await _wait_frames(1, geo)
		var cur := await _grab()
		var a := prev.get_data()
		var b := cur.get_data()
		var sum := 0
		var n := 0
		for i in range(0, a.size(), 97):
			sum += absi(int(a[i]) - int(b[i]))
			n += 1
		prev = cur
		if _args.has("debug"):
			print("cliff_look_shot: разность кадров %.3f" % (float(sum) / n))
		if float(sum) / n < STABLE_DIFF:
			calm += 1
			if calm >= 2:
				break
		else:
			calm = 0
	print("cliff_look_shot: кадр устоялся за %.1f с" % ((Time.get_ticks_msec() - t0) / 1000.0))
	return prev


func _wait_frames(n: int, geo: Dictionary) -> void:
	var cam: CameraRig = _game.camera
	for i in n:
		await get_tree().process_frame
		cam.look_at_from_position(geo.cpos, geo.tgt3, Vector3.UP)


func _diag(place: Dictionary, v: Dictionary, geo: Dictionary) -> void:
	var raw := String(_args.get("raw", "build/cliff_look_raw/diag"))
	DirAccess.make_dir_recursive_absolute(raw)
	var out := String(_args.get("out", "/tmp"))
	var stem := "%s_%s" % [place.tag, v.name]
	get_tree().paused = true  # кадры членов — в одном состоянии мира (облака, тени, LOD)
	await _wait_frames(10, geo)
	var cam3 := get_viewport().get_camera_3d()
	var meta := {"tag": place.tag, "view": v.name, "w": 0, "h": 0, "fov_deg": cam3.fov, "cam": [geo.cpos.x, geo.cpos.y, geo.cpos.z],
			"tgt": [geo.tgt3.x, geo.tgt3.y, geo.tgt3.z], "spacing": float(_game.terrain.layers[0].spacing),
			"sun_elev_deg": rad_to_deg(asin(clampf(_game.terrain.sun_direction().y, -1.0, 1.0))), "members": []}
	for mk: String in MASKS:
		var st := {}
		_mask_scene(true, st)
		_set_near_shader(_runtime_shader([], [], MASKS[mk]))
		var img := await _grab_stable(geo)
		_save_raw("%s/%s_%s.rgb" % [raw, stem, mk], img)
		meta.w = img.get_width()
		meta.h = img.get_height()
		_restore_shaders()
		_mask_scene(false, st)
	var members := PackedStringArray(String(_args.get("members", "")).split(",", false))
	for mem: String in DIAG_MEMBERS:
		if not members.is_empty() and not mem in members:
			continue
		var spec: Dictionary = DIAG_MEMBERS[mem]
		var old := _set_params(spec.get("p", {}))
		if spec.has("def") or spec.has("sub"):
			_set_near_shader(_runtime_shader(spec.get("def", []), spec.get("sub", []), ""))
		var sun := _sun() if spec.get("shadows", false) else null
		if sun:
			sun.shadow_enabled = false
		var img := await _grab_stable(geo)
		_save_raw("%s/%s_%s.rgb" % [raw, stem, mem], img)
		# «до» (CL-1) — diag_<tag>_<view>_<член>.jpg; другие метки — со своей меткой (кадры «до» не затираются)
		var lab := String(_args.get("label", "before"))
		var pre := "diag_" if lab == "before" else "diag_%s_" % lab
		img.save_jpg("%s/%s%s_%s.jpg" % [out, pre, stem, mem], 0.88)
		meta.members.append(mem)
		print("cliff_look_shot: диагноз ", stem, " ", mem)
		if sun:
			sun.shadow_enabled = true
		_restore_shaders()
		_set_params(old)
	var f := FileAccess.open("%s/%s.json" % [raw, stem], FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, " "))
	f.close()
	get_tree().paused = false


# ---------------------------------------------------------------- подбор ракурсов


func _find(place: Dictionary) -> void:
	var t: Terrain = _game.terrain
	var osm: OsmData = _game.world_link.objects.osm
	var hint := t.latlon_to_local(float(place.lat), float(place.lon))
	if _args.has("hint"):
		var p := String(_args.hint).split(",")
		hint = t.latlon_to_local(float(p[0]), float(p[1]))
	for a: Dictionary in osm.aerialways:
		var p: PackedVector2Array = a.p
		if p.size() < 2:
			continue
		var d := minf(p[0].distance_to(hint), p[p.size() - 1].distance_to(hint))
		if d > 6000.0:
			continue
		var s := "AERIALWAY %s узлов %d" % [a.t, p.size()]
		for q in [p[0], p[p.size() - 1]]:
			var ll := t.local_to_latlon(q.x, q.y)
			s += " | %.5f,%.5f h %.0f" % [ll.x, ll.y, t.height_at(q.x, q.y)]
		print(s, " (до подсказки %.0f м)" % d)
