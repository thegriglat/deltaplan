extends Node
## Наручные приборы PH-7 (PH-К2, PH-К4, PH-К5): стрелки часов, угол картушки на север, инерция
## жидкостного компаса, видимость по флажкам, крепление к пустышкам пилота.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])


const PILOT := "res://assets/models/pilot.glb"


func _pm() -> Node3D:
	var pm := Node3D.new()
	for n in ["WristL", "WristR"]:
		var w := Node3D.new()
		w.name = n
		pm.add_child(w)
	return pm


func _wi(pm: Node3D, c: SunClock = null) -> WristInstruments:
	add_child(pm)
	var wi := WristInstruments.new()
	add_child(wi)
	check(wi.attach(pm), "приборы прикрепились к пустышкам")
	wi.set_clock(c)
	return wi


## Базис запястья, циферблат смотрит вверх, «12 часов» — по курсу heading_deg (0 — север, 90 — восток).
func _basis_up(heading_deg: float) -> Basis:
	var r := deg_to_rad(heading_deg)
	var y := Vector3(sin(r), 0, -cos(r))
	var z := Vector3(0, -1, 0)
	return Basis(y.cross(z), y, z)


func test_wrist_hands_ph_k4() -> void:
	var c := SunClock.new()
	var wi := _wi(_pm(), c)
	c.hour = 6.0
	wi.update_hands()
	approx(wi._hour_hand.rotation.z, PI, 1e-5, "6:00 часовая")
	approx(wi._minute_hand.rotation.z, 0.0, 1e-5, "6:00 минутная")
	c.hour = 12.5
	wi.update_hands()
	approx(wi._hour_hand.rotation.z, TAU * 0.5 / 12.0, 1e-5, "12:30 часовая (15°)")
	approx(wi._minute_hand.rotation.z, PI, 1e-5, "12:30 минутная")
	c.hour = 18.25
	wi.update_hands()
	approx(wi._hour_hand.rotation.z, TAU * 6.25 / 12.0, 1e-5, "18:15 часовая")
	approx(wi._minute_hand.rotation.z, TAU * 0.25, 1e-5, "18:15 минутная")
	check(c.hour == 18.25, "время не продвигается")
	wi.get_parent().queue_free()
	wi.queue_free()


func test_wrist_north_angle_steady_state() -> void:
	for hd in [0.0, 37.0, 90.0, 180.0, 250.0, 359.0]:
		var na := WristInstruments.north_angle(_basis_up(hd))
		approx(na.y, 1.0, 1e-4, "циферблат горизонтален — проекция 1")
		# север относительно носа: −курс; N на картушке должен смотреть на север
		var expect := wrapf(-deg_to_rad(hd), -PI, PI)
		approx(rad_to_deg(wrapf(na.x - expect, -PI, PI)), 0.0, 0.5, "курс %.0f°" % hd)
	var wi := WristInstruments.new()
	for hd in [10.0, 120.0, 300.0]:
		wi.card_angle = 0.0
		wi.card_rate = 0.0
		wi.set_target(WristInstruments.north_angle(_basis_up(hd)).x)
		for _i in 600:
			wi.step_card(1.0 / 60.0)
		var e := rad_to_deg(wrapf(wi.card_angle - wi._target, -PI, PI))
		approx(e, 0.0, 3.0, "установившееся, курс %.0f°" % hd)
	wi.free()


