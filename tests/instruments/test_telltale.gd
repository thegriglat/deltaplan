extends Node
## Ленточка на тросе трапеции (TelltaleModel, Telltale): направление совпадает с потоком воздуха
## у точки крепления — встречный и боковой ветер на месте, скольжение в полёте; без потока висит
## вниз; вращение планера входит в поток; узел находится на тросе каждого крыла.

const DT := 1.0 / 120.0
const TOL_DEG := 8.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _cfg() -> Dictionary:
	return Config.get_config("instruments").telltale


## Среднее направление ленточки за последние 2 с из 3 с в постоянном потоке w.
func _mean_dir(w: Vector3) -> Vector3:
	var m := TelltaleModel.new()
	m.setup(_cfg())
	var sum := Vector3.ZERO
	for i in 360:
		m.step(DT, w)
		if i >= 120:
			sum += m.direction()
	return sum.normalized()


func _deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


func test_headwind_at_rest() -> void:
	# планер стоит носом на север (−Z), ветер с севера 5 м/с дует на юг (+Z)
	var r := Vector3(0.7, 1, -1)
	var w := TelltaleModel.airflow_at(Vector3(0, 0, 5), Vector3.ZERO, Basis(), Basis(), r, DT)
	var d := _mean_dir(w)
	check(_deg(d, w) < TOL_DEG, "встречный: лента по потоку, отклонение %.1f°" % _deg(d, w))
	check(d.z > 0.95, "встречный: лента назад, к пилоту: %s" % d)


func test_crosswind_at_rest() -> void:
	var w := Vector3(-4, 0, 0)  # ветер с востока
	var d := _mean_dir(w)
	check(_deg(d, w) < TOL_DEG, "боковой: отклонение %.1f°" % _deg(d, w))
	check(d.x < -0.9, "боковой: лента на запад: %s" % d)


func test_weak_wind_droops() -> void:
	var d := _mean_dir(Vector3(0, 0, 1.0))
	var elev := rad_to_deg(asin(-d.y))
	check(elev > 30.0 and elev < 60.0, "1 м/с: провис ~45° (lift_45_ms), сейчас %.0f°" % elev)


func test_no_airflow_hangs_down() -> void:
	var d := _mean_dir(Vector3.ZERO)
	check(_deg(d, Vector3.DOWN) < 1.0, "без потока висит вниз: %s" % d)


func test_sideslip_in_flight() -> void:
	# курс 30°, крен 20°, летит со скольжением 12° вправо, ветер 4 м/с с запада
	var basis := Basis.from_euler(Vector3(deg_to_rad(5.0), -deg_to_rad(30.0), -deg_to_rad(20.0)))
	var wind := Vector3(4, 0, 0)
	var air_dir := Vector3(sin(deg_to_rad(42.0)), 0, -cos(deg_to_rad(42.0)))
	var v := wind + air_dir * 12.0 + Vector3(0, -1.2, 0)
	var w := TelltaleModel.airflow_at(wind, v, basis, basis, Vector3(0.7, 1, -1), DT)
	var d := _mean_dir(w)
	check(_deg(d, w) < TOL_DEG, "скольжение: отклонение %.1f°" % _deg(d, w))
	# в осях планера: угол ленты по размаху = угол скольжения (лента уходит влево-назад)
	var bd := basis.inverse() * d
	var bw := basis.inverse() * w
	var slip_rib := rad_to_deg(atan2(bd.x, bd.z))
	var slip_air := rad_to_deg(atan2(bw.x, bw.z))
	check(absf(slip_rib - slip_air) < 3.0, "угол ленты %.1f° vs потока %.1f°" % [slip_rib, slip_air])
	check(slip_rib < -8.0, "при скольжении вправо лента отклонена влево: %.1f°" % slip_rib)


func test_rotation_adds_point_velocity() -> void:
	# штиль, планер на месте рыскает вправо 0,5 рад/с: точка в 1 м справа движется назад (+Z)
	var prev := Basis()
	var cur := Basis(Vector3.UP, -0.5 * DT)
	var w := TelltaleModel.airflow_at(Vector3.ZERO, Vector3.ZERO, prev, cur, Vector3(1, 0, 0), DT)
	check(absf(w.z + 0.5) < 0.01 and absf(w.x) < 0.01, "поток от вращения = −ω×r: %s" % w)


func test_anchor_on_every_wing() -> void:
	var vis_cfg: Dictionary = Config.get_config("flight").visual
	var pilot_cfg: Dictionary = Config.get_config("pilot")
	for id in Config.list_configs("wings"):
		var v := GliderVisual.new()
		add_child(v)
		v.build(Config.get_config(id), pilot_cfg, vis_cfg)
		check(v.telltales.size() == 2, "%s: две ленточки" % id)
		if v.telltales.size() == 2:
			var l := v.to_local(v.telltales[0].global_position)
			var r := v.to_local(v.telltales[1].global_position)
			var bb := v.to_local(v.get_marker("BaseBar").global_position)
			check(l.x < -0.15 and r.x > 0.15, "%s: слева и справа %s %s" % [id, l, r])
			check(absf(l.x + r.x) < 0.02 and l.distance_to(Vector3(-r.x, r.y, r.z)) < 0.02,
				"%s: симметрично" % id)
			check(l.y > bb.y + 0.3 and l.y < bb.y + 0.8 and l.z < bb.z, "%s: на переднем тросе, ~30%% высоты трапеции над штангой, впереди неё (%.2f)" % [id, l.y - bb.y])
		v.free()


func test_glider_crosswind_on_launch() -> void:
	var g := Glider.new()
	g.auto_start = Glider.AutoStart.NONE
	g.setup("sport")
	var wind := Vector3(0, 0, -5).rotated(Vector3.UP, deg_to_rad(-90))  # дует на восток
	g.set_air_fn(func(_p: Vector3) -> Vector3: return wind)
	add_child(g)
	g.reset_on_ground(Vector3.ZERO, 0.0)
	g.control = ControlInput.new()
	for i in 240:
		g.step(DT)
	check(g.visual.telltales.size() == 2, "у планера две ленточки")
	for t in g.visual.telltales:
		check(t.visible, "после шага ленточка видна")
		var d := t.model.direction()
		var w := wind - g.model.velocity
		check(_deg(d, w) < 15.0, "на старте ленточка по ветру: %.1f° (%s, %s)" % [_deg(d, w), d, w])
	g.free()
