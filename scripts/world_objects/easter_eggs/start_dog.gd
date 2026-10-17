class_name EggStartDog
extends EasterEgg
## Собака у стартового лагеря (DOG-K4, docs/contracts/start-dog.md). Модель — DOG-K2, лай — DOG-K3.
## Дом — палатки лагеря и пятачок вещей у старта (SC-K1); в покое — функция времени мира и сида
## (сегменты rest / wander / sniff, одинаково при любом шаге кадра). Бегущий (phase running) ближе
## notice_m — через react_s галопом сбоку от него, лает; у бровки или после отрыва стоит и лает вслед
## (edge), трусцой домой (return), дальше снова покой (новая эпоха расписания с точки прихода).
## Только картинка и звук: без тел, лучей и записи в чужое; препятствия — place.obstacles_near.
## Режим показа клипов (кадры DOG-1): DP_DOG_CLIP или cfg.showcase_clip ("all" — по очереди) —
## стоит у пилота и играет клип на месте; "" — обычное поведение.

const MODEL := "res://assets/easter_eggs/start_dog/dog.glb"
const BARK_FMT := "res://assets/easter_eggs/start_dog/bark_%d.ogg"
const CLIPS: PackedStringArray = ["gallop", "trot", "walk", "idle", "bark", "lie", "sit", "sniff"]
const DYNAMIC: PackedStringArray = ["chase", "edge", "return"]
const DT_MAX := 1.0 / 30.0  ## шаг погони, с (длинный кадр — подшагами)
const JUMP_S := 2.0  ## прыжок времени длиннее — погоня забыта, собака дома

var _cfg: Dictionary = {}
var _hf := Callable()  ## высота рельефа (ctx.height_at)
var _ap: AnimationPlayer
var _model: Node3D
var _player: AudioStreamPlayer3D
var _barks_snd: Array[AudioStream] = []
var _meshes: Array[GeometryInstance3D] = []
var _clip := ""
var _scale := 1.0
var _visible := true
var _shadow := true
var _show := ""  ## режим показа клипов
# место
var _has_home := false
var _s := Vector2.ZERO  ## старт лагеря (x, z)
var _fwd := Vector2(0.0, -1.0)
var _right := Vector2(1.0, 0.0)
var _home_c := Vector2.ZERO
var _home_r := 0.0
var _anchors: Array[Vector2] = []  ## точки отдыха (у вещей и палаток)
var _weights: PackedFloat32Array = []
var _obst: Array[Vector3] = []  ## x, y — центр (мир x, z), z — радиус с зазором
var _seed := 0
# состояние
var _state := "rest"
var _pos := Vector2.ZERO
var _vel := Vector2.ZERO
var _yaw := 0.0
var _anim := "lie"
var _barks := 0
var _target := -1
var _aim := Vector2.ZERO
var _last_t := NAN
# расписание покоя: эпоха (с какого момента и точки), сегменты
var _epoch := 0
var _ep_t := 0.0
var _ep_anchor := 0
var _segs: Array[Dictionary] = []
var _seg_i := 0
# погоня
var _chases := 0
var _react_id := -1
var _react_at := INF
var _side := 1.0
var _side_m := 3.0
var _lead_m := 0.0
var _next_bark := INF
var _edge_until := 0.0
var _home_i := 0
var _bark_clock := -1.0  ## время в цикле bark (стоит и лает); < 0 — не лает стоя
var _brow := {}  ## lat (шаг 0,5 м) → допустимый along


## Доля мест-дней (DOG-K4): детерминированно по месту старта лагеря и дате.
static func present(start: Vector3, month: int, day: int, cfg: Dictionary) -> bool:
	var r := RandomNumberGenerator.new()
	r.seed = ("start_dog|%d|%d|%d|%d" % [roundi(start.x), roundi(start.z), month, day]).hash()
	return r.randf() < float(cfg.get("presence_share", 0.6))


