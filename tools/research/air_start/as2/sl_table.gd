extends Node
## AS-2: болтанка поля в точке на ровном месте (синтетическое поле — лог-профиль, как
## air_turb/turb_probe.gd → _synthetic) против теории подобия приземного слоя, 1,5…300 м.
## Headless, без GPU:
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/air_start/as2/sl_table.tscn -- \
##     --out=<файл.jsonl> [--dur=600]
## Строка на (случай, высота): σu (вдоль среднего), σv (поперёк), σw, w̄, σθ, max|θ| и max|ΔU|/0,5 с
## за 20-с окна (медиана и максимум по окнам), время корреляции u (e⁻¹), Ū, u* поля.

const SEED := 42
const HZ := 10.0

var out_path := "user://sl_table.jsonl"
var dur := 600.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--dur="):
			dur = float(a.substr(6))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var sun := func(_x: float, _z: float) -> float: return 0.5
	var cases := [
		["3 м/с, нейтр.", 3.0, 0.0, 0.0],
		["6 м/с, нейтр.", 6.0, 0.0, 0.0],
		["8 м/с, нейтр.", 8.0, 0.0, 0.0],
		["6 м/с, N=0,010", 6.0, 0.0033, 0.0],
		["3 м/с, H=300, z_i=1500", 3.0, 0.0, 300.0],
		["6 м/с, H=300, z_i=1500", 6.0, 0.0, 300.0],
	]
	for cs: Array in cases:
		for agl: float in [1.5, 5.0, 10.0, 50.0, 100.0, 300.0]:
			var a := _make_atmo(float(cs[1]) * 3.6, 270.0)
			a.set_ground(flat, sun)
			a.set_thermal_mode("static")
			var wf := _synthetic(cs[1], cs[2], cs[3], 1500.0)
			a.set_air_field(wf, 0.0)
			var pos := Vector3(0.0, agl, 0.0)
			var row := _series(a, pos)
			row["case"] = cs[0]
			row["agl"] = agl
			var tb := a.air_field.sample_turb(pos, 0.0)
			row["T_USTAR"] = tb[WindField.T_USTAR]
			row["T_WSTAR"] = tb[WindField.T_WSTAR]
			row["T_HMIX"] = tb[WindField.T_HMIX]
			row["T_N2"] = tb[WindField.T_N2]
			row["T_SHEAR"] = tb[WindField.T_SHEAR]
			var m := a.mean_wind_at(pos)
			row["U_mean"] = Vector2(m.x, m.z).length()
			row["advect"] = a._advect
			a.free()
			f.store_line(JSON.stringify(row))
			f.flush()
			print(JSON.stringify(row))
	f.close()
	get_tree().quit()


func _make_atmo(wind_kmh: float, from_deg: float) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = wind_kmh
	w.wind_from_deg = from_deg
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.seed_value = SEED
	atmo.configure(Config.get_config("atmosphere").duplicate(true), w)
	atmo.turbulence_enabled = true
	return atmo


## Ряд в точке (шаг 1/HZ), статистика по всему ряду и по 20-с окнам.
func _series(atmo: Atmosphere, pos: Vector3) -> Dictionary:
	var dt := 1.0 / HZ
	var n := int(dur * HZ)
	atmo.set_focus(pos)
	var us := PackedFloat32Array()
	var vs := PackedFloat32Array()
	var ws := PackedFloat32Array()
	us.resize(n)
	vs.resize(n)
	ws.resize(n)
	for i in n:
		atmo.step(dt)
		var v := atmo.air_velocity_at(pos)
		us[i] = v.x
		vs[i] = v.z
		ws[i] = v.y
	var mu := _mean(us)
	var mv := _mean(vs)
	var e := Vector2(mu, mv).normalized()
	var al := PackedFloat32Array()
	var cr := PackedFloat32Array()
	al.resize(n)
	cr.resize(n)
	for i in n:
		al[i] = us[i] * e.x + vs[i] * e.y
		cr[i] = -us[i] * e.y + vs[i] * e.x
	var out := {
		"U": Vector2(mu, mv).length(), "su": _std(al), "sv": _std(cr), "sw": _std(ws), "wm": _mean(ws),
		"rev_frac": 0.0,
	}
	var rev := 0
	var th := PackedFloat32Array()
	th.resize(n)
	for i in n:
		th[i] = rad_to_deg(atan2(cr[i], al[i]))
		if al[i] < 0.0:
			rev += 1
	out.rev_frac = float(rev) / n
	out["sth"] = _std(th)
	# окна 20 с: max|θ − θ̄_окна|, max|ΔU| за 0,5 с
	var win := int(20.0 * HZ)
	var thm := []
	var dum := []
	var k := int(0.5 * HZ)
	for s in range(0, n - win + 1, win):
		var a := 0.0
		var b := 0.0
		for i in range(s, s + win):
			a += us[i]
			b += vs[i]
		var ew := Vector2(a, b).normalized()
		var mx := 0.0
		var md := 0.0
		for i in range(s, s + win):
			var x := us[i] * ew.x + vs[i] * ew.y
			var y := -us[i] * ew.y + vs[i] * ew.x
			mx = maxf(mx, absf(rad_to_deg(atan2(y, x))))
			if i + k < s + win:
				var s0 := Vector2(us[i], vs[i]).length()
				var s1 := Vector2(us[i + k], vs[i + k]).length()
				md = maxf(md, absf(s1 - s0))
		thm.append(mx)
		dum.append(md)
	thm.sort()
	dum.sort()
	out["thmax20_med"] = thm[thm.size() / 2]
	out["thmax20_max"] = thm[-1]
	out["dU05_med"] = dum[dum.size() / 2]
	out["dU05_max"] = dum[-1]
	# время корреляции u вдоль: первое пересечение e⁻¹
	var m := _mean(al)
	var var0 := 0.0
	for i in n:
		var0 += (al[i] - m) * (al[i] - m)
	var tau := NAN
	for lag in range(1, mini(n / 2, int(120.0 * HZ))):
		var c := 0.0
		for i in n - lag:
			c += (al[i] - m) * (al[i + lag] - m)
		if c / var0 < exp(-1.0):
			tau = lag * dt
			break
	out["tau_u"] = tau
	return out


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()


func _std(a: PackedFloat32Array) -> float:
	var m := _mean(a)
	var s := 0.0
	for x in a:
		s += (x - m) * (x - m)
	return sqrt(s / a.size())


## Синтетическое поле (как air_turb/turb_probe.gd): ровная земля, лог-профиль по x.
func _synthetic(u10: float, gam: float, heat: float, z_i: float) -> WindField:
	var nx := 16
	var nz := 40
	var dz := 25.0
	var m := {
		"dx": 100.0, "dz": dz, "x0": -800.0, "y0": -800.0, "z_bot": 0.0,
		"nx": nx, "ny": nx, "nz": nz, "z0": 0.1,
	}
	var g := []
	for k in nz:
		g.append(gam)
	m["gam"] = g
	var h := []
	for c in nx * nx:
		h.append(heat)
	m["heat"] = h
	m["z_i"] = z_i
	var n := nx * nx * nz
	var u := PackedFloat32Array()
	var z0a := PackedFloat32Array()
	u.resize(n)
	z0a.resize(n)
	for k in nz:
		var z := (k + 0.5) * dz
		var s := u10 * log(z / 0.1) / log(10.0 / 0.1)
		for c in nx * nx:
			u[k * nx * nx + c] = s
	var hc := PackedFloat32Array()
	hc.resize(nx * nx)
	return WindField.from_arrays(m, u, z0a, z0a, z0a, z0a, hc)
