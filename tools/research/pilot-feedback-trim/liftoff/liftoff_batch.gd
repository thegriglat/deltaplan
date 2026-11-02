extends Node
## PFT-4: переход «ноги -> подвеска» после отрыва. Разбег по склону, отрыв, ряд с шагом 1/120 (от -T0 до +T1 от отрыва).
## Варианты подменяются в СВОЕЙ копии сценария через публичные поля модели (код игры не правится):
##   --alpha_neutral=<deg>  ground.alpha_neutral (нейтраль на разбеге); "trim" = alpha_trim_deg паспорта
##   --bar_after=<s>        _bar_after (руки на штангу через столько после отрыва); --upright_clear=<m>
##   --mode=launch | air (старт в воздухе с V=--v0 км/ч и тримовой ориентацией, для эталона фугоиды)
##   --handoff=1  зафиксировать пилота на руках (arms.neutral) до перехода: не используется
## godot --headless --path . res://tools/research/pilot-feedback-trim/liftoff/liftoff_batch.tscn -- --wings=sport --out=x.json
const DT := 1.0 / 120.0
var _a := {"wings": "sport", "slope": "12", "out": "", "pre": "2", "post": "20", "mass": "game", "mode": "launch", "v0": "0",
	"alpha_neutral": "", "bar_after": "", "upright_clear": "", "pitch": "0", "every": "1", "th0": "", "tag": ""}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and s.contains("="):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1]
	var res := {"args": _a, "wings": {}}
	for w in String(_a.wings).split(","):
		res.wings[w] = _launch(w) if _a.mode == "launch" else _air(w)
	var f := FileAccess.open(String(_a.out), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "", false))
	f.close()
	get_tree().quit(0)


func _model(w: String) -> PendulumModel:
	var wing: Dictionary = Config.get_config("wings/" + w).duplicate(true)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	var mass := float(pilot.mass_kg)
	if _a.mass == "ref":
		mass = float(wing.pilot_mass_ref_kg)
	pilot.mass_kg = clampf(mass, float(wing.pilot_mass_min_kg), float(wing.pilot_mass_max_kg))
	var m := PendulumModel.new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": false}}, {})
	return m


func _row(m: PendulumModel, t: float) -> Array:
	var Rt := m._R.transposed()
	var q: float = (Rt * m._w).y
	var vh := Vector2(m.velocity.x, m.velocity.z).length()
	var gam := atan2(-m.velocity.y, vh)
	var rel := m.pilot_rel
	return [snappedf(t, 0.0001), snappedf(m.telemetry.airspeed * 3.6, 0.001), snappedf(rad_to_deg(m.theta), 0.001),
		snappedf(rad_to_deg(m.alpha), 0.001), snappedf(rad_to_deg(gam), 0.001), snappedf(rad_to_deg(q), 0.001),
		1 if m._uprights else 0, snappedf(m.ground.agl(m.chain.pilot()) - m._leg_len, 0.001),
		snappedf(rel.x, 0.0001), snappedf(rel.y, 0.0001), snappedf(rel.z, 0.0001),
		snappedf(m.pilot_shift.y, 0.001), snappedf(m.bar_force_wing.y, 0.01), snappedf(m.bar_force_wing.x, 0.01),
		snappedf(m._aero_m_b.y, 0.01), snappedf(m.strap_tension, 0.1), snappedf(m.velocity.y, 0.001),
		1 if m.ground.running else 0, 1 if m.ground.contact else 0, snappedf(m.stall_amount(), 0.001)]
const COLS := ["t", "V_kmh", "theta", "alpha", "gamma", "q_dps", "uprights", "feet_agl", "rel_x", "rel_y", "rel_z", "shift_y",
	"bar_fy", "bar_fx", "aero_My", "strap_N", "vz", "running", "contact", "stall"]


func _launch(w: String) -> Dictionary:
	var res := {}
	var wing: Dictionary = Config.get_config("wings/" + w)
	for slope in String(_a.slope).split(","):
		var k := tan(deg_to_rad(float(slope)))
		var gf := func(_x: float, z: float) -> float: return 1000.0 + k * z
		var af := func(_p: Vector3) -> Vector3: return Vector3.ZERO
		var m := _model(w)
		m.reset_on_ground(Vector3.ZERO, 0.0)
		if _a.alpha_neutral == "trim":
			m.ground.alpha_neutral = deg_to_rad(float(wing.pendulum.ref.alpha_trim_deg))
		elif _a.alpha_neutral != "":
			m.ground.alpha_neutral = deg_to_rad(float(_a.alpha_neutral))
		if _a.bar_after != "":
			m._bar_after = float(_a.bar_after)
		if _a.upright_clear != "":
			m._upright_clear = float(_a.upright_clear)
		var inp := ControlInput.new()
		inp.run = true
		inp.pitch = float(_a.pitch)
		var t_lo := -1.0
		var t_bar := -1.0
		var buf: Array = []  # кольцевой буфер до отрыва
		var ser: Array = []
		var n := 0
		var pre := float(_a.pre)
		var post := float(_a.post)
		var every := int(_a.every)
		var ext := {}
		while m.time_s < 80.0:
			m.step(DT, inp, af, gf)
			n += 1
			var landed_air := m.mode == FlightModel.Mode.AIR
			if t_lo < 0.0 and landed_air:
				t_lo = m.time_s
				ext["state_at_liftoff"] = _row(m, 0.0)
			if t_lo >= 0.0 and t_bar < 0.0 and not m._uprights:
				t_bar = m.time_s
				ext["state_at_bar"] = _row(m, m.time_s - t_lo)
			var t_rel := m.time_s - (t_lo if t_lo >= 0.0 else m.time_s + 1.0e9)
			if t_lo < 0.0:
				if n % every == 0:
					buf.append(_row(m, m.time_s))
					if buf.size() > int(pre / DT / every) + 2:
						buf.pop_front()
			else:
				if n % every == 0:
					ser.append(_row(m, t_rel))
				if t_rel > post:
					break
		for r in buf:
			r[0] = snappedf(r[0] - t_lo, 0.0001)
		res[slope] = {"cols": COLS, "t_liftoff": t_lo, "t_bar_after": t_bar - t_lo if t_bar > 0.0 else -1.0, "pre": buf,
			"series": ser, "ext": ext, "alpha_neutral_deg": rad_to_deg(m.ground.alpha_neutral),
			"alpha_trim_deg": float(wing.pendulum.ref.alpha_trim_deg), "mass": m.pilot_mass, "phase_end": m.phase()}
	return res


## Эталон физики: старт в воздухе (reset_in_air) с воздушной скоростью v0 (км/ч) на тримовой ориентации, ввод 0.
func _air(w: String) -> Dictionary:
	var m := _model(w)
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0, float(_a.v0) / 3.6)
	var inp := ControlInput.new()
	var ser: Array = []
	var T := float(_a.post)
	for i in int(T / DT):
		m.step(DT, inp, Callable(), Callable())
		if i % int(_a.every) == 0:
			ser.append(_row(m, m.time_s))
	return {"cols": COLS, "series": ser}