func test_wrist_card_transient_decays() -> void:
	var wi := WristInstruments.new()
	wi.card_angle = 0.0
	wi.set_target(deg_to_rad(90.0))
	var peak := 0.0
	var err_1s := 0.0
	var err_3s := 0.0
	for i in 360:
		wi.step_card(1.0 / 60.0)
		peak = maxf(peak, wi.card_angle)
		if i == 59:
			err_1s = absf(wi._target - wi.card_angle)
		if i == 179:
			err_3s = absf(wi._target - wi.card_angle)
	check(peak > wi._target * 0.99, "картушка доходит до цели")
	check(peak < wi._target * 1.2, "заброс небольшой (ζ 0,6): %.0f°" % rad_to_deg(peak))
	check(err_3s < err_1s or err_1s < deg_to_rad(1.0), "колебания затухают")
	check(err_3s < deg_to_rad(3.0), "за 3 с ближе 3°: %.1f°" % rad_to_deg(err_3s))
	# инерция: за первые 0,1 с картушка проходит малую часть
	var w2 := WristInstruments.new()
	w2.set_target(deg_to_rad(90.0))
	for i in 6:
		w2.step_card(1.0 / 60.0)
	check(w2.card_angle < deg_to_rad(20.0), "инерция: за 0,1 с %.0f°" % rad_to_deg(w2.card_angle))
	# кратчайший путь через ±180°
	var w3 := WristInstruments.new()
	w3.card_angle = deg_to_rad(170.0)
	w3.set_target(deg_to_rad(-170.0))
	w3.step_card(1.0 / 60.0)
	check(w3.card_rate > 0.0, "через ±180° — кратчайшим путём")
	wi.free()
	w2.free()
	w3.free()


func test_wrist_compass_in_tree_holds_when_vertical() -> void:
	var pm := _pm()
	var wi := _wi(pm)
	var wr := pm.get_node("WristR") as Node3D
	wr.global_transform = Transform3D(_basis_up(90.0), Vector3.ZERO)
	wi.update_compass(0.016)
	var a0 := wi._card.rotation.z
	approx(rad_to_deg(wrapf(a0 - (-PI / 2), -PI, PI)), 0.0, 0.5, "первый кадр — сразу на север (курс 90°)")
	# нормаль циферблата = север → проекция 0: угол и цель держатся
	wr.global_transform = Transform3D(Basis(Vector3(0, 0, 1), 0.0), Vector3.ZERO)  # нормаль = север → проекция 0
	var tgt := wi._target
	for _i in 120:
		wi.update_compass(1.0 / 60.0)
	approx(wi._target, tgt, 1e-6, "вертикальный циферблат: цель не меняется")
	check(absf(wi._card.rotation.z) < PI, "картушка конечна")
	pm.queue_free()
	wi.queue_free()


func test_wrist_visibility_flags() -> void:
	var ui: Dictionary = Config.get_config("ui")
	var old_clock: Variant = ui.get("clock", {}).get("enabled", true)
	var old_comp: Variant = ui.get("compass", {}).get("enabled", true)
	var c := SunClock.new()
	var pm := _pm()
	var wi := _wi(pm, c)
	check(wi.is_watch_shown() and wi.is_compass_shown(), "по умолчанию оба видны")
	ui["clock"]["enabled"] = false
	wi.reload()
	check(not wi.is_watch_shown(), "флажок «Часы» выключен — часов нет")
	check(wi.is_compass_shown(), "компас остаётся")
	ui["compass"]["enabled"] = false
	wi.reload()
	check(not wi.is_compass_shown(), "флажок «Компас» выключен — компаса нет")
	ui["clock"]["enabled"] = old_clock
	ui["compass"]["enabled"] = old_comp
	wi.reload()
	check(wi.is_watch_shown() and wi.is_compass_shown(), "включены обратно")
	wi.set_clock(null)
	check(not wi.is_watch_shown(), "без часов игры часы скрыты")
	pm.queue_free()
	wi.queue_free()


func _pose_prone(v: GliderVisual) -> void:
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(3.0)
	for i in 4:
		v.set_pose(0.0, 0.0, true, 1.0e6)
		await get_tree().process_frame


