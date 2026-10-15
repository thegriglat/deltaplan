extends Node
## SPF-1 п.1 и п.2: болтанка (load.jitter) и тангаж киля на разных воздушных скоростях.
## Запуск (из корня копии):
##   XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --headless --path . \
##     res://tools/research/speed-feel/jitter_theta.tscn -- --out=/путь/jitter.json
## Воздух: GustSpectrum (замороженный в пространстве), σ_u=σ_w=σ, нулевой средний ветер.
const Sim := preload("res://tests/flight/flight_sim.gd")
const DT := 1.0 / 120.0
const SEEDS := [11, 22, 33, 44, 55]
const WARM_S := 40.0
const MEAS_S := 200.0

var _gs: GustSpectrum
var _m: FlightModel
var _sigma := 1.0
var _lu := 100.0
var _lw := 100.0


func _air(p: Vector3) -> Vector3:
	var g := _gs.sample(p, _m.time_s, 0.0, Vector3.RIGHT, _lu, _lw)
	return Vector3(g.x, g.y, g.z) * _sigma


func _pitch_for(m: FlightModel, v_kmh: float) -> float:
	var tr := m.trim_speed() * 3.6
	if v_kmh >= tr:
		return -(v_kmh - tr) / (float(m.wing.full_pull_speed_kmh) - tr)
	return (tr - v_kmh) / (tr - float(m.wing.full_push_speed_kmh))


func _calm(wing: String, v_kmh: float) -> Dictionary:
	var m := Sim.make(wing)
	var p := _pitch_for(m, v_kmh)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var inp := Sim.input(p)
	Sim.run_for(m, 90.0, inp)
	var t := m.telemetry
	var gamma := asin(clampf(m.velocity.y / m.velocity.length(), -1, 1))
	return {
		"wing": wing, "v_target_kmh": v_kmh, "pitch": p, "v_kmh": t.airspeed * 3.6,
		"sink_ms": -m.velocity.y, "theta_deg": rad_to_deg(m.theta),
		"gamma_deg": rad_to_deg(gamma), "alpha_deg": rad_to_deg(m.alpha),
		"alpha_stall_deg": rad_to_deg(m.alpha_stall), "stalled": m.stalled,
	}


func _gust(wing: String, v_kmh: float, seed_v: int) -> Dictionary:
	_gs = GustSpectrum.new()
	_gs.setup(seed_v, 0.6)
	_m = Sim.make(wing)
	var p := _pitch_for(_m, v_kmh)
	_m.reset_in_air(Vector3(1000.0 * seed_v, 3000, 0), 0.0)
	var inp := Sim.input(p)
	var air := Callable(self, "_air")
	Sim.run_for(_m, WARM_S, inp, air)
	var n := int(MEAS_S / DT)
	var sj := 0.0
	var sd2 := 0.0
	var sv := 0.0
	var sa := 0.0
	var sth := 0.0
	var sth2 := 0.0
	var fmean := 0.0
	var lo := 9.0
	var hi := 0.0
	var inl := PackedFloat64Array()
	for i in n:
		_m.step(DT, inp, air, Callable())
		sj += _m.load.jitter
		var d := _m.load.load_raw - _m.load.load_factor
		sd2 += d * d
		sv += _m.telemetry.airspeed
		lo = minf(lo, _m.load.load_raw)
		hi = maxf(hi, _m.load.load_raw)
		sth += _m.theta
		sth2 += _m.theta * _m.theta
		if _m.stalled:
			sa += 1.0
		fmean += _m.load.load_raw
	var th_m := sth / n
	return {
		"jitter": sj / n, "rms_dev_g": sqrt(sd2 / n), "v_ms": sv / n,
		"theta_sd_deg": rad_to_deg(sqrt(maxf(sth2 / n - th_m * th_m, 0.0))),
		"stalled_frac": sa / n, "n_min": lo, "n_max": hi, "n_mean": fmean / n,
	}


func _ready() -> void:
	var out := "user://jitter.json"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var res := {"calm": [], "gust": []}
	for c in [["training", 30.0], ["training", 32.3], ["training", 40.0], ["training", 55.0],
			["training", 62.6], ["sport", 30.0], ["sport", 35.4], ["sport", 40.0],
			["sport", 55.0], ["sport", 80.0]]:
		res.calm.append(_calm(c[0], c[1]))
	var full_g := float(Config.value("sail", "turbulence_full_g"))
	res["full_g"] = full_g
	# (крыло, скорости) × масштаб L × σ
	var plans := [["training", [32.3, 40.0, 55.0, 62.6]], ["sport", [35.4, 55.0, 80.0]]]
	for scale in [[100.0, 100.0], [30.0, 30.0], [300.0, 300.0]]:
		_lu = scale[0]
		_lw = scale[1]
		for pl in plans:
			for v in pl[1]:
				var rows := []
				for s in SEEDS:
					rows.append(_gust(pl[0], v, s))
				var jm := 0.0
				var jv := 0.0
				for r in rows:
					jm += r.jitter
				jm /= rows.size()
				for r in rows:
					jv += (r.jitter - jm) * (r.jitter - jm)
				var vm := 0.0
				for r in rows:
					vm += r.v_ms
				res.gust.append({
					"wing": pl[0], "v_target_kmh": v, "L": scale[0], "sigma": _sigma,
					"jitter_mean": jm, "jitter_sd": sqrt(jv / (rows.size() - 1)),
					"v_ms": vm / rows.size(), "rows": rows,
				})
				print("%s %.1f L=%d jitter=%.4f v=%.2f" % [pl[0], v, scale[0], jm, vm / rows.size()])
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	get_tree().quit()
