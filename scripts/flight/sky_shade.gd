class_name SkyShade
extends Node3D
## Затенение земли крылом (PH-8, контракт PH-К7): под крылом и чуть впереди темнеет земля, потому что
## парус закрывает часть небосвода и до земли доходит меньше рассеянного света неба. Размер, резкость
## и плотность пятна честно зависят от высоты — это сигнал высоты на последних метрах посадки (прямая
## тень от солнца при посадке против солнца ложится позади, её не видно). Никаких маркеров, цвета и
## подсказок: только множитель яркости земли (чёрная декаль с альфой = доля затемнения).
##
## Одна Decal на всё: проекция вниз по нормали рельефа, ложится на землю, траву, ноги пилота; видна
## всем камерам (слой 1, кабинная камера его рисует). Никаких новых теней и каскадов.
## Физика: F(r, h) — фактор видимости диска радиуса R = √(S/π) (площадь паруса S) с центром на
## высоте h над точкой земли на горизонтальном расстоянии r — косинусно-взвешенная доля закрытого
## неба. Затемнение = gain · sky_share · F. Параметры — configs/flight.json → visual.sky_shade.

const TEX_N := 48  ## сторона текстуры декали, пикселей
const MAX_HALF_M := 10.0
const LUT_N := 128  ## отсчётов радиальной таблицы затемнения при пересчёте текстуры  ## предел полуразмера декали, м

var _cfg: Dictionary = {}
var _area := 13.5
var _decal: Decal
var _img: Image
var _tex: ImageTexture
var _bytes := PackedByteArray()
var _center_local := Vector3.ZERO  ## центр паруса в осях визуала
var _center_ready := false
var _share := 0.15
var _share_t := 0.0
var _baked_h := -1.0
var _baked_share := -1.0
var _bake_t := 1.0

## Условия освещения: Vector2(sin высоты солнца, облачность 0..1) — задаёт Game; нет — ясно, солнце высоко.
var env_fn: Callable = Callable()
## Высота земли (x, z) → y; null — берётся у родителя-Glider.
var ground_fn: Callable = Callable()
## Для замеров и тестов: сколько раз пересчитывалась текстура.
var bakes := 0
## Последнее значение h (м) и признак видимости — для тестов.
var last_h := 0.0
var last_share := 0.0


