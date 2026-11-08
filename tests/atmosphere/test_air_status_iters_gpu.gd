extends TestCase
## W2 v3: status().iters на экране подготовки воздуха (RW-3c). Поле Онгудая считает крейт (DpAir,
## CPU; RW-7b — GPU-путь фасад не вызывает), режим поля «on»: пока идёт этап расчёта, status().stage —
## подпись, iters — int ≥ 0, не убывает и растёт (шаг 10 итераций, обновляется каждый кадр pump); после READY этапа нет, iters = 0.
## tools/gpu_tests.sh --filter=air_status_iters

const ID := "ongudai"


func needs_gpu() -> bool:
	return true


func _root() -> Node:
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	return tree_root.get_child(tree_root.get_child_count() - 1)


func test_iters_grow_during_solver_stage() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location(ID), "Онгудай загрузился")
	t.wait_relief()
	var utc := float(Config.get_config("locations/" + ID).get("utc_offset_h", NAN))
	var host := Node.new()
	_root().add_child(host)
	var a := Atmosphere.new()
	a.visuals_enabled = false
	host.add_child(a)
	var p: AirPlaceData = await a.place_from_terrain(t, utc, 7, 15)
	check(p != null, "место из рельефа")
	if p == null:
		host.queue_free()
		return
	check(a.configure(77) == 0, "configure")
	# ветер, которого нет среди запечённых полей старта: решатель считает поле с нуля
	var cond := {
		"forecast":
		{"temperature_c": 26.0, "wind_speed_kmh": 17.3, "wind_from_deg": 131.0, "sky": "clear"},
		"start_hour": 12.0,
	}
	check(a.set_conditions(cond) == 0, "set_conditions")
	check(a.load_place(p) == 0, "load_place")
	a.set_focuses(PackedVector3Array([Vector3(0, 900, 0)]), PackedFloat32Array([1.0]))
	a.start_at(0.0)
	var tree := Engine.get_main_loop() as SceneTree
	var solver_frames := 0
	var last := 0
	var max_it := 0
	var monotonic := true
	var label := ""
	for i in 60000:
		a.pump(8000)
		var st: Dictionary = a.status()
		check(typeof(st.iters) == TYPE_INT and int(st.iters) >= 0, "iters — int ≥ 0")
		check(st.has("stage") and st.has("field_on"), "stage и field_on в status")
		if String(st.stage) != "":
			solver_frames += 1
			label = String(st.stage)
			if int(st.iters) < last:
				monotonic = false
			last = int(st.iters)
			max_it = maxi(max_it, last)
		if int(st.state) != Atmosphere.STATE_LOADING:
			break
		await tree.process_frame
	check(a.is_ready(), "дошёл до READY")
	check(solver_frames > 0, "этап «solver» с подписью был (%d кадров): %s" % [solver_frames, label])
	check(monotonic, "iters в этапе не убывает")
	check(max_it > 0 and max_it % 10 == 0, "iters растёт десятками: %d" % max_it)
	var done: Dictionary = a.status()
	check(String(done.stage) == "" and int(done.iters) == 0, "после READY этапа нет, iters = 0")
	check(bool(done.field_on), "поле Пикара включено")
	print("    status.iters: итераций в этапе %d за %d кадров" % [max_it, solver_frames])
	host.queue_free()
	t.free()
