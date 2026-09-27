class_name StormField
extends RefCounted
## Кучево-дождевые облака (Cb) — опасная погода (VR-26):
## - ливневый нисходящий поток под облаком (до −W на высоте, у земли поворачивает в горизонталь);
## - растекающийся у земли порывистый поток (outflow) с фронтом порывов, который уходит от
##   облака на несколько километров; на фронте — подъём и сильная болтанка;
## - сильный подсос под основанием задаётся в самом термике (AtmoThermal.suck).
## Стадия бури начинается в середине зрелой стадии термика-Cb и гаснет после его конца.

var cells: Array[AtmoThermal] = []

var _dd_w: float = 6.0
var _dd_r_frac: float = 0.5
var _dd_ground_m: float = 300.0
var _out_u: float = 12.0
var _out_h: float = 600.0
var _front_v: float = 8.0
var _front_max: float = 12000.0
var _front_width: float = 800.0
var _front_w: float = 2.0
var _turb_k: float = 0.35
var _start_frac: float = 0.4
var _ramp_s: float = 300.0
var _linger_s: float = 900.0
var _cloud_w_per_ms: float = 500.0


func setup(storm_cfg: Dictionary, cloud_width_per_ms: float) -> void:
	_dd_w = float(storm_cfg.downdraft_ms)
	_dd_r_frac = float(storm_cfg.downdraft_radius_frac)
	_dd_ground_m = float(storm_cfg.downdraft_turn_height_m)
	_out_u = float(storm_cfg.outflow_ms)
	_out_h = float(storm_cfg.outflow_depth_m)
	_front_v = float(storm_cfg.front_speed_ms)
	_front_max = float(storm_cfg.front_max_radius_m)
	_front_width = float(storm_cfg.front_width_m)
	_front_w = float(storm_cfg.front_updraft_ms)
	_turb_k = float(storm_cfg.turbulence_per_outflow)
	_start_frac = float(storm_cfg.start_mature_frac)
	_ramp_s = float(storm_cfg.ramp_s)
	_linger_s = float(storm_cfg.linger_s)
	_cloud_w_per_ms = cloud_width_per_ms


## Обновить список ячеек из термиков (после ThermalField.refresh).
func refresh(thermals: Dictionary) -> void:
	cells.clear()
	for id in thermals:
		var th: AtmoThermal = thermals[id]
		if th.is_cb:
			cells.append(th)


## Начало стадии бури (ливень, нисходящий поток), с.
func storm_start(th: AtmoThermal) -> float:
	return th.t_birth + th.t_grow + th.t_mature * _start_frac


## Сила бури 0..1 в момент t.
func intensity(th: AtmoThermal, t: float) -> float:
	var s0 := storm_start(th)
	var s1 := th.t_end() + _linger_s
	return smoothstep(s0, s0 + _ramp_s, t) * (1.0 - smoothstep(s1 - _ramp_s, s1, t))


## Радиус нисходящего потока (ливня), м.
func downdraft_radius(th: AtmoThermal) -> float:
	return _cloud_w_per_ms * th.strength * 0.5 * _dd_r_frac


## Радиус фронта порывов в момент t, м.
func front_radius(th: AtmoThermal, t: float) -> float:
	var r0 := downdraft_radius(th)
	return minf(r0 + _front_v * maxf(0.0, t - storm_start(th)), _front_max)


## Вклад бурь в точке: Vector4(ветер x, вертикаль, ветер z, σ болтанки).
func sample(pos: Vector3, agl: float, t: float) -> Vector4:
	var out := Vector4.ZERO
	for th in cells:
		var e := intensity(th, t)
		if e <= 0.0:
			continue
		var c := th.cloud_center(t)
		var dx := pos.x - c.x
		var dz := pos.z - c.y
		var r2 := dx * dx + dz * dz
		var rf := front_radius(th, t)
		var reach := rf + _front_width * 2.0
		if r2 > reach * reach:
			continue
		var r := sqrt(r2)
		var rd := downdraft_radius(th)
		# Нисходящий поток: под основанием, у земли поворачивает в стороны.
		if pos.y < th.top:
			var dd := exp(-(r * r) / (rd * rd)) * smoothstep(0.0, _dd_ground_m, agl)
			out.y -= _dd_w * e * dd
		# Растекание у земли: радиально от центра, до фронта; слой толщиной ~_out_h.
		var prof := exp(-agl / _out_h)
		var radial := minf(r / rd, 1.0) * (1.0 - smoothstep(rf - _front_width, rf, r))
		var u := _out_u * e * prof * radial
		if r > 1.0:
			out.x += dx / r * u
			out.z += dz / r * u
		# Фронт порывов: подъём тёплого воздуха над «языком» холодного и болтанка.
		var fr := (r - rf) / _front_width
		var front := exp(-fr * fr)
		out.y += _front_w * e * front * smoothstep(0.0, 150.0, agl) * exp(-agl / 1500.0)
		out.w = maxf(out.w, _turb_k * _out_u * e * (front + 0.5 * radial) * prof)
	return out
