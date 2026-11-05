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
		}
	var a := amount
	if a <= 0.0:
		# Мглы нет: исходные параметры побитно, метаданных для облаков нет (CVW-К2 v2).
		env.fog_enabled = _base.enabled
		env.fog_density = _base.density
		env.fog_light_color = _base.color
		env.fog_sky_affect = _base.sky
		env.fog_height_density = _base.height_density
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
	env.fog_enabled = true
	env.fog_density = _fog_density(float(_base.density), float(_cfg.get("fog_density", 0.06)), a)
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


## Плотность тумана: геометрическая (логарифмическая) интерполяция от исходной к плотности мглы.
## Линейная по amount давала на рельефе в километрах ступеньку: при a = 0,007 и 0,06 1/м
## 1 − exp(−4e-4 · 5000 м) ≈ 0,86 — даль заливается цветом тумана уже на кромке слоя.
## Геометрическая плотность растёт плавно (в e раз на равные шаги amount), при a = 1 равна
## плотности мглы (видимость как в v1); исходная плотность 0 (туман выключен) заменяется на
## fog_density_floor — иначе логарифм не определён; это 1e-6 1/м, т.е. 1 000 км видимости.
func _fog_density(base: float, full: float, a: float) -> float:
	var floor_d := float(_cfg.get("fog_density_floor", 1e-6))
	var b := maxf(base, floor_d)
	if full <= b:
		return lerpf(base, full, a)
	# К a = 1 кривая сводится к full: вес a^8 дотягивает густоту до плотности мглы уже около a ≈ 0,95
	# (чистая геометрическая даёт там ~0,03), в окне малых amount вес < 1e-5.
	var geo := lerpf(b * pow(full / b, a), full, pow(a, 8.0))
	# База ниже порога (туман выключен): первые 2 % amount плавно поднимают 0 до геометрической кривой.
	return geo if base >= b else lerpf(base, geo, minf(a * 50.0, 1.0))
