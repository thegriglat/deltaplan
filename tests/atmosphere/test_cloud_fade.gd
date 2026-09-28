extends TestCase
## Облака уходят из отрисовки только плавно (тают), а не выключаются за кадр: конец жизни
## (linger), слияние наложившихся, лимит max_clouds, предел дальности, удаление термика из поля.
## Видимость облака — CloudLayer: запись [20] (плотность × видимость в шейдере).

## Больше этого за 1 с атмосферы видимость облака не меняется (скачок — это «пропало»).
const MAX_STEP_PER_S := 0.1
## Облако с видимостью выше этой считаем заметным.
const VISIBLE := 0.02


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(x: float, z: float) -> float:
	return 0.75 + 0.25 * sin(x / 1300.0) * cos(z / 1700.0)


func _model() -> CloudModel:
	var m := CloudModel.new()
	m.setup(Config.get_config("atmosphere").clouds)
	return m


func _thermal() -> AtmoThermal:
	var th := AtmoThermal.new()
	th.id = 11
	th.top = 1800.0
	th.strength = 3.0
	th.t_grow = 200.0
	th.t_mature = 600.0
	th.t_decay = 200.0
	th.has_cloud = true
	th.cloud_depth = 700.0
	return th


## Конец жизни: к моменту, когда стадии облака больше нет, видимость уже ноль; по дороге —
## без скачков. Раньше на распаде оставалось ~20 % плотности, и облако выключалось целиком.
func test_life_fade_reaches_zero_before_cloud_ends() -> void:
	var m := _model()
	var th := _thermal()
	var prev := 0.0
	var max_jump := 0.0
	var last_alive := -1.0
	for i in 3000:
		var t := float(i)
		var alive := m.stage(th, t).x >= 0.0
		var v := m.life_fade(th, t) if alive else 0.0
		max_jump = maxf(max_jump, absf(v - prev))
		if alive:
			last_alive = t
		prev = v
	check(last_alive > 1000.0, "облако жило до конца термика и linger: %.0f с" % last_alive)
	check(max_jump < MAX_STEP_PER_S * 0.5, "видимость по жизни без скачков: %.3f/с" % max_jump)
	check(m.life_fade(th, last_alive) < 0.01, "в последнюю секунду облако почти растаяло")
	check(m.life_fade(th, 700.0) > 0.99, "зрелое облако видно полностью")


## Предел дальности: облако тает в полосе fade_band_m, у самой границы — ноль.
func test_range_fade_is_smooth_to_zero() -> void:
	var m := _model()
	var far := 25000.0
	approx(m.range_fade(far, far), 0.0, 1e-6, "на границе дальности не видно")
	approx(m.range_fade(far - 3000.0, far), 1.0, 1e-6, "до полосы таяния видно полностью")
	var prev := 1.0
	for d in range(20000, 25001, 10):
		var v := m.range_fade(float(d), far)
		check(absf(v - prev) < 0.01, "без скачка на %d м" % d)
		prev = v


## Выбывшее облако тает fade_out_s, выбранное проявляется fade_in_s — шагами без скачков.
func test_step_fade_is_gradual() -> void:
	var m := _model()
	var cfg: Dictionary = Config.get_config("atmosphere").clouds
	var out_s := float(cfg.fade_out_s)
	var in_s := float(cfg.fade_in_s)
	check(out_s >= 30.0 and out_s <= 90.0, "таяние 30–90 с: %.0f" % out_s)
	check(in_s >= 20.0 and in_s <= 90.0, "проявление 20–90 с: %.0f" % in_s)
	var v := 1.0
	var n := 0
	while v > 0.0 and n < 1000:
		var nv := m.step_fade(v, 0.0, 1.0)
		check(v - nv <= 1.0 / out_s + 1e-6, "шаг таяния не больше 1/fade_out_s")
		v = nv
		n += 1
	approx(float(n), out_s, 1.0, "растаяло за fade_out_s")
	approx(m.step_fade(0.0, 1.0, in_s), 1.0, 1e-6, "проявилось за fade_in_s")


