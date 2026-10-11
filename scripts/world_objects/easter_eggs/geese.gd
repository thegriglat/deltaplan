class_name EggGeese
extends EasterEgg
## Клин гусей (EE-6): в сезон перелёта клин 20–40 птиц идёт по прямой через область вокруг центра
## локации. Время, прямая и курс — от ключа мира (rng планировщика), не от пилота (К4): пилот
## лишь видит то, что оказалось рядом. Положение — функция ctx.t − t0. Птицы — один MultiMesh,
## взмах крыльев делает шейдер (К13), звук — AudioStreamPlayer3D на шине Ambient (К14).
## Вне сезона и при отсеве по весу месяца узел «пустой» (без мешей и звука) и живёт до конца.

const SHADER := "res://scripts/world_objects/easter_eggs/geese.gdshader"

var _ghost := true  ## нет птиц (не сезон / отсев)
var _dir := Vector3.FORWARD
var _p0 := Vector3.ZERO  ## центр клина в t0 (xz), м
var _speed := 16.0
var _life := 0.0  ## время пути, с
var _base_alt := 0.0  ## высота клина над уровнем моря, м
var _cfg: Dictionary = {}
var _n := 0
var _slots: Array[Vector3] = []  ## места строя
var _jit: Array[Vector3] = []
var _bph: Array[Vector3] = []  ## фазы дыхания по осям
var _bper: Array[Vector3] = []
var _flap_phase: Array[float] = []
var _events: Array = []  ## [[t, ряд→слот K]] смены ведущего
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _player: AudioStreamPlayer3D
var _height_at: Callable
var _pilot := Vector3.ZERO
var _last_pos := PackedVector3Array()  ## места птиц после последнего _pose


## Сезон: {weight, heading_deg, kind} для месяца и широты. weight 0 — вне сезона.
static func season(month: int, lat_deg: float, cfg: Dictionary) -> Dictionary:
	var m := month
	var south := lat_deg < 0.0
	if south:
		m = (month + 5) % 12 + 1
	var s: Dictionary = cfg.get("season", {})
	for kind in ["spring", "autumn"]:
		var e: Dictionary = s.get(kind, {})
		var months: Array = e.get("months", [])
		var i := -1
		for j in months.size():
			if int(months[j]) == m:
				i = j
		if i >= 0:
			var h := float(e.get("heading_deg", 0.0))
			if south:
				h = fposmod(180.0 - h, 360.0)
			return {"weight": float(e.weights[i]), "heading_deg": h, "kind": kind}
	return {"weight": 0.0, "heading_deg": 0.0, "kind": ""}


static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	return float(season(ctx.month, ctx.lat_deg, cfg).weight) > 0.0


## Единичный вектор курса (0 — север = −Z, 90 — восток = +X).
static func dir_of(heading_deg: float) -> Vector3:
	var h := deg_to_rad(heading_deg)
	return Vector3(sin(h), 0.0, -cos(h))


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	var sea := season(ctx.month, ctx.lat_deg, cfg)
	# порядок бросков: отсев, курс, смещение, скорость, высота, число птиц, дальше — строй
	var keep := rng.randf() < float(sea.weight)
	var spread := float(cfg.get("season", {}).get("heading_spread_deg", 25.0))
	var hdg := float(sea.heading_deg) + (rng.randf() * 2.0 - 1.0) * spread
	var off := (rng.randf() * 2.0 - 1.0) * float(cfg.get("max_offset_m", 3000.0))
	var sp: Array = cfg.get("speed_ms", [15.0, 18.3])
	_speed = lerpf(float(sp[0]), float(sp[1]), rng.randf())
	var alt: Array = cfg.get("altitude_above_start_m", [-100.0, 400.0])
	var alt_off := lerpf(float(alt[0]), float(alt[1]), rng.randf())
	var cn: Array = cfg.get("count", [20, 40])
	_n = rng.randi_range(int(cn[0]), int(cn[1]))
	if not keep or float(sea.weight) <= 0.0:
		return  # призрак: ничего не строим
	_ghost = false
	_dir = dir_of(hdg)
	var perp := Vector3(-_dir.z, 0.0, _dir.x)
	var half := float(cfg.get("half_len_m", 4000.0))
	var centre := _centre(ctx)
	_p0 = Vector3(centre.x, 0.0, centre.z) + perp * off - _dir * half
	_life = 2.0 * half / _speed
	_height_at = ctx.height_at
	_base_alt = centre.y + alt_off
	_build_formation(cfg, rng)
	_build_mesh(cfg)
	_build_sound(cfg)
	update(ctx)


