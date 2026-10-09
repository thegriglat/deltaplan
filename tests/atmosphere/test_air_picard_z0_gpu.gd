extends TestCase
## z0 по покрову в решателе (SH-6, C2 v9): C_d стенки и u* замыкания — по столбцу (плоскости
## AirCase.COL_CD, COL_UST, чтение в air_picard.glsl). Синтетика: ровная земля, ветер с запада,
## западная половина — луг (z0 0,03 м), восточная — лес (1 м). Над лесом у земли тише, чем над
## лугом; карта из одного значения = прежний скаляр (поле побитно то же); две сборки — побитно одно поле.
## tools/gpu_tests.sh --filter=air_picard_z0. В headless пропускается.

const NX := 32
const NY := 16
const DX := 200.0


func needs_gpu() -> bool:
	return true


static func _case(z0_map: PackedFloat64Array) -> AirCase:
	var c := AirCase.new()
	var dz := DX / 2.0
	c.set_grid(DX, NX, NY, dz, 400.0, 24, 0.0, 0.0)
	c.hc.resize(NX * NY)
	c.hc.fill(500.0)
	c.gam.resize(c.nz + 2)
	c.gam.fill(0.003)
	c.u10 = 5.0
	c.u10_menu = 5.0
	c.wdir = 270.0
	c.label = "z0 синтетика"
	c.set_z0_map(z0_map)
	return c


static func _split_map(z_w: float, z_e: float) -> PackedFloat64Array:
	var m := PackedFloat64Array()
	m.resize(NX * NY)
	for j in NY:
		for i in NX:
			m[j * NX + i] = z_w if i < NX / 2 else z_e
	return m


func _solve(c: AirCase) -> WindField:
	var job := AirPicardJob.new()
	job.case = c
	job.mech = false
	if not job.start():
		failures.append("start: " + job.error)
		return null
	var frames := 0
	while not job.is_done() and job.error == "" and frames < 100000:
		await Engine.get_main_loop().process_frame
		job.poll()
		frames += 1
	check(job.is_done(), "%s: решено (%s)" % [c.label, job.error])
	var f := job.field()
	job.release()
	return f


## Средняя |U_h| на высоте agl над землёй по столбцам i ∈ [i0, i1), средние строки.
static func _mean_u(f: WindField, i0: int, i1: int, agl: float) -> float:
	var s := 0.0
	var n := 0
	for j in range(NY / 2 - 2, NY / 2 + 2):
		for i in range(i0, i1):
			var p := Vector3((i + 0.5) * DX, 500.0 + agl, -(j + 0.5) * DX)
			var v := f.sample(p, 500.0)
			s += Vector2(v.x, v.z).length()
			n += 1
	return s / n


func test_forest_vs_meadow() -> void:
	var fm: WindField = await _solve(_case(_split_map(0.03, 1.0)))
	var fu: WindField = await _solve(_case(_split_map(0.03, 0.03)))
	check(fm != null and fu != null, "поля решены")
	if fm == null or fu == null:
		return
	# над лесом (восточная половина, вдали от края и от границы луг/лес) против луга того же места
	var i_f0 := NX / 2 + 4
	var i_f1 := NX - 6
	var u_for := _mean_u(fm, i_f0, i_f1, 30.0)
	var u_gr := _mean_u(fu, i_f0, i_f1, 30.0)
	var u_up := _mean_u(fm, 6, NX / 2 - 2, 30.0)
	var u_up0 := _mean_u(fu, 6, NX / 2 - 2, 30.0)
	print("  U(30 м): лес %.2f, тот же участок лугом %.2f, ×%.3f; луг перед лесом %.2f / %.2f м/с" % [u_for, u_gr, u_for / u_gr, u_up, u_up0])
	check(u_for < 0.97 * u_gr, "над лесом на 30 м тише луга: %.2f < %.2f" % [u_for, u_gr])
	var t_for := fm.turb_at(Vector3((i_f0 + 2) * DX, 560.0, -NY * DX / 2.0), 500.0)
	var t_gr := fu.turb_at(Vector3((i_f0 + 2) * DX, 560.0, -NY * DX / 2.0), 500.0)
	print("  u* поля: лес %.3f, луг %.3f м/с" % [t_for[WindField.T_USTAR], t_gr[WindField.T_USTAR]])
	check(t_for[WindField.T_USTAR] > t_gr[WindField.T_USTAR], "u* над лесом больше")
	# карта из одного значения 0,1 = прежний скаляр (без карты): поле побитно то же
	var f1: WindField = await _solve(_case(_split_map(AirCase.Z0, AirCase.Z0)))
	var f0: WindField = await _solve(_case(PackedFloat64Array()))
	check(f1 != null and f0 != null and f1.raw_vel() == f0.raw_vel(), "однородная карта 0,1 = скаляр 0,1 (побитно)")
	# детерминизм: та же карта — то же поле
	var fm2: WindField = await _solve(_case(_split_map(0.03, 1.0)))
	check(fm2 != null and fm2.raw_vel() == fm.raw_vel(), "две сборки с картой — побитно одно поле")
