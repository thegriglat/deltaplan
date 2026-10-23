extends Node
## Проба gdext: add/sum и фоновый поток Rust не вешает главный поток.

func _ready() -> void:
	var p = ClassDB.instantiate("Probe")  # класс расширения; без типа - чтобы check_gd игры не ругался
	print("add=", p.add(2, 3))
	var arr := PackedFloat32Array()
	arr.resize(1000000)
	arr.fill(0.5)
	print("sum=", p.sum(arr))
	p.start(1000)
	var t0 := Time.get_ticks_msec()
	var frames := 0
	var max_gap := 0
	var last := t0
	while not p.is_done():
		await get_tree().process_frame
		frames += 1
		var now := Time.get_ticks_msec()
		max_gap = maxi(max_gap, now - last)
		last = now
	print("done after ms=", Time.get_ticks_msec() - t0, " frames=", frames, " max_frame_gap_ms=", max_gap, " result=", p.take_result())
	print("result_again=", p.take_result())
	get_tree().quit()