## Не ночь, лагерь есть, сегодня здесь собака.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.sun_elev_deg < float(cfg.get("min_sun_deg", -6.0)) or ctx.place == null:
		return false
	var cs := ctx.place.camp_start()
	if ctx.place.camp().is_empty() or cs.is_empty():
		return false
	return present(cs.position, ctx.month, ctx.day, cfg)


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, _t0: float) -> void:
	_cfg = cfg
	_hf = ctx.height_at
	_seed = rng.randi()
	_show = OS.get_environment("DP_DOG_CLIP")
	if _show == "":
		_show = String(cfg.get("showcase_clip", ""))
	if _show != "":
		_begin_show(ctx)
		return
	var camp: Array[Dictionary] = ctx.place.camp() if ctx.place != null else ([] as Array[Dictionary])
	var cs: Dictionary = ctx.place.camp_start() if ctx.place != null else {}
	if camp.is_empty() or cs.is_empty():
		return  # force без лагеря: собаки нет, узлов нет
	_has_home = true
	var sp: Vector3 = cs.position
	_s = Vector2(sp.x, sp.z)
	var h := deg_to_rad(float(cs.heading_deg))
	_fwd = Vector2(sin(h), -cos(h))
	_right = Vector2(cos(h), sin(h))
	_build_home(ctx, camp, rng)
	_ep_t = t0
	_ep_anchor = _pick_anchor(_rand(0, 0, 9), -1)
	_pos = _anchors[_ep_anchor]
	_build_nodes()


## Только чтение для тестов (DOG-K4); aim — точка, куда бежит; home, home_r — дом.
func info() -> Dictionary:
	return {
		"state": _state,
		"pos": _p3(_pos),
		"speed": _vel.length(),
		"anim": _anim,
		"anim_scale": _scale,
		"barks": _barks,
		"target_id": _target,
		"aim": _p3(_aim),
		"home": _p3(_home_c),
		"home_r": _home_r,
	}


## Собака есть (лагерь найден или показ клипов).
func has_dog() -> bool:
	return _has_home or _show != ""


func update(ctx: EggContext) -> bool:
	if _show != "":
		_update_show(ctx)
		return true
	if not _has_home:
		return true
	var t := ctx.t
	var dt := 0.0 if is_nan(_last_t) else t - _last_t
	_last_t = t
	if dt < 0.0 or dt > JUMP_S:
		if _state in DYNAMIC:
			_new_epoch(t, _nearest_anchor(_pos))
		_react_id = -1
		dt = 0.0
	_watch_runners(ctx)
	if _state in DYNAMIC:
		var left := dt
		while left > 1e-6 and _state in DYNAMIC:
			var h := minf(left, DT_MAX)
			left -= h
			_step_dynamic(ctx, t - left, h)
	if not _state in DYNAMIC:
		_rest_at(t)
	_pose(ctx, dt)
	return true


# ---------------------------------------------------------------- дом и расписание покоя


func _build_home(ctx: EggContext, camp: Array[Dictionary], rng: RandomNumberGenerator) -> void:
	var c := Vector2.ZERO
	for t in camp:
		c += Vector2(t.position.x, t.position.z)
	_home_c = c / float(camp.size())
	var kinds := PackedStringArray(_cfg.get("avoid_kinds", ["tent", "gear"]))
	var margin := float(_cfg.get("avoid_margin_m", 0.3))
	var reach := _s.distance_to(_home_c) + float(_cfg.get("home_radius_m", 14.0)) + 40.0
	for o in ctx.place.obstacles_near(_s, reach, kinds):  # ObstacleIndex: (x, z, радиус)
		_obst.append(Vector3(o.x, o.y, o.z + margin))
	for t in camp:  # палатки — и без индекса: круг radius
		_obst.append(Vector3(t.position.x, t.position.z, float(t.get("radius", 2.0)) + margin))
	var gap := float(_cfg.get("anchor_gap_m", 1.0))
	var kg := PackedStringArray(["gear"])
	for g in ctx.place.obstacles_near(_s, float(_cfg.get("gear_search_m", 30.0)), kg):
		_add_anchor(Vector2(g.x, g.y), g.z + margin + gap, float(_cfg.get("gear_weight", 2.5)), rng)
	for t in camp:
		var r := float(t.get("radius", 2.0)) + margin + gap
		_add_anchor(Vector2(t.position.x, t.position.z), r, 1.0, rng)
	if _anchors.is_empty():
		_anchors.append(_push_out(_home_c))
		_weights.append(1.0)
	_home_r = float(_cfg.get("home_radius_m", 14.0))
	for a in _anchors:
		_home_r = maxf(_home_r, a.distance_to(_home_c) + 2.0)


