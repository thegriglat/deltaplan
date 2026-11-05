class_name CloudWhiteout
extends RefCounted
## «Белая мгла» в облаке: по плотности облака у камеры сгущает туман окружения (Environment)
## и красит его в белый — горизонт теряется, видно только ближнее (прибор на трапеции).
## Параметры — configs/game.json → cloud_whiteout. Логика без нод — тестируется headless.

var amount: float = 0.0  ## 0 — ясно, 1 — полная мгла

var _cfg: Dictionary = {}
var _base := {}  ## исходные параметры тумана Environment


func setup(cfg: Dictionary) -> void:
	_cfg = cfg


## Шаг: density — плотность облака у камеры 0..1 (Atmosphere.cloud_density_at).
func update(density: float, dt: float) -> float:
	var want := clampf(density * float(_cfg.get("density_gain", 1.5)), 0.0, 1.0)
	var tau := float(_cfg.get("rise_time_s", 0.3))
	amount = lerpf(amount, want, 1.0 if tau <= 0.0 else 1.0 - exp(-dt / tau))
	if amount < 1e-4:
		amount = 0.0
	return amount


## Применить к окружению (запоминает исходный туман при первом вызове и возвращает его при 0).
func apply(env: Environment) -> void:
	if env == null:
		return
	if _base.is_empty() or _base.env != env:
		_base = {
			"env": env,
			"enabled": env.fog_enabled,
			"density": env.fog_density,
			"color": env.fog_light_color,
			"sky": env.fog_sky_affect,
			"height_density": env.fog_height_density,
			"mode": env.fog_mode,
			"depth_begin": env.fog_depth_begin,
			"depth_end": env.fog_depth_end,
			"depth_curve": env.fog_depth_curve,
		}
	var a := amount
	if a <= 0.0:
		# Мглы нет: исходные параметры побитно, метаданных для облаков нет (CVW-К2 v2).
		env.fog_enabled = _base.enabled
		env.fog_mode = _base.mode
		env.fog_density = _base.density
		env.fog_light_color = _base.color
		env.fog_sky_affect = _base.sky
		env.fog_height_density = _base.height_density
		env.fog_depth_begin = _base.depth_begin
		env.fog_depth_end = _base.depth_end
		env.fog_depth_curve = _base.depth_curve
		for k in ["fog_base", "whiteout_veil"]:
			if env.has_meta(k):
				env.remove_meta(k)
		return
	var c: Array = _cfg.get("color", [0.86, 0.88, 0.9])
	var white := Color(float(c[0]), float(c[1]), float(c[2]))
	# Вид вуали v(amount) = amount: доля вуали на облаках и на небе линейна по плотности облака
	# у камеры; непрерывна, v(0) = 0, v(1) = 1.
	var v := clampf(a, 0.0, 1.0)
	# Туман Godot на небе не зависит от расстояния и насыщается при любой плотности > 0, поэтому
	# долю тумана на небе ведём по v от исходной (0, если исходный туман выключен).
	var s0 := float(_base.sky) if bool(_base.enabled) else 0.0
	# Рельеф: туман глубины, доля на расстоянии d — F(d) = v · c(d / L) ≤ v (Бер–Ламберт с
	# видимостью L), а не экспонента, насыщающая дальний рельеф при любой плотности (CVW-К2 v3).
	var vis := visibility_m()
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = v
	env.fog_depth_begin = 0.0
	env.fog_depth_end = vis
	env.fog_depth_curve = depth_curve()
	env.fog_light_color = (_base.color as Color).lerp(white, a)
	env.fog_sky_affect = lerpf(s0, 1.0, v)
	env.fog_height_density = lerpf(float(_base.height_density), 0.0, a)
	# Стык с облаками (cloud_layer.gd): их дымка — из тумана до мглы, мгла — вуалью по v.
	env.set_meta(
		"fog_base",
		{
			"enabled": _base.enabled,
			"density": _base.density,
			"color": _base.color,
			"sky_affect": _base.sky,
		}
	)
	env.set_meta("whiteout_veil", {"v": v, "color": white})


## Видимость внутри облака L, м: configs/game.json → cloud_whiteout.visibility_m
## (Кошмидер: 3,9 / σ); без ключа — из плотности fog_density (σ) v1.
func visibility_m() -> float:
	if _cfg.has("visibility_m"):
		return maxf(float(_cfg.visibility_m), 1.0)
	return 3.9 / maxf(float(_cfg.get("fog_density", 0.06)), 1e-6)


static var _curve_cache := -1.0


## Показатель fog_depth_curve: Godot считает долю как smoothstep(begin, end, d)^curve · fog_density;
## показатель подобран (наименьшие квадраты на x = d/L ∈ (0, 1]) под форму Бера–Ламберта 1 − exp(−3x).
static func depth_curve() -> float:
	if _curve_cache > 0.0:
		return _curve_cache
	var best := 1.0
	var best_err := INF
	for k in range(20, 201):
		var p := k * 0.005
		var err := 0.0
		for i in range(1, 101):
			var x := i / 100.0
			err += pow(pow(smoothstep(0.0, 1.0, x), p) - (1.0 - exp(-3.0 * x)), 2.0)
		if err < best_err:
			best_err = err
			best = p
	_curve_cache = best
	return best


## Доля тумана на расстоянии d при текущих параметрах env (режим DEPTH Godot).
static func depth_fraction(env: Environment, d: float) -> float:
	return pow(smoothstep(env.fog_depth_begin, env.fog_depth_end, d), env.fog_depth_curve) * env.fog_density
