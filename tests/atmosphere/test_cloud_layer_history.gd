extends TestCase
## Какие облака рисуются и насколько они проявлены — функция времени атмосферы (и камеры), а не
## истории кадров (NET-00, найдено в NET-40: вошедший в зону не видел тающих Cb/наковален).
## Слой A летит с атмосферой от 0 до t, слой B создан сразу в t (Atmosphere.start_at) — при той же
## камере у них тот же набор облаков и та же видимость (до 1e-3) в t = 600 и 3600 с. Второй
## случай — с урезанным лимитом max_clouds (работает обрезка по дальности).

const TOL := 1.0e-3
const EYE := AtmoFingerprint.CENTER + Vector3(0.0, 1500.0, 0.0)


static func _world(max_clouds: int) -> Atmosphere:
	var cfg := {}
	if max_clouds > 0:
		cfg = Config.get_config("atmosphere").duplicate(true)
		cfg.thermal.generation_radius_m = AtmoFingerprint.GEN_RADIUS_M
		cfg.clouds.max_clouds = max_clouds
	return AtmoFingerprint.make_world(AtmoFingerprint.DEFAULT_KEY, cfg)


static func _layer(a: Atmosphere) -> CloudLayer:
	var layer := CloudLayer.new()
	layer.setup(a)
	layer._select(a.time_s, EYE)
	return layer


## id -> [доля выбора, видимость записи] для всех облаков в слотах.
static func _state(layer: CloudLayer, t: float) -> Dictionary:
	layer._select(t, EYE)
	var out: Dictionary = {}
	for i in layer._slot_th.size():
		var th: AtmoThermal = layer._slot_th[i]
		if th == null:
			continue
		layer._place(i, t, EYE)
		if layer._slot_th[i] != null:
			out[th.id] = [layer._sel[i], layer._rec[i][20], th.is_cb]
	return out


func _compare(sa: Dictionary, sb: Dictionary, what: String) -> void:
	var bad: Array = []
	for id in sa:
		var va: Array = sa[id]
		var vb: Array = sb.get(id, [0.0, 0.0, false])
		if absf(float(va[0]) - float(vb[0])) > TOL or absf(float(va[1]) - float(vb[1])) > TOL:
			bad.append("id=%d A=%.3f/%.3f B=%.3f/%.3f" % [id, va[0], va[1], vb[0], vb[1]])
	for id in sb:
		if not sa.has(id):
			bad.append("id=%d только у B: %.3f/%.3f" % [id, sb[id][0], sb[id][1]])
	check(bad.is_empty(), "%s: расхождения %s" % [what, bad.slice(0, 8)])


func _run(max_clouds: int, times: Array) -> void:
	var a := _world(max_clouds)
	var la := _layer(a)
	for t: float in times:
		while a.time_s < t - 1.0e-9:
			a.step(minf(1.0, t - a.time_s))
			la._select(a.time_s, EYE)
		a.time_s = t
		a.refresh_now()
		var sa := _state(la, t)
		var b := _world(max_clouds)
		b.start_at(t)
		var lb := _layer(b)
		var sb := _state(lb, t)
		var partial := 0
		var cb := 0
		for id in sa:
			if float(sa[id][0]) < 0.999:
				partial += 1
			if sa[id][2]:
				cb += 1
		print("    t=%.0f лимит=%d: облаков %d (тающих/проявляющихся %d, Cb %d)" % [
			t, max_clouds, sa.size(), partial, cb])
		check(sa.size() > 3, "облака есть (%d)" % sa.size())
		_compare(sa, sb, "t=%.0f, лимит %d" % [t, max_clouds])
		lb.free()
		b.free()
	la.free()
	a.free()


func test_fresh_layer_matches_running() -> void:
	_run(0, [600.0, 3600.0])


func test_fresh_layer_matches_running_with_cap() -> void:
	_run(12, [600.0])