## Центр области: среднее положение стартов локации (там летают пилоты; не начало координат —
## оно может быть в километрах от них); без рельефа — начало координат. y — высота старта.
func _centre(ctx: EggContext) -> Vector3:
	if ctx.place != null:
		var sites := ctx.place.start_sites()
		if not sites.is_empty():
			var sum := Vector3.ZERO
			for st in sites:
				sum += st.position as Vector3
			return sum / sites.size()
	return Vector3(0.0, float(ctx.height_at.call(0.0, 0.0)), 0.0)


func _build_formation(cfg: Dictionary, rng: RandomNumberGenerator) -> void:
	var back := float(cfg.get("row_back_m", 5.0))
	var side := float(cfg.get("row_side_m", 3.5))
	var drop := float(cfg.get("row_drop_m", 0.3))
	var jit := float(cfg.get("slot_jitter_m", 0.6))
	var bp: Array = cfg.get("breath_period_s", [4.0, 9.0])
	var sync := float(cfg.get("flap_sync_rad", 0.5))
	for k in _n:
		var row := (k + 1) / 2
		var sgn := 1.0 if k % 2 == 1 else -1.0
		_slots.append(Vector3(sgn * row * side, -row * drop, row * back))
		_jit.append(Vector3(rng.randf() - 0.5, (rng.randf() - 0.5) * 0.5, rng.randf() - 0.5) * 2.0 * jit)
		_bph.append(Vector3(rng.randf(), rng.randf(), rng.randf()) * TAU)
		_bper.append(
			Vector3(
				lerpf(float(bp[0]), float(bp[1]), rng.randf()),
				lerpf(float(bp[0]), float(bp[1]), rng.randf()),
				lerpf(float(bp[0]), float(bp[1]), rng.randf())
			)
		)
		# фаза взмаха (доля периода): ведущий — случайная, ведомый — около соседа впереди по плечу
		if k == 0:
			_flap_phase.append(rng.randf())
		else:
			var parent := 0 if k <= 2 else k - 2
			_flap_phase.append(
				fposmod(_flap_phase[parent] + (rng.randf() * 2.0 - 1.0) * sync / TAU, 1.0)
			)
	# смены ведущего: ведущий уходит назад на ряд (слот K), на его место встаёт ведомый
	var lc: Array = cfg.get("leader_change_s", [40.0, 120.0])
	var rows: Array = cfg.get("swap_rows", [2, 5])
	var t := 0.0
	while true:
		t += lerpf(float(lc[0]), float(lc[1]), rng.randf())
		if t > _life:
			break
		var r := rng.randi_range(int(rows[0]), int(rows[1]))
		var kk := clampi(2 * r - 1 + rng.randi_range(0, 1), 1, _n - 1)
		_events.append([t, kk])


func _build_mesh(cfg: Dictionary) -> void:
	var mesh := _load_mesh(String(cfg.get("model", "")))
	if mesh == null:
		mesh = BoxMesh.new()
		(mesh as BoxMesh).size = Vector3(1.6, 0.1, 0.9)
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	var hs := maxf(mesh.get_aabb().size.x * 0.5, 0.1)
	mat.set_shader_parameter(&"half_span", hs)
	mat.set_shader_parameter(&"flap_hz", float(cfg.get("flap_hz", 3.0)))
	mat.set_shader_parameter(&"amp_frac", float(cfg.get("flap_amp", 0.35)))
	var tn: Array = cfg.get("tint", [1.0, 1.0, 1.0])
	mat.set_shader_parameter(&"tint", Vector3(float(tn[0]), float(tn[1]), float(tn[2])))
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = mesh
	_mm.instance_count = _n
	_mm.custom_aabb = AABB(Vector3(-150, -60, -60), Vector3(300, 120, 200))
	for k in _n:
		_mm.set_instance_custom_data(k, Color(_flap_phase[k], 0, 0, 0))
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.material_override = mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)


static func _load_mesh(path: String) -> Mesh:
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res := load(path)
	if res is PackedScene:
		var root := (res as PackedScene).instantiate()
		var found: Mesh = null
		var stack: Array = [root]
		while not stack.is_empty() and found == null:
			var n: Node = stack.pop_back()
			if n is MeshInstance3D:
				found = (n as MeshInstance3D).mesh
			else:
				stack.append_array(n.get_children())
		root.free()
		return found
	return res as Mesh


