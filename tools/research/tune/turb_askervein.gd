extends SceneTree
## AM-09: масштаб 3 на поле Askervein — ТКЭ в точках мачт (как Atmosphere._air_velocity_field:
## σ механики и слоя смешения, большее из двух, те же ограничители; шум u, v — σ_u, w — σ_w, СКО 1),
## ТКЭ = ½(2σ_u² + σ_w²). Перебор порогов признака отрыва (lee.field_deficit_attached,
## field_deficit_separated − attached, field_descent_slope) — остальное из configs/atmosphere.json.
##
##   godot --headless --path . -s tools/research/tune/turb_askervein.gd -- \
##     --points=tools/research/tune/out/tke_points.json --out=<json> <поле без расширения> ...


func _init() -> void:
	var pts_path := ""
	var out_path := ""
	var fields: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--points="):
			pts_path = a.substr(9)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		else:
			fields.append(a)
	var pts: Array = JSON.parse_string(FileAccess.get_file_as_string(pts_path))
	var atm: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/atmosphere.json"))
	var turb: Dictionary = atm.turbulence
	var turb_max := float(turb.max_amplitude_ms)
	var rotor_max := float(atm.lee.get("rotor_max_amplitude_ms", 0.0))
	var ex0s: Array[float] = []
	for q in 15:
		ex0s.append(0.05 * q)
	var widths: Array[float] = [0.2, 0.4, 0.6]
	var descs: Array[float] = [0.02, 0.05, 0.1]
	var res := {}
	for path in fields:
		var f := WindField.load_file(path)
		if f == null:
			continue
		var rows: Array = []
		for ex0 in ex0s:
			for wd in widths:
				for ds in descs:
					var lee: Dictionary = atm.lee.duplicate()
					lee.field_deficit_attached = ex0
					lee.field_deficit_separated = ex0 + wd
					lee.field_descent_slope = ds
					var ft := FieldTurbulence.new()
					ft.setup(turb, lee, 42)
					ft.z0 = f.z0
					var vals := {}
					for p in pts:
						vals[p.name] = _point(f, ft, p, turb_max, rotor_max)
					rows.append({"ex0": ex0, "width": wd, "desc": ds, "pts": vals})
		res[path.get_file()] = rows
	var fo := FileAccess.open(out_path, FileAccess.WRITE)
	fo.store_string(JSON.stringify(res))
	fo.close()
	print("turb_askervein: ", fields.size(), " полей → ", out_path)
	quit(0)


func _point(f: WindField, ft: FieldTurbulence, p: Dictionary, turb_max: float, rotor_max: float) -> Dictionary:
	var ground := float(p.ground)
	var agl := float(p.h)
	var pos := Vector3(float(p.x), ground + agl, -float(p.y))
	var s := f.sample(pos, ground)
	var uf := Vector2(s.x, s.z).length()
	var tb := f.turb_at(pos, ground)
	var lee_f := ft.lee(uf, agl, tb)
	var du := maxf(tb[WindField.T_UOUT] - uf, 0.0) * lee_f
	var sg := ft.sigma(agl, tb, Vector2.ZERO)
	var sep := ft.sep_sigma(du)
	var s_u := minf(maxf(sg.x, sep.x), maxf(turb_max, minf(sep.x, rotor_max)))
	var s_w := minf(maxf(sg.y, sep.y), maxf(turb_max, minf(sep.y, rotor_max)))
	return {
		"u": uf, "tke": 0.5 * (2.0 * s_u * s_u + s_w * s_w), "su": s_u, "sw": s_w, "lee": lee_f,
		"ustar": tb[WindField.T_USTAR]
	}
