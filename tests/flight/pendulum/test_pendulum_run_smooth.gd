extends Node
## Разбег без подскоков (PD-36, отзыв по 1.5.5: «моделька скачет при разбеге»): на разбеге по склону 15° (штиль и
## встречный 3 м/с, «Маятник») ЦМ пилота в физике и таз нарисованного пилота не подпрыгивают. Причина была в
## анимации run (assets/models/pilot.glb): нижняя стопа всегда на земле, при размахе бедра 38° и сгибе колена 80°
## таз ходил на 0,45 м дважды за цикл; теперь таз на постоянной высоте, ноги — IK (tools/blender/build_pilot.py).
## Подскок — отклонение высоты над склоном от скользящего среднего за 0,5 с (медленный тренд не в счёт).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const M := preload("res://tests/flight/pendulum/test_pendulum_mode.gd")
const DT := 1.0 / 120.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## → ряд кадров 60 Гц: высоты над склоном (м) модели и визуала.
func run_trace(slope_deg: float, wind: float, tmax := 3.4) -> Array:
	var k := tan(deg_to_rad(slope_deg))
	var g: Glider = M.make_glider("pendulum", "training")
	g.set_ground_fn(func(_x: float, z: float) -> float: return k * z)
	var a := deg_to_rad(slope_deg)
	var wv := Vector3(0.0, wind * sin(a), -wind * cos(a)) * -1.0
	wv = Vector3(0.0, wind * sin(a), wind * cos(a))
	g.set_air_fn(func(_p: Vector3) -> Vector3: return wv)
	add_child(g)
	g.set_process(false)
	g.set_physics_process(false)
	g.reset_on_ground(Vector3.ZERO, 0.0)
	var an := PilotAnimator.new()
	an.bind(g.visual, Config.get_config("game").get("pilot_animation", {}))
	an.player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var sk: Skeleton3D = g.visual._skeleton
	var rows := []
	var t := 0.0
	var n := 0
	while t < tmax and g.model.mode == FlightModel.Mode.GROUND:
		g.control.run = t > 1.0 - 1.0e-9
		g.step(DT)
		t += DT
		n += 1
		if n % 2 != 0:
			continue
		g.global_transform = g._cur_xform
		an.update(g.model.telemetry.phase, g.model.telemetry.altitude_agl, 0.0, 0.0, 2.0 * DT)
		an.player.advance(2.0 * DT)
		g._update_pilot(2.0 * DT)
		sk.force_update_all_bone_transforms()
		var v: GliderVisual = g.visual
		var gt := sk.global_transform
		var hips := gt * sk.get_bone_global_pose(sk.find_bone("Hips")).origin
		var fl := gt * sk.get_bone_global_pose(sk.find_bone("Foot.L")).origin
		var fr := gt * sk.get_bone_global_pose(sk.find_bone("Foot.R")).origin
		var head := v.head_marker.global_position
		var gf := v.global_transform * v.ground_feet()
		var m: PendulumModel = g.model
		var c := func(p: Vector3) -> float: return p.y - k * p.z
		rows.append({
			"t": t, "phase": m.telemetry.phase, "anim": an.current(), "ph": an.player.current_animation_position,
			"cm": c.call(m.pilot_position), "hips": c.call(hips), "head": c.call(head),
			"fmin": minf(c.call(fl), c.call(fr)), "gfeet": c.call(gf),
			"pfeet": c.call(m.pilot_position - m.pilot_basis.y), "th": rad_to_deg(m.theta),
			"rel": m.pilot_rel,
		})
	g.queue_free()
	return rows


## Размах (макс − мин) отклонения ряда key от скользящего среднего за win кадров, м; кадры t ∈ [t0, t1].
static func jitter(rows: Array, key: String, win: int, t0: float, t1: float) -> float:
	var lo := INF
	var hi := -INF
	for i in range(win, rows.size()):
		var r: Dictionary = rows[i]
		if r.t < t0 or r.t > t1:
			continue
		var mean := 0.0
		for j in range(i - win, i):
			mean += rows[j][key]
		mean /= win
		lo = minf(lo, r[key] - mean)
		hi = maxf(hi, r[key] - mean)
	return hi - lo


func test_no_bounce() -> void:
	for wind: float in [0.0, 3.0]:
		var rows := run_trace(15.0, wind)
		var t_end: float = rows[rows.size() - 1].t - 0.3
		var cm := jitter(rows, "cm", 30, 1.5, t_end)
		var hips := jitter(rows, "hips", 30, 1.5, t_end)
		print("    встречный %.0f м/с: разбег %.2f с; подскок ЦМ физики %.1f см, таза в картинке %.1f см (размах)" % [
			wind, t_end, cm * 100.0, hips * 100.0])
		check(cm < 0.02, "ветер %.0f: ЦМ физики не подпрыгивает (%.1f см ≤ 2)" % [wind, cm * 100.0])
		check(hips < 0.05, "ветер %.0f: таз пилота в картинке не подпрыгивает (%.1f см ≤ 5; было ≈ 40)" % [wind, hips * 100.0])
