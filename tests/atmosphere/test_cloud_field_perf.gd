extends TestCase
## Цена шага CloudField на сетке региона 96 × 96 (CLF-К1: ≤ 15 мс на внутренний шаг, headless):
## синтетические входы по столбцам (прямо в поле, без AirThermals), медиана 10 шагов.
## Печатает cloud_field_step_ms=<мс>.

const N := 96
const DX := 400.0


func test_step_cost() -> void:
	var cfg: Dictionary = Config.get_config("atmosphere").cloud_field
	var cf := CloudField.new(cfg)
	cf.setup_grid(N, N, DX, -N * DX * 0.5, -N * DX * 0.5)
	cf.base_msl = 2000.0
	var n := N * N
	var au := PackedFloat32Array()
	au.resize(n)
	var ds := PackedFloat32Array()
	ds.resize(n)
	var vx := PackedFloat32Array()
	vx.resize(n)
	var vz := PackedFloat32Array()
	vz.resize(n)
	var hc := PackedFloat32Array()
	hc.resize(n)
	for j in N:
		for i in N:
			var c := j * N + i
			var r := Vector2(i - 48.0, j - 48.0).length()
			au[c] = 0.3 * maxf(1.0 - r / 30.0, 0.0) * (0.5 + 0.5 * sin(i * 0.7) * cos(j * 0.5))
			ds[c] = 1200.0 * maxf(1.0 - r / 40.0, 0.0)
			vx[c] = 5.0 + 1.0 * sin(j * 0.3)
			vz[c] = 1.0 * cos(i * 0.3)
			hc[c] = 1000.0 + 500.0 * sin(i * 0.2)
	cf._au0 = au.duplicate()
	cf._au1 = au
	cf._ds0 = ds.duplicate()
	cf._ds1 = ds
	cf._vx = vx
	cf._vz = vz
	cf._hc = hc
	cf._mean_v = Vector2(5.0, 0.0)
	cf._has_inputs = true
	cf._started = true
	cf._depth_day = 1000.0
	var dt := float(cfg.step_s)
	# прогрев: несколько шагов, чтобы перенос уже случался
	for k in 5:
		cf._step(dt)
	var times: Array[float] = []
	for k in 10:
		var t0 := Time.get_ticks_usec()
		cf._step(dt)
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	var med := times[times.size() / 2]
	print("cloud_field_step_ms=%.2f (мин %.2f, макс %.2f)" % [med, times[0], times[times.size() - 1]])
	check(med <= 15.0, "шаг 96 × 96 ≤ 15 мс (медиана %.2f)" % med)
	check(cf.bg_cover > 0.0, "поле не пустое")