## Обрезка по max_clouds: уже нарисованное облако чуть дальше не вытесняется новым чуть ближе.
func test_cap_prefers_shown() -> void:
	var cfg: Dictionary = Config.get_config("atmosphere").clouds.duplicate()
	cfg.max_clouds = 1
	var m := CloudModel.new()
	m.setup(cfg)
	var ths: Dictionary = {}
	for k in 2:
		var th := AtmoThermal.new()
		th.id = 100 + k
		th.is_static = true
		th.has_cloud = true
		th.strength = 3.0
		th.cloud_depth = 700.0
		th.top = 1500.0
		th.src = Vector3(8000.0 + k * 400.0, 0.0, (k * 2 - 1) * 5000.0)
		ths[th.id] = th
	var near: Array = m.select(ths, 0.0, Vector3.ZERO)
	check(near.size() == 1 and (near[0][1] as AtmoThermal).id == 100, "без истории — ближнее")
	var keep: Array = m.select(ths, 0.0, Vector3.ZERO, {101: true})
	check(
		keep.size() == 1 and (keep[0][1] as AtmoThermal).id == 101,
		"нарисованное остаётся при почти равной дальности"
	)


## Короткий полёт (3 мин атмосферы, medium; лимит облаков урезан, чтобы работала обрезка):
## ни одно видимое облако не пропадает скачком и не появляется сразу плотным.
## (Длинный 20-минутный прогон убран по просьбе пользователя — долго.)
func test_no_instant_disappearance_in_flight() -> void:
	var r := _fly("weather/medium", 180)
	check(r.events.is_empty(), "мгновенные исчезновения/появления: %s" % [r.events])
	check(int(r.max_vis) > 0, "облака рисовались")


func _fly(weather: String, seconds: int) -> Dictionary:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config(weather), {"wind_speed_kmh": 15.0})
	var acfg := Config.get_config("atmosphere").duplicate(true)
	acfg.clouds.max_clouds = 40
	a.configure(acfg, w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	a.time_s = 3600.0
	var pos := Vector3(0, 1200, 0)
	a.set_focus(pos)
	a.step(0.0)
	var layer := CloudLayer.new()
	layer.setup(a)
	var prev: Dictionary = {}
	var events: Array = []
	var faded := 0
	var max_vis := 0
	var vel := Vector3(18.0, 0.0, 6.0)
	for s in seconds:
		pos += vel
		a.set_focus(pos)
		a.step(1.0)
		var t := a.time_s
		layer._select(t, pos)
		for i in layer._slot_th.size():
			if layer._slot_th[i] != null:
				layer._place(i, t, pos)
		layer._update_fades(1.0)
		var cur: Dictionary = {}
		for i in layer._slot_th.size():
			var th: AtmoThermal = layer._slot_th[i]
			if th != null and not layer._rec[i].is_empty():
				cur[th.id] = layer._rec[i][20]
		for id in prev:
			var v0 := float(prev[id])
			var v1 := float(cur.get(id, 0.0))
			if v0 > VISIBLE and v0 - v1 > MAX_STEP_PER_S:
				events.append("t=%d id=%d %.2f→%.2f" % [s, id, v0, v1])
			elif v0 > VISIBLE and not cur.has(id):
				events.append("t=%d id=%d %.2f→нет" % [s, id, v0])
		for id in cur:
			var v2 := float(cur[id])
			if s > 0 and v2 - float(prev.get(id, 0.0)) > MAX_STEP_PER_S:
				events.append("t=%d id=%d появилось %.2f" % [s, id, v2])
			if prev.has(id) and v2 < float(prev[id]):
				faded += 1
		max_vis = maxi(max_vis, cur.size())
		prev = cur
		if events.size() > 10:
			break
	layer.free()
	a.free()
	return {"events": events, "faded": faded, "max_vis": max_vis}