func _build_sound(cfg: Dictionary) -> void:
	var path := String(cfg.get("sound", ""))
	if path == "" or not ResourceLoader.exists(path):
		return
	_player = AudioStreamPlayer3D.new()
	_player.stream = load(path)
	_player.bus = "Ambient" if AudioServer.get_bus_index("Ambient") >= 0 else "Master"
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_player.unit_size = float(cfg.get("sound_unit_m", 150.0))
	_player.max_distance = float(cfg.get("sound_max_m", 3500.0))
	_player.volume_db = float(cfg.get("sound_volume_db", 0.0))
	_player.attenuation_filter_cutoff_hz = float(cfg.get("sound_filter_hz", 8000.0))
	_player.autoplay = true  # заиграет при входе в дерево
	add_child(_player)


## Центр клина в момент возраста age, м (xz по курсу, y — высота с запасом над рельефом).
func center_at(age: float) -> Vector3:
	var p := _p0 + _dir * _speed * age
	var clear := float(_cfg.get("clearance_m", 100.0))
	var la := float(_cfg.get("look_ahead_m", 150.0))
	var g := 0.0
	for s: float in [0.0, 0.5, 1.0]:
		var q := p + _dir * la * s
		g = maxf(g, float(_height_at.call(q.x, q.z)))
	p.y = maxf(_base_alt, g + clear)
	return p


## Живой клин (не призрак).
func is_ghost() -> bool:
	return _ghost


func bird_count() -> int:
	return _n


func update(ctx: EggContext) -> bool:
	var age := ctx.t - t0
	if lifetime_s > 0.0 and age > lifetime_s:
		return false
	if _ghost:
		return true
	if age > _life:
		return false
	_pilot = ctx.pilot_pos
	position = center_at(age)
	basis = Basis.looking_at(_dir, Vector3.UP)
	var vis := position.distance_to(_pilot) < float(_cfg.get("fade_end_m", 3500.0)) + 150.0
	_mmi.visible = vis
	if vis:
		_pose(age)
	return true


## Центры птиц (локально) после последнего _pose — для тестов.
func bird_positions() -> PackedVector3Array:
	return _last_pos


## Места птиц в момент age: строй + дыхание + смены ведущего.
func _pose(age: float) -> void:
	var perm: Array[int] = []
	for k in _n:
		perm.append(k)
	var swap_a := -1
	var swap_k := 0
	var swap_s := 0.0
	var dur := float(_cfg.get("swap_s", 10.0))
	for e in _events:
		var te := float(e[0])
		if age >= te + dur:
			var kk := int(e[1])
			var tmp := perm[0]
			perm[0] = perm[kk]
			perm[kk] = tmp
		elif age >= te:
			swap_a = perm[0]
			swap_k = int(e[1])
			swap_s = smoothstep(0.0, 1.0, (age - te) / dur)
			break
		else:
			break
	_last_pos.resize(_n)
	var breath := float(_cfg.get("breath_m", 0.7))
	var f0 := float(_cfg.get("fade_start_m", 2500.0))
	var f1 := maxf(float(_cfg.get("fade_end_m", 3500.0)), f0 + 1.0)
	var xf := global_transform if is_inside_tree() else transform
	var lift := float(_cfg.get("swap_lift_m", 3.0))
	for slot in _n:
		var bird := perm[slot]
		var p := _slots[slot]
		if swap_a >= 0:
			if slot == 0:
				p = _slots[0].lerp(_slots[swap_k], swap_s)
				p.y += lift * sin(PI * swap_s)  # обходят друг друга по высоте
			elif slot == swap_k:
				p = _slots[swap_k].lerp(_slots[0], swap_s)
				p.y -= lift * sin(PI * swap_s)
		var ph := _bph[bird]
		var per := _bper[bird]
		p += _jit[bird]
		p += (
			Vector3(
				sin(TAU * age / per.x + ph.x), 0.5 * sin(TAU * age / per.y + ph.y), sin(TAU * age / per.z + ph.z)
			)
			* breath
		)
		_last_pos[bird] = p
		# граница видимости: птица сжимается к нулю между f0 и f1 от пилота
		var sc := clampf((f1 - (xf * p).distance_to(_pilot)) / (f1 - f0), 0.0, 1.0)
		_mm.set_instance_transform(bird, Transform3D(Basis.from_scale(Vector3.ONE * sc), p))
