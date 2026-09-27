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
	var c: Array = _cfg.get("color", [0.86, 0.88, 0.9])
	var white := Color(float(c[0]), float(c[1]), float(c[2]))
	env.fog_enabled = bool(_base.enabled) or a > 0.0
	env.fog_density = lerpf(float(_base.density), float(_cfg.get("fog_density", 0.06)), a)
	env.fog_light_color = (_base.color as Color).lerp(white, a)
	env.fog_sky_affect = lerpf(float(_base.sky), 1.0, a)
	env.fog_height_density = lerpf(float(_base.height_density), 0.0, a)
