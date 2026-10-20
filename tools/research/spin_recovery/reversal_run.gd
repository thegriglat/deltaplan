extends Node
## SR-3: переложение 45→45 (как test_reversal_45 / test_pendulum_flight_feel.gd) для вариантов стенда spin_run.gd.
## godot --headless --path . res://tools/research/spin_recovery/reversal_run.tscn -- --wing=sport --variant=game --out=<json>
const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const SR := preload("res://tools/research/spin_recovery/spin_run.gd")


func _ready() -> void:
	var a := {"wing": "sport", "variant": "game", "out": ""}
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--") and x.contains("="):
			var kv := x.substr(2).split("=", true, 1)
			a[kv[0]] = kv[1]
	var sr: Node = SR.new()
	var mk: Dictionary = sr.make_model(String(a.wing), String(a.variant))
	var m: PendulumModel = mk.m
	S.reset(m)
	var r := S.scenario("reversal", String(a.wing))
	var bh := S.BankHold.new(deg_to_rad(float(r.bank_deg)), 6.0, 2.5, 1.0)
	var inp := S.input()
	for i in int(round(float(r.hold_s) / S.DT)):
		inp.roll = bh.roll(m)
		m.step(S.DT, inp, Callable(), Callable())
	var phi0 := rad_to_deg(m.bank)
	var t0 := m.time_s
	inp.roll = -1.0
	var t_rev := NAN
	for i in int(round(12.0 / S.DT)):
		m.step(S.DT, inp, Callable(), Callable())
		if is_nan(t_rev) and m.bank <= deg_to_rad(-float(r.bank_deg)):
			t_rev = m.time_s - t0
	var res := {"wing": a.wing, "variant": a.variant, "reversal_s": (null if is_nan(t_rev) else t_rev), "phi_start_deg": phi0,
		"finite": S.finite(m)}
	var f := FileAccess.open(String(a.out) + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(res))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(String(a.out) + ".tmp"), ProjectSettings.globalize_path(String(a.out)))
	get_tree().quit(0)