## Точка отдыха у препятствия (центр c, радиус r): с направления из rng, не в препятствии и не
## в коридоре разбега; не нашлась за 6 бросков — нет точки.
func _add_anchor(c: Vector2, r: float, w: float, rng: RandomNumberGenerator) -> void:
	for i in 6:
		var a := rng.randf() * TAU
		var p := c + Vector2(cos(a), sin(a)) * r
		if not _in_corridor(p) and _inside_obst(p) < 0:
			_anchors.append(p)
			_weights.append(w)
			return


func _in_corridor(p: Vector2) -> bool:
	var rel := p - _s
	return (
		rel.dot(_fwd) > -float(_cfg.get("corridor_back_m", 8.0))
		and absf(rel.dot(_right)) < float(_cfg.get("corridor_half_m", 11.0))
	)


func _inside_obst(p: Vector2) -> int:
	for i in _obst.size():
		var o := _obst[i]
		if p.distance_squared_to(Vector2(o.x, o.y)) < o.z * o.z:
			return i
	return -1


## Детерминированное случайное 0–1 по (эпоха, сегмент, слот) — расписание и погоня (из сида rng).
func _rand(ep: int, k: int, slot: int) -> float:
	var r := RandomNumberGenerator.new()
	r.seed = ("%d|%d|%d|%d" % [_seed, ep, k, slot]).hash()
	return r.randf()


func _rand_in(range_v: Variant, x: float) -> float:
	var a: Array = range_v
	return lerpf(float(a[0]), float(a[1]), x)


## Точка отдыха по весам (у вещей чаще), кроме not_i.
func _pick_anchor(x: float, not_i: int) -> int:
	var total := 0.0
	for i in _weights.size():
		if i != not_i:
			total += _weights[i]
	if total <= 0.0:
		return 0
	var v := x * total
	var last := 0
	for i in _weights.size():
		if i == not_i:
			continue
		last = i
		v -= _weights[i]
		if v <= 0.0:
			return i
	return last


func _nearest_anchor(p: Vector2) -> int:
	var best := 0
	for i in _anchors.size():
		if p.distance_squared_to(_anchors[i]) < p.distance_squared_to(_anchors[best]):
			best = i
	return best


func _new_epoch(t: float, anchor: int) -> void:
	_epoch += 1
	_ep_t = t
	_ep_anchor = anchor
	_segs.clear()
	_seg_i = 0
	_state = "sniff"
	_vel = Vector2.ZERO
	_target = -1
	_bark_clock = -1.0


## Сегмент k эпохи: {kind, t0, t1, anchor, speed, anim | path, cum}.
func _make_seg(k: int, t_start: float, prev: Dictionary) -> Dictionary:
	var e := _epoch
	var at: int = prev.get("anchor", _ep_anchor)
	var kind := "rest"
	if k == 0:
		kind = "rest" if e == 0 else "sniff"
	elif String(prev.kind) == "wander":
		kind = "rest" if _rand(e, k, 0) < float(_cfg.get("rest_share", 0.5)) else "sniff"
	elif _anchors.size() > 1:
		kind = "wander"
	else:
		kind = "sniff" if String(prev.kind) == "rest" else "rest"
	var seg := {"kind": kind, "t0": t_start, "anchor": at, "speed": 0.0, "anim": ""}
	if kind == "wander":
		var to := _pick_anchor(_rand(e, k, 1), at)
		var path := _plan_path(_anchors[at], _anchors[to])
		var cum := PackedFloat32Array([0.0])
		for i in range(1, path.size()):
			cum.append(cum[i - 1] + path[i - 1].distance_to(path[i]))
		var trot := _rand(e, k, 2) < float(_cfg.get("trot_share", 0.2))
		var v := _rand_in(_cfg.get("trot_ms" if trot else "walk_ms", [0.8, 1.3]), _rand(e, k, 3))
		seg.anchor = to
		seg.path = path
		seg.cum = cum
		seg.speed = v
		seg.t1 = t_start + maxf(cum[cum.size() - 1] / v, 0.5)
	elif kind == "rest":
		seg.t1 = t_start + _rand_in(_cfg.get("rest_s", [20.0, 90.0]), _rand(e, k, 4))
		seg.anim = "sit" if _rand(e, k, 5) < float(_cfg.get("sit_share", 0.3)) else "lie"
	else:
		seg.t1 = t_start + _rand_in(_cfg.get("sniff_s", [4.0, 15.0]), _rand(e, k, 4))
		seg.anim = "sniff"
	return seg


