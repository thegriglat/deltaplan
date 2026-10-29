extends TestCase
## PF-8: выбор облаков порциями по кадрам (CloudLayer._select_begin / _select_pump) даёт тот же набор
## облаков и их состояние, что одноразовый _select (одиночная игра, с таянием).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const EYE := Vector3(0.0, 1200.0, 0.0)


## Грозовой день на малом месте, состояние на 3600 с (фасад W2: Rig, start_at).
static func _storm() -> Atmosphere:
	return Rig.make(
		{"preset": "weather/storm", "over": {"wind_speed_kmh": 15.0}, "start_at": 3600.0, "focus": EYE, "advance": 0.0,
		"half": 11000.0, "cache": true}
	)


func _state(layer: CloudLayer) -> Dictionary:
	var out: Dictionary = {}
	for id in layer._slot_of:
		var s: int = layer._slot_of[id]
		out[id] = [layer._want[s], layer._sel[s], layer._rec[s][0] if not layer._rec[s].is_empty() else -1.0]
	return out


func test_chunked_select_equals_sync() -> void:
	var a := _storm()
	var sync_l := CloudLayer.new()
	sync_l.setup(a)
	var chunk_l := CloudLayer.new()
	chunk_l.setup(a)
	chunk_l.select_budget_us = 150
	var pumps_total := 0
	var pos := EYE
	for k in 6:
		pos += Vector3(900.0, 0.0, 300.0)
		Rig.focus(a, pos)
		Rig.step(a, 30.0)
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


## Родная сортировка по очкам и порционное слияние дают тот же список, что прежние sort_custom + _drop_overlaps.
func test_sort_and_drop_equal_old() -> void:
	var a := _storm()
	Rig.step(a, 60.0)
	var m := CloudModel.new()
	m.setup(Config.get_config("atmosphere").clouds)
	var objs := CloudModel.parse(a.cloud_objects(Vector3.ZERO, -1.0, a.time_s), a.time_s)
	var cand: Array = []
	for id in objs:
		var e := m.select_entry(objs[id], a.time_s, EYE, {})
		if not e.is_empty():
			cand.append(e)
	var old := cand.duplicate()
	old.sort_custom(m._by_score)
	var old_list: Array = m._drop_overlaps(old)
	var st := m.drop_begin(CloudModel.sort_by_score(cand))
	var steps := 0
	while not m.drop_step(st, Time.get_ticks_usec() + 50):
		steps += 1
	check(cand.size() > 50, "кандидатов достаточно: %d" % cand.size())
	var ia: Array = []
	var ib: Array = []
	for e: Array in old_list:
		ia.append((e[1] as CloudModel.Obj).id)
	for e: Array in st.out:
		ib.append((e[1] as CloudModel.Obj).id)
	check(ia == ib and not ia.is_empty(), "тот же список после слияния (%d / %d), шагов %d" % [ia.size(), ib.size(), steps])
	a.free()
