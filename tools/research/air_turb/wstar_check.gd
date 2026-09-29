extends SceneTree
## AM-08 ↔ AM-07: w* болтанки (WindField.turb_at → T_WSTAR, H сглажен квадратом 1500 м) против w*
## источников термиков (AirThermals.wstar, H — среднее по водосбору источника). Одна формула
## (WindField.deardorff_wstar), разное осреднение H. Печатает среднее и разброс отношения.
##   godot --headless --path . -s tools/research/air_turb/wstar_check.gd -- <поле без расширения> ...
func _init() -> void:
	for path in OS.get_cmdline_user_args():
		var f := WindField.load_file(path)
		var atm: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/atmosphere.json"))
		var w: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/weather/medium.json"))
		var c: Dictionary = atm.thermal.duplicate()
		c["radius_m"] = w.thermal_radius_m
		c["duty"] = float(w.thermal_duty)
		c["cloudbase_msl"] = 1.0e9
		var s := AirThermals.new()
		if not s.build(f, c):
			print(path, ": источников нет")
			continue
		var rs := PackedFloat32Array()
		var sum_a := 0.0
		var sum_b := 0.0
		for i in s.count():
			var p: Vector3 = s.pos[i]
			var t := f.turb_at(Vector3(p.x, p.y + 50.0, p.z))
			if s.wstar[i] > 0.01:
				rs.append(t[WindField.T_WSTAR] / s.wstar[i])
				sum_a += t[WindField.T_WSTAR]
				sum_b += s.wstar[i]
		var mu := 0.0
		for r in rs:
			mu += r
		mu /= maxf(rs.size(), 1)
		var sd := 0.0
		for r in rs:
			sd += (r - mu) * (r - mu)
		sd = sqrt(sd / maxf(rs.size(), 1))
		var lo := 1.0e9
		var hi := 0.0
		for r in rs:
			lo = minf(lo, r)
			hi = maxf(hi, r)
		print("%s: источников %d; w* болтанки / w* термика: среднее %.3f, СКО %.3f, мин %.3f, макс %.3f; средние w* %.3f / %.3f м/с"
			% [path.get_file(), rs.size(), mu, sd, lo, hi, sum_a / maxf(rs.size(), 1), sum_b / maxf(rs.size(), 1)])
	quit(0)
