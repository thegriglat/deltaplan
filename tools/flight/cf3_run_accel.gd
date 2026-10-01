extends Node
## CF-3: разгон на разбеге в штиль — по времени (шаг 0,1 с): скорость, ускорение и вклады
## ноги / склон / крыло (остаток: сопротивление и подъёмная сила вдоль склона), доля веса на ногах.
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/cf3_run_accel.tscn
##   -- [--csv=файл.csv]. Итог по случаю — в stdout.

const Sim := preload("res://tests/flight/flight_sim.gd")


func _ready() -> void:
	var csv_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--csv="):
			csv_path = a.substr(6)
	var rows := PackedStringArray(["wing,slope_deg,t_s,v_ground_ms,v_air_ms,a_ms2,a_legs,a_slope,a_wing,feet_load,phase"])
	for w in ["slavutich_ut", "sport"]:
		for slope in [8.0, 17.0]:
			var k := tan(deg_to_rad(slope))
			var gf := func(_x: float, z: float) -> float: return 1000.0 + k * z
			var af := func(_p: Vector3) -> Vector3: return Vector3.ZERO
			var m := Sim.make(w)
			m.reset_on_ground(Vector3.ZERO, 0.0)
			var gr: GroundRun = m._ground
			var run: Dictionary = m.pilot.run
			var inp := Sim.input(0.0, 0.0, true)
			var t := 0.0
			var n := 0
			var a_peak := 0.0
			var acc := Vector3.ZERO  # сумма вкладов за отчётный интервал
			var steps := 0
			var v0 := 0.0
			while t < 15.0 and m.mode == FlightModel.Mode.GROUND:
				var v := gr._speed
				var load := gr.feet_load
				var v_cap := float(run.speed_max_ms) * (1.0 + float(run.unload_speed_bonus) * (1.0 - load))
				var f_run := float(run.force_n) * (1.0 - v / v_cap)
				if f_run < 0.0:
					f_run *= load
				m.step(Sim.DT, inp, af, gf)
				t += Sim.DT
				n += 1
				var a := (gr._speed - v) / Sim.DT
				var a_legs := f_run / m.mass
				var a_slope := Units.G * sin(atan(k))
				acc += Vector3(a_legs, a_slope, a - a_legs - a_slope)
				steps += 1
				if m.mode == FlightModel.Mode.GROUND:
					a_peak = maxf(a_peak, a)
				if n % 12 == 0 or m.mode != FlightModel.Mode.GROUND:
					var am := acc / steps
					rows.append(
						"%s,%.0f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%s"
						% [w, slope, t, gr._speed, m.telemetry.airspeed, (gr._speed - v0) / (steps * Sim.DT),
							am.x, am.y, am.z, gr.feet_load, m.phase()]
					)
					v0 = gr._speed
					acc = Vector3.ZERO
					steps = 0
			var d := Vector2(m.position.x, m.position.z).length()
			print(
				"%s склон %.0f°: %s за %.2f с, %.1f м; V отрыва %.2f м/с (путевая = воздушная в штиль), a пик %.2f, средн %.2f м/с², масса %.0f кг"
				% [w, slope, m.phase(), t, d, gr._speed, a_peak, gr._speed / t, m.mass]
			)
	if csv_path != "":
		var f := FileAccess.open(csv_path, FileAccess.WRITE)
		f.store_string("\n".join(rows) + "\n")
	else:
		print("\n".join(rows))
	get_tree().quit()
