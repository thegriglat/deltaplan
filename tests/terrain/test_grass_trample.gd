extends TestCase
## Примятая трава (SC-3): построение маски TrampleMask по пятнам, цена, ограничения шейдера.

const TENTS := {"types": {"dome2": {"half_size_m": [0.8, 1.3]}}}


func _value(m: Dictionary, x: float, z: float) -> float:
	var o: Vector2 = m.origin
	var c: float = m.cell_m
	var img: Image = m.image
	return img.get_pixel(int((x - o.x) / c), int((z - o.y) / c)).r


func test_tent_is_rotated_box() -> void:
	# палатка 0,8 x 1,3 повёрнута на 90°: длинная сторона вдоль x
	var camp := [
		{
			"type": "dome2",
			"position": Vector3(0, 0, 0),
			"basis": Basis(Vector3.UP, PI / 2.0),
			"yaw": PI / 2.0,
		}
	]
	var m := TrampleMask.build(Vector3(100, 0, 100), camp, [], [], TENTS)
	var along_x := _value(m, 1.2, 0.0)
	var along_z := _value(m, 0.0, 1.2)
	check(along_x > 0.85, "вдоль длинной стороны (x) пятно: %.2f" % along_x)
	check(along_z < along_x, "по z (короткая сторона) уже спад: %.2f" % along_z)


func test_gear_and_track() -> void:
	var gear := [{"position": Vector3(-10, 0, -10), "radius_m": 1.0}]
	var track := PackedVector2Array([Vector2(0, 0), Vector2(0, 40)])
	var m := TrampleMask.build(Vector3(0, 0, 0), [], gear, [track], TENTS)
	approx(_value(m, -10, -10), 0.7, 0.02, "пятно вещи 0,7")
	var edge := _value(m, -10, -8.75)
	check(edge > 0.05 and edge < 0.65, "спад у края пятна вещи: %.2f" % edge)
	approx(_value(m, -10, -8.2), 0.0, 0.01, "за краем пятна вещи нетронуто")
	approx(_value(m, 0.1, 30.0), 0.5, 0.02, "тропа 0,5")
	approx(_value(m, 5.0, 30.0), 0.0, 0.01, "рядом с тропой нетронуто")


func test_run_circle() -> void:
	var m := TrampleMask.build(Vector3(0, 0, 0), [], [], [], TENTS)
	approx(_value(m, 0.0, 3.0), 0.5, 0.02, "круг разбега 0,5")
	approx(_value(m, 0.0, 10.0), 0.0, 0.01, "за кругом нетронуто")


func test_build_cost() -> void:
	var camp: Array = []
	for i in 6:
		camp.append(
			{
				"type": "dome2",
				"position": Vector3(-30 - i * 4, 0, 10 * i - 25),
				"basis": Basis(Vector3.UP, i),
				"yaw": float(i),
			}
		)
	var gear: Array = []
	for i in 20:
		gear.append({"position": Vector3(-8 - i, 0, -5 + i), "radius_m": 1.5})
	var pts := PackedVector2Array()
	for i in 80:
		pts.append(Vector2(sin(i * 0.2) * 5.0, 4.0 * i))
	var t0 := Time.get_ticks_usec()
	var m := TrampleMask.build(Vector3.ZERO, camp, gear, [pts], TENTS)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("  trample_mask: 6 палаток, 20 вещей, тропа 320 м — %.1f мс" % ms)
	check(m.image != null, "картинка есть")
	check(ms < 150.0, "построение маски %.1f мс" % ms)


func test_shader_outside_unchanged() -> void:
	# без маски (trample_on = 0) высота/наклон/цвет не зависят от шейдерных добавок
	var src := FileAccess.get_file_as_string("res://scripts/terrain/grass.gdshader")
	check(src.contains("hh *= mix(1.0, trample_height_k, tr);"), "высота через tr")
	check(src.contains("if (trample_on > 0.5)"), "выборка маски только при trample_on")
	check(src.count("trample_tex") == 2, "одна выборка текстуры маски: %d" % src.count("trample_tex"))