func setup(area_m2: float, cfg: Dictionary) -> void:
	_area = area_m2
	_cfg = cfg
	name = "SkyShade"
	if _decal != null:
		return
	_img = Image.create_empty(TEX_N, TEX_N, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	_bytes.resize(TEX_N * TEX_N * 4)
	_bytes.fill(0)
	_decal = Decal.new()
	_decal.name = "Decal"
	_decal.texture_albedo = _tex
	_decal.albedo_mix = 1.0
	# Forward+: ослабление pow(1 − |y_local|, fade). Нижний 0 — земля (на y_local ≈ −0,6) темнеет ровно
	# на darkening(); верхний ≈ 0 — вершины травы (до 0,9 м) не слабее земли. Мягкий край — в текстуре.
	_decal.upper_fade = 0.1
	_decal.lower_fade = 0.0
	_decal.normal_fade = 0.0
	_decal.cull_mask = 0xFFFFF
	_decal.layers = 1
	_decal.visible = false
	add_child(_decal)


## Радиус эквивалентного диска, м.
static func disc_radius(area_m2: float) -> float:
	return sqrt(area_m2 / PI)


## Фактор видимости диска радиуса R с центром на высоте h над точкой земли на горизонтальном
## расстоянии r от оси диска: ½·(1 − (h²+r²−R²)/√((h²+r²+R²)² − 4r²R²)).
static func view_factor(r: float, h: float, radius: float) -> float:
	var h2 := h * h
	var r2 := r * r
	var r_sq := radius * radius
	var s := h2 + r2 + r_sq
	var d := sqrt(maxf(s * s - 4.0 * r2 * r_sq, 1e-12))
	return clampf(0.5 * (1.0 - (h2 + r2 - r_sq) / d), 0.0, 1.0)


## Контракт PH-К7: доля, на которую темнеет освещённость земли в точке на расстоянии r от центра
## пятна при высоте крыла h. cfg: gain, sky_share (доля рассеянного света неба, 0..1), h_max_m.
## Выше h_max пятно плавно (от 0,6·h_max) уходит в ноль.
static func darkening(r_m: float, h_m: float, area_m2: float, cfg: Dictionary) -> float:
	var h_max := float(cfg.get("h_max_m", 12.0))
	if h_m >= h_max:
		return 0.0
	var h := maxf(h_m, 0.05)
	var gain := clampf(float(cfg.get("gain", 1.6)), 1.0, 2.0)
	var share := clampf(float(cfg.get("sky_share", 0.3)), 0.0, 1.0)
	var fade := 1.0 - smoothstep(0.6 * h_max, h_max, h_m)
	return clampf(gain * share * view_factor(absf(r_m), h, disc_radius(area_m2)) * fade, 0.0, 1.0)


## Доля рассеянного света неба в освещённости земли (физическая оценка, без яркости сцены игры):
## ясно — диффузная доля ≈ clear_noon (0,12–0,2 при высоком солнце), растёт к горизонту как
## clear_noon + clear_low_k·(1 − sin h)²; облачность cover (0..1, пелена прогноза) смешивает её
## к overcast_share (пасмурно почти весь свет рассеянный, ≈ 0,9) по cover/overcast_cover.
static func share_from_weather(sin_elev: float, cover: float, cfg: Dictionary) -> float:
	var clear := float(cfg.get("clear_noon", 0.15))
	var low := float(cfg.get("clear_low_k", 0.35))
	var k := 1.0 - clampf(sin_elev, 0.0, 1.0)
	var clear_share := clear + low * k * k
	var over := float(cfg.get("overcast_share", 0.9))
	var t := clampf(cover / maxf(float(cfg.get("overcast_cover", 0.85)), 1e-3), 0.0, 1.0)
	return clampf(lerpf(clear_share, over, t), 0.0, over)


## Параметры пятна при высоте h: смещение центра вперёд (к виду пилота, ≤ h), полуразмер декали.
func shift_m(h: float) -> float:
	return clampf(float(_cfg.get("shift_k", 0.5)), 0.0, 1.0) * h


func half_extent_m(h: float) -> float:
	var stretch := maxf(float(_cfg.get("stretch", 1.3)), 1.0)
	return minf((1.8 * disc_radius(_area) + 0.3 * h) * stretch + shift_m(h), MAX_HALF_M)


func _cfg_share() -> float:
	var fixed := float(_cfg.get("sky_share", -1.0))
	if fixed >= 0.0:
		return fixed
	return _share


func _ground(x: float, z: float) -> float:
	if ground_fn.is_valid():
		return float(ground_fn.call(x, z))
	var g := _find_glider()
	if g != null and g.ground_fn.is_valid():
		return float(g.ground_fn.call(x, z))
	return -INF


func _find_glider() -> Glider:
	var n := get_parent()
	while n != null:
		if n is Glider:
			return n as Glider
		n = n.get_parent()
	return null


func _update_share(dt: float) -> void:
	_share_t -= dt
	if _share_t > 0.0:
		return
	_share_t = 0.5
	var sin_el := 1.0
	var cover := 0.0
	if env_fn.is_valid():
		var e: Vector2 = env_fn.call()
		sin_el = e.x
		cover = e.y
	_share = share_from_weather(sin_el, cover, _cfg)


## Центр паруса в осях визуала: середина AABB Sail (иначе узел Wing).
func _find_center(vis: Node3D) -> void:
	_center_ready = true
	var wing := vis.find_child("Wing", false, false) as Node3D
	var sail := vis.find_child("Sail", true, false) as MeshInstance3D
	if sail != null and sail.mesh != null:
		var c := sail.mesh.get_aabb().get_center()
		_center_local = vis.global_transform.affine_inverse() * (sail.global_transform * c)
	elif wing != null:
		_center_local = vis.to_local(wing.global_position)


func _process(dt: float) -> void:
	if _decal == null:
		return
	var vis := get_parent() as Node3D
	if vis == null or not vis.is_inside_tree():
		return
	if not _center_ready:
		_find_center(vis)
	var xf := vis.global_transform
	var c: Vector3 = xf * _center_local
	var g := _ground(c.x, c.z)
	var h_max := float(_cfg.get("h_max_m", 12.0))
	if g == -INF or c.y - g >= h_max:
		_decal.visible = false
		return
	var h := maxf(c.y - g, 0.05)
	last_h = h
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 1e-3 else Vector3.FORWARD
	var s := shift_m(h)
	var px := c.x + fwd.x * s
	var pz := c.z + fwd.z * s
	var pg := _ground(px, pz)
	if pg == -INF:
		_decal.visible = false
		return
	# нормаль рельефа по разностям — декаль ложится вдоль склона
	var e := 1.5
	var n := Vector3(
		_ground(px - e, pz) - _ground(px + e, pz), 2.0 * e, _ground(px, pz - e) - _ground(px, pz + e)
	).normalized()
	var f_t := (fwd - n * fwd.dot(n)).normalized()
	var right := f_t.cross(n).normalized()
	var he := half_extent_m(h)
	var vert := float(_cfg.get("vertical_m", 1.8))
	var lift := vert * float(_cfg.get("vertical_lift", 0.3))
	_decal.global_transform = Transform3D(Basis(right, n, -f_t), Vector3(px, pg, pz) + n * lift)
	_decal.size = Vector3(2.0 * he, vert, 2.0 * he)
	_update_share(dt)
	var share := _cfg_share()
	last_share = share
	_bake_t -= dt
	# пересчёт текстуры при заметном изменении h/доли неба (не чаще bake_hz); курс не нужен —
	# текстура в осях декали
	if (
		_baked_h < 0.0
		or (
			_bake_t <= 0.0
			and (absf(h - _baked_h) > 0.02 * h or absf(share - _baked_share) > 0.02)
		)
	):
		_bake(h, share, he)
	_decal.visible = true


func _bake(h: float, share: float, he: float) -> void:
	_bake_t = 1.0 / maxf(float(_cfg.get("bake_hz", 10.0)), 1.0)
	_baked_h = h
	_baked_share = share
	bakes += 1
	var c := {
		"gain": _cfg.get("gain", 1.6), "sky_share": share, "h_max_m": _cfg.get("h_max_m", 12.0)
	}
	var stretch := maxf(float(_cfg.get("stretch", 1.3)), 1.0)
	var bytes := _bytes
	var px := 2.0 * he / TEX_N
	# F зависит только от расстояния до центра: радиальная таблица (LUT), пиксели — по ней
	var r_max := he * 1.4143
	var lut := PackedByteArray()
	lut.resize(LUT_N + 1)
	for k in LUT_N + 1:
		lut[k] = int(roundf(clampf(darkening(r_max * k / LUT_N, h, _area, c), 0.0, 1.0) * 255.0))
	var k_scale := LUT_N / r_max
	var inv_he := 1.0 / he
	for j in TEX_N:
		var a := ((float(j) + 0.5) * px - he) / stretch  # вдоль курса (с учётом вытяжки)
		var row := j * TEX_N * 4 + 3
		for i in TEX_N:
			var x := (float(i) + 0.5) * px - he
			# край текстуры — в ноль, чтобы декаль не оставляла границы
			var edge := 1.0 - smoothstep(0.8, 1.0, maxf(absf(x), absf(a * stretch)) * inv_he)
			bytes[row + i * 4] = int(lut[int(sqrt(x * x + a * a) * k_scale)] * edge)
	_img.set_data(TEX_N, TEX_N, false, Image.FORMAT_RGBA8, bytes)
	_tex.update(_img)
