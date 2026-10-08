extends TestCase
## PF-8: выбор облаков порциями по кадрам (CloudLayer._select_begin / _select_pump) даёт тот же набор
## облаков и их состояние, что одноразовый _select (одиночная игра, с таянием).

const EYE := Vector3(0.0, 1200.0, 0.0)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _state(layer: CloudLayer) -> Dictionary:
	var out: Dictionary = {}
	for id in layer._slot_of:
		var s: int = layer._slot_of[id]
		out[id] = [layer._want[s], layer._sel[s], layer._rec[s][0] if not layer._rec[s].is_empty() else -1.0]
	return out


func test_chunked_select_equals_sync() -> void:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config("weather/medium"), {"wind_speed_kmh": 15.0})
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	a.time_s = 3600.0
	a.set_focus(EYE)
	a.step(0.0)
	var sync_l := CloudLayer.new()
	sync_l.setup(a)
	var chunk_l := CloudLayer.new()
	chunk_l.setup(a)
	chunk_l.select_budget_us = 150
	var pumps_total := 0
	var pos := EYE
	for k in 6:
		pos += Vector3(900.0, 0.0, 300.0)
		a.set_focus(pos)
		a.step(30.0)
		var t := a.time_s
		sync_l._select(t, pos)
		sync_l._update_fades(30.0)
		if k == 0:
			# первый выбор после старта — «мгновенный» (_instant): порциями идёт со второго
			chunk_l._select(t, pos)
			chunk_l._update_fades(30.0)
		else:
			chunk_l._select_begin(t, pos)
			var pumps := 0
			while chunk_l._sj:
				chunk_l._select_pump()
				pumps += 1
				if pumps > 100000:
					break
			pumps_total += pumps
			chunk_l._update_fades(30.0)
		var sa := _state(sync_l)
		var sb := _state(chunk_l)
		check(not sa.is_empty(), "шаг %d: облака выбраны (%d)" % [k, sa.size()])
		check(sa == sb, "шаг %d: набор и состояние облаков те же (%d / %d)" % [k, sa.size(), sb.size()])
		check(sync_l._wave_rec.size() == chunk_l._wave_rec.size(), "шаг %d: волновые облака те же" % k)
	check(pumps_total > 5, "выбор действительно разбит по кадрам (%d шагов)" % pumps_total)
	sync_l.free()
	chunk_l.free()
	a.free()
