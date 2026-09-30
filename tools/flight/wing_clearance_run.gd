extends Node
## Таблица зазора крыла над рельефом на земле (SF-4): штиль, синтетические склоны и встроенные
## старты локаций, все крылья линейки; фазы — стоит / трапеция до упора / A (крен) / шагом /
## разбег до отрыва / первые 1,5 с после отрыва. Модель — tools/flight/wing_clearance.gd.
##
## Запуск (без окна, несколько минут):
##   godot --headless --path . res://tools/flight/wing_clearance_run.tscn -- [--csv=файл.csv]
##       [--wings=sport,training] [--loc-wings=training,sport,magic,combat] [--no-locations]
## (на стартах локаций по умолчанию — 4 крыла: крайние по размаху/стреловидности и зазору)
## Строка CSV на фазу: наименьший зазор за фазу (м) и состояние в этот момент; разложение
## по кандидатам — тот же кадр с креном 0 (clear_nobank), с килем по горизонту и креном 0
## (clear_level), с поворотом базиса вокруг HangPoint вместо ступней (clear_pivot_hang), против
## рельефа, как его рисует сетка (clear_rendered, только локации), ошибка высоты ступней
## (feet_err = рисуемая − билинейная высота под ступнями, м).

const WC := preload("res://tools/flight/wing_clearance.gd")
const DT := 1.0 / 120.0
const SAMPLE_EVERY := 12  ## шагов между замерами (10 Гц)
const LOCATIONS := ["altai", "ongudai", "askarovo", "aushkul"]
const COLS := [
	"scene",
	"wing",
	"phase",
	"t_s",
	"bank_deg",
	"theta_deg",
	"slope_along_deg",
	"slope_cross_deg",
	"clear_min",
	"part",
	"tips",
	"nose",
	"tail",
	"frame",
	"clear_nobank",
	"clear_level",
	"clear_pivot_hang",
	"clear_rendered",
	"feet_err"
]