func test_wrist_on_real_pilot_and_visible_layers() -> void:
	var v := GliderVisual.new()
	add_child(v)
	v.set_wrist_clock(SunClock.new())
	v.build(Config.get_config("wings/sport"), Config.get_config("pilot"), Config.get_config("flight").visual)
	check(v.wrist != null, "GliderVisual создал приборы на запястьях")
	if v.wrist != null:
		# приборы жёстко на кисти (пустышка хвата HandL/HandR), не на предплечье
		var hl := v.find_child("HandL", true, false)
		var hr := v.find_child("HandR", true, false)
		check(hl != null and v.wrist.watch.get_parent().get_parent() == hl, "часы на кисти HandL")
		check(hr != null and v.wrist.compass.get_parent().get_parent() == hr, "компас на кисти HandR")
		check(v.wrist.is_watch_shown(), "часы видны")
		# PH-К5: приборы на слое 1, который видит кабинная камера (скрыт только бит шлема)
		var bad := 0
		for mi in v.wrist.watch.find_children("*", "VisualInstance3D", true, false):
			if (mi as VisualInstance3D).layers & 1 == 0:
				bad += 1
		for mi in v.wrist.compass.find_children("*", "VisualInstance3D", true, false):
			if (mi as VisualInstance3D).layers & 1 == 0:
				bad += 1
		check(bad == 0, "ноды приборов на слое 1 (видны кабинной камере)")
		v.set_cockpit_body("hands")
		check(v.wrist.is_watch_shown(), "в кабине (hands) приборы остаются")
	v.queue_free()


## Манжеты (краг) нет, прибор с ремешком стоит вплотную перед срезом перчатки, циферблатом к глазам.
func test_wrist_instruments_at_glove_edge() -> void:
	var v := GliderVisual.new()
	add_child(v)
	v.set_wrist_clock(SunClock.new())
	v.build(Config.get_config("wings/sport"), Config.get_config("pilot"), Config.get_config("flight").visual)
	await _pose_prone(v)
	var sk := v.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var body := v.find_child("PilotBody", true, false) as MeshInstance3D
	# в меш визуала манжет нет, в общей модели они есть
	var fresh := ((load(PILOT) as PackedScene).instantiate() as Node3D).find_child("PilotBody", true, false) as MeshInstance3D
	var cut_n := _glove_indices(body.mesh)
	check(cut_n < _glove_indices(fresh.mesh), "из перчаток убраны манжеты: %d < %d индексов" % [cut_n, _glove_indices(fresh.mesh)])
	fresh.get_parent().free()
	var openings := PilotGloveCut.cut(body, sk)
	check(_glove_indices(body.mesh) == cut_n, "повторный разрез ничего не убирает (манжет не осталось)")
	var eye := v.head_marker.global_position
	for side in ["L", "R"]:
		check(openings.has(side), "срез перчатки %s найден" % side)
		if not openings.has(side):
			continue
		var inst: Node3D = v.wrist.watch if side == "L" else v.wrist.compass
		var grip := v.find_child("Hand" + side, true, false) as Node3D
		var bone := grip.global_transform * grip.transform.affine_inverse()  # кость кисти
		var strap := inst.find_child("Strap", true, false) as MeshInstance3D
		var sb := strap.get_aabb()
		# лента вдоль кисти (локальный Y кости): до среза перчатки 0…3 мм
		var o := bone.affine_inverse() * inst.global_transform.origin
		var y_hi := o.y + sb.end.y
		var y_lo := o.y + sb.position.y
		var edge: float = openings[side].y
		check(edge - y_hi >= -0.0005 and edge - y_hi <= 0.003, "%s: ремешок вплотную перед срезом, зазор %.1f мм" % [side, (edge - y_hi) * 1000.0])
		check(y_lo < edge - 0.015, "%s: ремешок не уходит внутрь перчатки" % [side])
		# кольцо охватывает сечение запястья: центр кольца на оси кисти (по X/Z кости)
		var c: Vector3 = openings[side].center
		var ring_c := bone.affine_inverse() * (inst.global_transform * Vector3(0, 0, v.wrist.RING_H_M * 0.5))
		check(Vector2(ring_c.x - c.x, ring_c.z - c.z).length() < 0.003, "%s: кольцо соосно запястью" % side)
		# циферблат смотрит к глазам
		var facing := (-inst.global_basis.z).dot((eye - inst.global_position).normalized())
		check(facing > 0.7, "%s: циферблат к пилоту, cos %.2f" % [side, facing])
	v.queue_free()


func _glove_indices(m: Mesh) -> int:
	for s in m.get_surface_count():
		var mt := m.surface_get_material(s)
		if mt != null and mt.resource_name.begins_with("Glove"):
			return (m.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	return -1