## Путь a → b: в обход коридора разбега (сзади) и кругов препятствий.
func _plan_path(a: Vector2, b: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array([a])
	var la := (a - _s).dot(_right)
	var lb := (b - _s).dot(_right)
	var back := -float(_cfg.get("corridor_back_m", 8.0)) - 2.0
	var half := float(_cfg.get("corridor_half_m", 11.0)) + 1.0
	if signf(la) != signf(lb) and _seg_hits_corridor(a, b):
		pts.append(_s + _fwd * back + _right * signf(la) * half)
		pts.append(_s + _fwd * back + _right * signf(lb) * half)
	pts.append(b)
	for pass_i in 4:
		var changed := false
		var out := PackedVector2Array([pts[0]])
		for i in range(1, pts.size()):
			var p0 := out[out.size() - 1]
			var p1 := pts[i]
			var k := _first_block(p0, p1)
			if k >= 0:
				var o := _obst[k]
				var c := Vector2(o.x, o.y)
				var n := Geometry2D.get_closest_point_to_segment(c, p0, p1) - c
				if n.length() < 1e-3:
					n = (p1 - p0).orthogonal()
				out.append(c + n.normalized() * (o.z + 0.6))
				changed = true
			out.append(p1)
		pts = out
		if not changed:
			break
	return pts


func _seg_hits_corridor(a: Vector2, b: Vector2) -> bool:
	for i in 9:
		if _in_corridor(a.lerp(b, i / 8.0)):
			return true
	return false


func _first_block(a: Vector2, b: Vector2) -> int:
	for i in _obst.size():
		var o := _obst[i]
		var c := Vector2(o.x, o.y)
		if a.distance_to(c) < o.z or b.distance_to(c) < o.z:
			continue  # конец в круге — выталкивание разберётся
		if Geometry2D.get_closest_point_to_segment(c, a, b).distance_to(c) < o.z:
			return i
	return -1


## Покой: состояние и место — функция времени (эпоха, сегменты), без шага кадра.
func _rest_at(t: float) -> void:
	if _segs.is_empty():
		_segs.append(_make_seg(0, _ep_t, {}))
	if t < float(_segs[_seg_i].t0):
		_seg_i = 0
	while t >= float(_segs[_seg_i].t1):
		if _seg_i + 1 >= _segs.size():
			_segs.append(_make_seg(_segs.size(), float(_segs[_seg_i].t1), _segs[_seg_i]))
		_seg_i += 1
	var seg: Dictionary = _segs[_seg_i]
	_state = String(seg.kind)
	_anim = String(seg.anim)
	if _state == "wander":
		var path: PackedVector2Array = seg.path
		var cum: PackedFloat32Array = seg.cum
		var total := cum[cum.size() - 1]
		var d := minf((t - float(seg.t0)) * float(seg.speed), total)
		var i := 1
		while i < cum.size() - 1 and cum[i] < d:
			i += 1
		var u := clampf((d - cum[i - 1]) / maxf(cum[i] - cum[i - 1], 1e-4), 0.0, 1.0)
		_pos = _push_out(path[i - 1].lerp(path[i], u))
		var dir := (path[i] - path[i - 1]).normalized()
		_vel = dir * float(seg.speed) if d < total else Vector2.ZERO
	else:
		_pos = _anchors[int(seg.anchor)]
		_vel = Vector2.ZERO


# ---------------------------------------------------------------- погоня


## Ближайший бегущий ближе notice_m → через react_s погоня. Стоящий и идущий — не цель.
func _watch_runners(ctx: EggContext) -> void:
	if _state == "chase":
		return
	var notice := float(_cfg.get("notice_m", 80.0))
	var best := {}
	var best_d := INF
	for r: Dictionary in ctx.runners:
		if String(r.phase) != "running":
			continue
		var d := Vector2(r.pos.x, r.pos.z).distance_to(_pos)
		if d < notice and d < best_d:
			best_d = d
			best = r
	if best.is_empty():
		_react_id = -1
		return
	if _react_id != int(best.id):
		_react_id = int(best.id)
		_react_at = ctx.t + _rand_in(_cfg.get("react_s", [0.3, 0.8]), _rand(-1, _chases, 0))
	if ctx.t >= _react_at:
		_start_chase(ctx, best)


func _start_chase(ctx: EggContext, r: Dictionary) -> void:
	_chases += 1
	_target = int(r.id)
	_react_id = -1
	_state = "chase"
	_bark_clock = -1.0
	var rp := Vector2(r.pos.x, r.pos.z)
	_side = 1.0 if (_pos - rp).dot(_runner_dir(r).orthogonal()) >= 0.0 else -1.0
	_side_m = _rand_in(_cfg.get("side_m", [2.5, 4.0]), _rand(-2, _chases, 0))
	_lead_m = _rand_in(_cfg.get("lead_m", [-1.0, 2.0]), _rand(-2, _chases, 1))
	_next_bark = ctx.t + _bark_gap()


func _bark_gap() -> float:
	return _rand_in(_cfg.get("bark_interval_s", [0.4, 0.9]), _rand(-3, _barks, 0))


func _runner_dir(r: Dictionary) -> Vector2:
	var v := Vector2(r.vel.x, r.vel.z)
	if v.length() > 1.0:
		return v.normalized()
	var h := deg_to_rad(float(r.heading_deg))
	return Vector2(sin(h), -cos(h))


func _runner(ctx: EggContext, rid: int) -> Dictionary:
	for r: Dictionary in ctx.runners:
		if int(r.id) == rid:
			return r
	return {}


## Шаг погони, лая у бровки и пути домой: скорость к желаемой не круче accel_ms2, вперёд — не
## дальше допустимого along с запасом на торможение, из препятствий и от бегущих — выталкивание.
func _step_dynamic(ctx: EggContext, t: float, dt: float) -> void:
	var r := _runner(ctx, _target) if _target >= 0 else {}
	var amax := float(_cfg.get("accel_ms2", 8.0))
	var want := Vector2.ZERO
	if _state == "chase":
		var ph := String(r.get("phase", ""))
		if r.is_empty():
			_go_home()
		elif ph == "flying":
			_to_edge(t, _rand_in(_cfg.get("edge_bark_s", [3.0, 8.0]), _rand(-4, _chases, 0)))
		elif ph != "running":
			_to_edge(t, float(_cfg.get("fail_bark_s", 1.5)))
		else:
			var rp := Vector2(r.pos.x, r.pos.z)
			var dir := _runner_dir(r)
			_aim = rp + dir * _lead_m + dir.orthogonal() * _side * _side_m
			# к точке сбоку: скорость бегущего + сближение, которое успевает погаснуть (без перелёта)
			var e := _aim - _pos
			var d := e.length()
			var close := minf(float(_cfg.get("follow_gain", 1.5)) * d, sqrt(amax * d))
			want = Vector2(r.vel.x, r.vel.z) + (e / d * close if d > 1e-3 else Vector2.ZERO)
			if _along(_pos) >= _allowed_along(_pos) - 0.3 and _along(rp) > _along(_pos):
				_to_edge(t, _rand_in(_cfg.get("edge_bark_s", [3.0, 8.0]), _rand(-4, _chases, 0)))
			elif t >= _next_bark:
				_bark()
				_next_bark = t + _bark_gap()
	if _state == "edge":
		want = Vector2.ZERO
		if not r.is_empty():
			_aim = Vector2(r.pos.x, r.pos.z)
		if _vel.length() < float(_cfg.get("still_ms", 0.15)):
			_bark_clock = maxf(_bark_clock, 0.0)
		elif t >= _next_bark:
			_bark()
			_next_bark = t + _bark_gap()
		if t >= _edge_until:
			_go_home()
	if _state == "return":
		var home := _anchors[_home_i]
		var d := home.distance_to(_pos)
		if d < float(_cfg.get("arrive_m", 1.0)):
			_new_epoch(t, _home_i)
			return
		_aim = home
		want = (home - _pos) / d * minf(float(_cfg.get("return_ms", 3.0)), sqrt(2.0 * amax * d))
	want = _avoid(want.limit_length(float(_cfg.get("gallop_max_ms", 10.0))))
	_vel = _vel.move_toward(want, amax * dt)
	var va := _vel.dot(_fwd)  # бровка и max_along: успеть остановиться
	if va > 0.0:
		var vcap := sqrt(2.0 * amax * maxf(_allowed_along(_pos) - _along(_pos), 0.0))
		if va > vcap:
			_vel -= _fwd * (va - vcap)
	var np := _pos + _vel * dt
	var over := _along(np) - maxf(_allowed_along(np), _along(_pos))
	if over > 0.0:
		np -= _fwd * over
	np = _keep_gap(ctx, _push_out(np))
	_vel = (np - _pos) / dt
	_pos = np
	if _bark_clock >= 0.0:
		_bark_tick(dt)


func _to_edge(t: float, dur: float) -> void:
	_state = "edge"
	_edge_until = t + dur
	_next_bark = t


func _go_home() -> void:
	_state = "return"
	_bark_clock = -1.0
	_home_i = _nearest_anchor(_pos)


## Лай стоя: гавки в моменты anims.bark.bark_at_s цикла клипа bark.
func _bark_tick(dt: float) -> void:
	var b: Dictionary = (_cfg.get("anims", {}) as Dictionary).get("bark", {})
	var cyc := float(b.get("cycle_s", 1.2))
	var c0 := fmod(_bark_clock, cyc)
	_bark_clock += dt
	var c1 := c0 + dt
	for x in b.get("bark_at_s", [0.25]):
		var xs := float(x)
		if (c0 <= xs and xs < c1) or (c1 > cyc and xs < c1 - cyc):
			_bark()


func _bark() -> void:
	_barks += 1
	if _player != null and not _barks_snd.is_empty() and _player.is_inside_tree():
		_player.stream = _barks_snd[_barks % _barks_snd.size()]
		_player.play()


func _along(p: Vector2) -> float:
	return (p - _s).dot(_fwd)


## Допустимый along на линии lat точки p: до первой бровки впереди (проба рельефа на brow_probe_m)
## и не дальше max_along_m. Кешируется по lat (рельеф не меняется).
func _allowed_along(p: Vector2) -> float:
	var key := roundi((p - _s).dot(_right) * 2.0)
	if _brow.has(key):
		return float(_brow[key])
	var lat := key * 0.5
	var max_a := float(_cfg.get("max_along_m", 25.0))
	var probe := float(_cfg.get("brow_probe_m", 3.0))
	var tan_b := tan(deg_to_rad(float(_cfg.get("brow_slope_deg", 30.0))))
	var drop := float(_cfg.get("brow_drop_m", 0.8))
	var out := max_a
	var a := -float(_cfg.get("corridor_back_m", 8.0))
	while a < max_a:
		if _is_brow(a, lat, probe, tan_b, drop):
			out = a
			break
		a += 0.5
	_brow[key] = out
	return out


## Бровка у точки (a, lat): впереди на пробе земля уходит вниз круче tan_b или ниже продолжения
## склона (по метру позади) больше чем на drop.
func _is_brow(a: float, lat: float, probe: float, tan_b: float, drop: float) -> bool:
	var h0 := _h_al(a, lat)
	var g := h0 - _h_al(a - 1.0, lat)
	var prev := h0
	var k := 0.5
	while k <= probe + 1e-4:
		var hk := _h_al(a + k, lat)
		if (prev - hk) / 0.5 > tan_b:
			return true
		prev = hk
		k += 0.5
	return prev < h0 + g * probe - drop


func _h_al(a: float, lat: float) -> float:
	var p := _s + _fwd * a + _right * lat
	return float(_hf.call(p.x, p.y))


## Обход: курс к цели, перекрытый кругом препятствия впереди, поворачивает на касательную к нему
## (наименьший отворот, сторона — куда ближе).
func _avoid(want: Vector2) -> Vector2:
	var sp := want.length()
	if sp < 1e-3:
		return want
	var dir := want / sp
	var look := float(_cfg.get("avoid_r_m", 6.0)) + sp
	var to_aim := _aim.distance_to(_pos)
	for o in _obst:
		var rel := Vector2(o.x, o.y) - _pos
		var dist := rel.length()
		var ahead := rel.dot(dir)
		if ahead <= 0.0 or dist > look + o.z or to_aim < dist - o.z:
			continue
		var r := o.z + 0.2
		var miss := rel.dot(dir.orthogonal())
		if absf(miss) >= r:
			continue
		var side := -signf(miss) if absf(miss) > 1e-3 else 1.0
		var off := asin(minf(r / maxf(dist, 1e-3), 1.0))
		dir = rel.normalized().rotated(-side * off)
		if dir.dot(rel.normalized().orthogonal() * side) < 0.0:
			dir = rel.normalized().rotated(side * off)
	return dir * sp


## Вытолкнуть из кругов препятствий (палатки, вещи) — собака внутрь не заходит.
func _push_out(p: Vector2) -> Vector2:
	for pass_i in 3:
		var k := _inside_obst(p)
		if k < 0:
			break
		var o := _obst[k]
		var c := Vector2(o.x, o.y)
		var d := p - c
		p = c + (d.normalized() if d.length() > 1e-3 else _right) * (o.z + 0.01)
	return p


## Не ближе min_gap_m к бегущим.
func _keep_gap(ctx: EggContext, p: Vector2) -> Vector2:
	var gap := float(_cfg.get("min_gap_m", 1.5)) + 0.05
	for r: Dictionary in ctx.runners:
		if String(r.phase) != "running":
			continue
		var rp := Vector2(r.pos.x, r.pos.z)
		var d := p - rp
		if d.length() < gap:
			p = rp + (d.normalized() if d.length() > 1e-3 else _right * _side) * gap
	return p


# ---------------------------------------------------------------- картинка и звук


func _p3(p: Vector2) -> Vector3:
	var y := float(_hf.call(p.x, p.y)) if _hf.is_valid() else 0.0
	return Vector3(p.x, y, p.y)


func _build_nodes() -> void:
	var ps: PackedScene = load(MODEL) if ResourceLoader.exists(MODEL) else null
	if ps != null:
		_model = ps.instantiate() as Node3D
		add_child(_model)
		_ap = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
		for n in _model.find_children("*", "GeometryInstance3D", true, false):
			_meshes.append(n as GeometryInstance3D)
	for i in range(1, 9):
		var path := BARK_FMT % i
		if not ResourceLoader.exists(path):
			break
		_barks_snd.append(load(path))
	_player = AudioStreamPlayer3D.new()
	_player.bus = "Ambient" if AudioServer.get_bus_index("Ambient") >= 0 else "Master"
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_player.unit_size = float(_cfg.get("bark_unit_m", 6.0))
	_player.max_distance = float(_cfg.get("bark_max_m", 250.0))
	_player.volume_db = float(_cfg.get("bark_volume_db", 0.0))
	_player.position = Vector3(0.0, 0.45, -0.4)
	add_child(_player)


## Аллюр по скорости с гистерезисом (walk < trot_from_ms ≤ trot < gallop_from_ms ≤ gallop).
func _gait(v: float) -> String:
	var hy := float(_cfg.get("gait_hyst_ms", 0.3))
	var tr := float(_cfg.get("trot_from_ms", 1.6))
	var ga := float(_cfg.get("gallop_from_ms", 3.8))
	match _anim:
		"gallop":
			return "gallop" if v >= ga - hy else ("trot" if v >= tr - hy else "walk")
		"trot":
			return "gallop" if v >= ga + hy else ("trot" if v >= tr - hy else "walk")
		"walk":
			return "gallop" if v >= ga + hy else ("trot" if v >= tr + hy else "walk")
	return "gallop" if v >= ga else ("trot" if v >= tr else "walk")


func _pose(ctx: EggContext, dt: float) -> void:
	var v := _vel.length()
	var clip := _anim
	if v >= float(_cfg.get("still_ms", 0.15)):
		clip = _gait(v)
	elif _state == "edge":
		clip = "bark" if _bark_clock >= 0.0 else "idle"
	elif _state in DYNAMIC or not clip in ["lie", "sit", "sniff"]:
		clip = "idle"
	_anim = clip
	_scale = 1.0
	var sp := float(
		((_cfg.get("anims", {}) as Dictionary).get(clip, {}) as Dictionary).get("speed_ms", 0.0)
	)
	if sp > 0.0:
		var lim: Array = _cfg.get("anim_scale", [0.5, 6.0])
		_scale = clampf(v / sp, float(lim[0]), float(lim[1]))
	var face := _vel  # курс — по скорости, у бровки — на улетающего
	if _state == "edge" and v < 0.5:
		face = _aim - _pos
	if face.length() > 0.05:
		var dy := wrapf(atan2(-face.x, -face.y) - _yaw, -PI, PI)
		var rate := deg_to_rad(float(_cfg.get("turn_rate_deg_s", 360.0)))
		_yaw += clampf(dy, -rate * dt, rate * dt) if dt > 0.0 else dy
	var nose := Vector2(-sin(_yaw), -cos(_yaw))
	var half := float(_cfg.get("leg_base_m", 0.6)) * 0.5
	var pf := _pos + nose * half
	var pb := _pos - nose * half
	var dh := float(ctx.height_at.call(pf.x, pf.y)) - float(ctx.height_at.call(pb.x, pb.y))
	position = Vector3(_pos.x, float(ctx.height_at.call(_pos.x, _pos.y)), _pos.y)
	rotation = Vector3(atan2(dh, half * 2.0), _yaw, 0.0)
	_show_lod(ctx)
	if _ap != null and _visible:
		if clip != _clip and _ap.has_animation(clip):
			_ap.play(clip, 0.2)
			_clip = clip
		_ap.speed_scale = _scale


## Дальше visible_m от камеры — скрыта и AnimationPlayer стоит; тень — ближе shadow_m.
func _show_lod(ctx: EggContext) -> void:
	var cam := ctx.pilot_pos
	if ctx.camera != null and ctx.camera.is_inside_tree():
		cam = ctx.camera.global_position
	var d := cam.distance_to(position)
	var vis := d < float(_cfg.get("visible_m", 300.0))
	if vis != _visible:
		_visible = vis
		if _model != null:
			_model.visible = vis
		if _ap != null:
			if vis:
				_ap.play()
			else:
				_ap.pause()
	var sh := d < float(_cfg.get("shadow_m", 60.0))
	if sh != _shadow:
		_shadow = sh
		for m in _meshes:
			m.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if sh
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)


# ---------------------------------------------------------------- показ клипов (кадры DOG-1)


func _begin_show(ctx: EggContext) -> void:
	var pilot := Vector2(ctx.pilot_pos.x, ctx.pilot_pos.z)
	var home := pilot + Vector2(float(_cfg.get("shot_side_m", 5.0)), 0.0)
	position = Vector3(home.x, float(ctx.height_at.call(home.x, home.y)), home.y)
	var d := pilot - home
	var fwd := Vector2(-d.y, d.x).normalized() if d.length() > 0.1 else Vector2(0.0, -1.0)
	rotation.y = atan2(-fwd.x, -fwd.y)
	_pos = home
	var ps: PackedScene = load(MODEL) if ResourceLoader.exists(MODEL) else null
	if ps == null:
		return
	_model = ps.instantiate() as Node3D
	add_child(_model)
	_ap = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer


func _update_show(ctx: EggContext) -> void:
	var c := _show
	if c == "all":
		var k := int(floor(maxf(ctx.t - t0, 0.0) / float(_cfg.get("showcase_s", 4.0))))
		c = CLIPS[k % CLIPS.size()]
	_anim = c
	if _ap != null and c != _clip and _ap.has_animation(c):
		_ap.play(c, 0.2)
		_clip = c