var _out: FileAccess
var _hang := 2.0


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var csv := String(args.get("csv", "build/sf4/wing_clearance.csv"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(csv).get_base_dir())
	_out = FileAccess.open(csv, FileAccess.WRITE)
	_out.store_line(",".join(COLS))
	_hang = float(Config.get_config("flight").visual.hang_height_m)
	var wings: Array = []
	if args.has("wings"):
		wings = String(args.wings).split(",")
	else:
		for p in Config.list_configs("wings"):
			wings.append(String(p).get_file())
	var loc_wings: Array = String(args.get("loc-wings", "training,sport,magic,combat")).split(",")
	var zero := func(_p: Vector3) -> Vector3: return Vector3.ZERO
	var flat := func(_x: float, _z: float) -> float: return 100.0
	var down20 := func(_x: float, z: float) -> float: return 100.0 + tan(deg_to_rad(20.0)) * z
	var cross15 := func(x: float, _z: float) -> float: return 100.0 + tan(deg_to_rad(15.0)) * x
	for w: String in wings:
		_scene("ровно", w, Vector3(0, 100, 0), 0.0, flat, zero, null)
		_scene("склон 20° по курсу", w, Vector3(0, 100, 0), 0.0, down20, zero, null)
		_scene("косой 15° (правая вверх)", w, Vector3(0, 100, 0), 0.0, cross15, zero, null)
	if not args.has("no-locations"):
		for id: String in LOCATIONS:
			var t := Terrain.new()
			t.location_id = ""
			if not t.load_location(id):
				t.free()
				continue
			var gf := func(x: float, z: float) -> float: return t.height_at(x, z)
			for site in t.get_start_sites():
				for w: String in loc_wings:
					_scene(
						"%s/%s" % [id, site.id],
						w,
						site.position,
						float(site.heading_deg),
						gf,
						zero,
						t
					)
			t.free()
	_out.close()
	print("wing_clearance: готово → ", csv)
	get_tree().quit()


func _scene(
	name: String, w: String, pos: Vector3, heading: float, gf: Callable, af: Callable, t: Terrain
) -> void:
	var g := WC.make_glider(self, w)
	var pts := WC.wing_points(g.visual)
	var phases := {
		"стоит": [_inp(0, 0, false, 0), 3.0],
		"стоит, трапеция от себя (нос вверх)": [_inp(1, 0, false, 0), 3.0],
		"стоит, трапеция на себя (нос вниз)": [_inp(-1, 0, false, 0), 3.0],
		"стоит, A (крен от A/D)": [_inp(0, -1, false, 0), 3.0],
		"шагом": [_inp(0, 0, false, 1), 4.0],
		"разбег": [_inp(0, 0, true, 0), 12.0],
	}
	for ph: String in phases:
		var m := g.model
		m.reset_on_ground(Vector3(pos.x, gf.call(pos.x, pos.z), pos.z), heading)
		var inp: ControlInput = phases[ph][0]
		var dur: float = phases[ph][1]
		var worst := {}
		var after := {}
		var air_t := 0.0
		var n := 0
		var time := 0.0
		while time < dur:
			m.step(DT, inp, af, gf)
			time += DT
			n += 1
			if m.mode == FlightModel.Mode.AIR:
				air_t += DT
				if air_t > 1.5:
					break
			elif m.mode != FlightModel.Mode.GROUND:
				break
			if n % SAMPLE_EVERY != 0:
				continue
			var row := _measure(m, pts, gf, t, time)
			if m.mode == FlightModel.Mode.AIR:
				if after.is_empty() or row.clear_min < after.clear_min:
					after = row
			elif worst.is_empty() or row.clear_min < worst.clear_min:
				worst = row
		_write(name, w, ph, worst)
		if not after.is_empty():
			_write(name, w, "после отрыва ≤1,5 с", after)
	g.free()


func _measure(m: FlightModel, pts: Dictionary, gf: Callable, t: Terrain, time: float) -> Dictionary:
	var x := WC.pose(m)
	var c := WC.clearance(pts, x, gf)
	var sl := WC.slopes(gf, m.position, m.heading)
	var row := {
		"t_s": time,
		"bank_deg": rad_to_deg(m.bank),
		"theta_deg": rad_to_deg(m.theta),
		"slope_along_deg": sl.x,
		"slope_cross_deg": sl.y,
		"clear_min": c.min,
		"part": c.part,
		"tips": c.tips,
		"nose": c.nose,
		"tail": c.tail,
		"frame": c.frame,
	}
	row.clear_nobank = WC.clearance(pts, WC.pose(m, true), gf).min
	var lvl := Transform3D(Basis.from_euler(Vector3(0, -m.heading, 0)), m.position)
	row.clear_level = WC.clearance(pts, lvl, gf).min
	var up := Vector3(0, _hang, 0)
	var piv := Transform3D(x.basis, m.position + up - x.basis * up)
	row.clear_pivot_hang = WC.clearance(pts, piv, gf).min
	row.clear_rendered = NAN
	row.feet_err = 0.0
	if t != null:
		var l: HeightLayer = t.layers[0]
		var rf := func(xx: float, zz: float) -> float: return WC.rendered_height(l, xx, zz)
		row.clear_rendered = WC.clearance(pts, x, rf).min
		row.feet_err = WC.rendered_height(l, m.position.x, m.position.z) - m.position.y
	return row


func _write(name: String, w: String, ph: String, r: Dictionary) -> void:
	if r.is_empty():
		return
	var vals := ['"%s"' % name, w, '"%s"' % ph]
	for k in COLS.slice(3):
		var v: Variant = r[k]
		vals.append(("%.3f" % v) if v is float else str(v))
	_out.store_line(",".join(vals))
	_out.flush()
	print(",".join(vals))


static func _inp(pitch: float, roll: float, run: bool, walk: float) -> ControlInput:
	var c := ControlInput.new()
	c.pitch = pitch
	c.roll = roll
	c.run = run
	c.walk = walk
	return c
