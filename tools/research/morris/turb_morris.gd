extends SceneTree
## Моррис масштаба 3: ТКЭ, σ_u, σ_w, признак отрыва в точках мачт Askervein на готовых полях
## (как tools/research/tune/turb_askervein.gd — те же функции атмосферы игры), по точкам плана:
## каждая точка — замены ключей configs/atmosphere.json ("turbulence.key" / "lee.key" → число).
##
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s tools/research/morris/turb_morris.gd -- \
##     --points=tools/research/tune/out/tke_points.json --plan=<plan_s3.json> --out=<json> <поле без расш.> ...


func _init() -> void:
	var pts_path := ""
	var plan_path := ""
	var out_path := ""
	var fields: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--points="):
			pts_path = a.substr(9)
		elif a.begins_with("--plan="):
			plan_path = a.substr(7)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		else:
			fields.append(a)
	var pts: Array = JSON.parse_string(FileAccess.get_file_as_string(pts_path))
	var plan: Array = JSON.parse_string(FileAccess.get_file_as_string(plan_path))
	var atm: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/atmosphere.json"))
	var res := {}
	for path in fields:
		var f := WindField.load_file(path)
		if f == null:
			push_error("нет поля " + path)
			continue
		var rows: Array = []
		for p in plan:
			var turb: Dictionary = atm.turbulence.duplicate()
			var lee: Dictionary = atm.lee.duplicate()
			var over: Dictionary = p.over
			for k in over:
				var parts: PackedStringArray = String(k).split(".")
				if parts[0] == "turbulence":
					turb[parts[1]] = float(over[k])
				else:
					lee[parts[1]] = float(over[k])
			var ft := FieldTurbulence.new()
			ft.setup(turb, lee, 42)
			ft.z0 = f.z0
			var turb_max := float(turb.max_amplitude_ms)
			var rotor_max := float(lee.get("rotor_max_amplitude_ms", 0.0))
			var vals := {}
			for q in pts:
				vals[q.name] = _point(f, ft, q, turb_max, rotor_max)
			rows.append({"id": p.id, "pts": vals})
		res[path.get_file()] = rows
	var fo := FileAccess.open(out_path, FileAccess.WRITE)
	fo.store_string(JSON.stringify(res))
	fo.close()
	print("turb_morris: ", fields.size(), " полей × ", plan.size(), " точек → ", out_path)
	quit(0)


func _point(
	f: WindField, ft: FieldTurbulence, p: Dictionary, turb_max: float, rotor_max: float
) -> Dictionary:
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
	return {"tke": 0.5 * (2.0 * s_u * s_u + s_w * s_w), "su": s_u, "sw": s_w, "lee": lee_f}
