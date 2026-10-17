extends TestCase
## CloudField (CLF-К1): источник — подъём, дошедший до LCL; инварианты; детерминизм; снимок и
## текстура; аналитический путь; задержка таяния; снос ветром; слабый день < сильный.

const N := 48
const NZ := 40
const DX := 400.0
const DZ := 100.0
const GROUND := 1000.0
const Z_BOT := 950.0


## Синтетическое поле N × N × NZ (dx 400 м, ровная земля GROUND): heat(x, z) Вт/м², z_i, ветер
## (мир x, z) м/с, фон нейтральный до z_i, выше gam_above.
static func flat_field(
	heat_fn: Callable, z_i: float, wind := Vector2.ZERO, gam_above := 0.0058
) -> WindField:
	var m := {
		dx = DX, dz = DZ, x0 = -N * DX * 0.5, y0 = -N * DX * 0.5, z_bot = Z_BOT,
		nx = N, ny = N, nz = NZ, z0 = 0.1, z_i = z_i, u10 = wind.length() / 1.8,
	}
	var gam := []
	for k in NZ:
		gam.append(0.0 if Z_BOT + (k + 0.5) * DZ < z_i else gam_above)
	m["gam"] = gam
	var n := N * N * NZ
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	for a: PackedFloat32Array in [u, v, wm, wc, th]:
		a.resize(n)
	u.fill(wind.x)
	v.fill(-wind.y)
	var hc := PackedFloat32Array()
	hc.resize(N * N)
	hc.fill(GROUND)
	var heat := PackedFloat32Array()
	heat.resize(N * N)
	for j in N:
		for i in N:
			var x: float = m.x0 + (i + 0.5) * DX
			var zw: float = -(m.y0 + (j + 0.5) * DX)
			heat[j * N + i] = float(heat_fn.call(x, zw))
	m["heat"] = heat
	return WindField.from_arrays(m, u, v, wm, wc, th, hc)


static func thermals_cfg(cb: float = 1.0e9) -> Dictionary:
	var c: Dictionary = Config.get_config("atmosphere").thermal.duplicate()
	var w: Dictionary = Config.get_config("weather/medium")
	c["duty"] = float(w.thermal_duty)
	c["cloudbase_msl"] = cb
	return c


## Нагрев пятном радиуса r у (cx, cz), Вт/м² (вне — 0).
static func blob(cx: float, cz: float, r: float, h: float) -> Callable:
	return func(x: float, z: float) -> float:
		return h if Vector2(x - cx, z - cz).length() < r else 0.0


static func weather(z_lcl: float, depth_m := 800.0, overdev := 0.0) -> Dictionary:
	return {
		cloud_depth_m = depth_m,
		overdevelopment_chance = overdev,
		stability_n_per_s = 0.012,
		_derived = {z_lcl_msl_m = z_lcl, temperature_c = 25.0, dew_point_c = 8.0},
	}


static func cfg() -> Dictionary:
	return Config.get_config("atmosphere").cloud_field


static func field_inputs(f: WindField, z_lcl: float, seed := 1) -> Dictionary:
	var air := AirThermals.new()
	air.build(f, thermals_cfg(z_lcl))
	return {air = air, wind_field = f, weather = weather(z_lcl), seed = seed}


static func mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(a.size(), 1)


func _invariants(cf: CloudField, label: String) -> void:
	var ok := true
	for c in cf.nx * cf.ny:
		var cov := cf.cover[c]
		var d := cf.depth[c]
		if cov < 0.0 or cov > 1.0 or d < 0.0 or is_nan(d) or is_nan(cov):
			ok = false
		if cov == 0.0 and d != 0.0:
			ok = false
		if cf.stage[c] < -1.0 or cf.stage[c] > 1.0 or cf.activity[c] < 0.0 or cf.activity[c] > 1.0:
			ok = false
	check(ok, "%s: cover 0..1, depth ≥ 0 (0 без облака), stage −1..1, activity 0..1" % label)


func test_empty_without_inputs() -> void:
	var cf := CloudField.new(cfg())
	cf.setup_grid(N, N, DX, -N * DX * 0.5, -N * DX * 0.5)
	cf.step_to(3600.0)
	cf.set_inputs({})
	cf.step_to(7200.0)
	check(mean(cf.cover) == 0.0, "без входов — пустое поле")
	check(cf.sample(Vector3.ZERO).x == 0.0 and cf.density_at(Vector3(0, 2000, 0)) == 0.0, "выборка 0")
	_invariants(cf, "пустое")


func test_source_reaches_lcl() -> void:
	var f := flat_field(blob(0.0, 0.0, 4000.0, 300.0), 2500.0)
	var cf := CloudField.new(cfg())
	cf.set_inputs(field_inputs(f, 2000.0))
	check(cf.nx == N and cf.signature() == AirThermals.signature(f), "сетка — по полю")
	cf.reset(0.0)
	cf.step_to(1800.0)
	_invariants(cf, "пятно")
	var s_in := cf.sample(Vector3(0, 0, 0))
	var s_out := cf.sample(Vector3(-8000.0, 0, -8000.0))
	check(s_in.x > 0.05, "над прогретым пятном облако (cover %.3f)" % s_in.x)
	check(s_out.x == 0.0, "вдали от пятна — чисто (cover %.3f)" % s_out.x)
	check(s_in.y == 2000.0 and s_in.z > s_in.y + 50.0, "основание = LCL, мощность > 0 (%.0f)" % (s_in.z - s_in.y))
	check(cf.density_at(Vector3(0, 1900, 0)) == 0.0, "под основанием плотность 0")
	check(cf.density_at(Vector3(0, s_in.y + 0.5 * (s_in.z - s_in.y), 0)) > 0.0, "в облаке плотность > 0")
	check(cf.shade_at(Vector2(0, 0), Vector3(0, 1, 0)) > 0.0, "тень под облаком")
	check(cf.shade_at(Vector2(-8000, -8000), Vector3(0, 1, 0)) == 0.0, "нет тени вдали")
	# LCL выше потолка — облаков нет
	var cf2 := CloudField.new(cfg())
	cf2.set_inputs(field_inputs(f, 4500.0))
	cf2.reset(0.0)
	cf2.step_to(1800.0)
	check(mean(cf2.cover) == 0.0, "LCL выше потолка частицы — чисто")


func test_weak_lt_strong() -> void:
	var weak := flat_field(blob(0.0, 0.0, 6000.0, 80.0), 1800.0)
	var strong := flat_field(blob(0.0, 0.0, 6000.0, 350.0), 2600.0)
	var a := CloudField.new(cfg())
	a.set_inputs(field_inputs(weak, 1650.0))
	a.reset(0.0)
	a.step_to(3600.0)
	var b := CloudField.new(cfg())
	b.set_inputs(field_inputs(strong, 2100.0))
	b.reset(0.0)
	b.step_to(3600.0)
	check(mean(a.cover) < mean(b.cover), "слабый день (%.3f) < сильный (%.3f)" % [mean(a.cover), mean(b.cover)])
	check(mean(a.depth) < mean(b.depth), "мощность: слабый < сильный")


func test_determinism() -> void:
	var f := flat_field(blob(1000.0, -2000.0, 5000.0, 250.0), 2500.0, Vector2(4.0, 1.0))
	var inp := field_inputs(f, 2000.0, 7)
	var a := CloudField.new(cfg())
	a.set_inputs(inp)
	a.reset(100.0)
	a.step_to(2500.0)
	var b := CloudField.new(cfg())
	b.set_inputs(inp)
	b.reset(100.0)
	b.step_to(2500.0)
	check(a.cover == b.cover and a.depth == b.depth and a.stage == b.stage and a.activity == b.activity, "одни входы — побитно те же массивы")
	# reset + step_to(t) == шаги по одному
	var c := CloudField.new(cfg())
	c.set_inputs(inp)
	c.reset(100.0)
	var t := 100.0
	while t < 2500.0:
		t += float(cfg().step_s)
		c.step_to(t)
	check(a.cover == c.cover and a.depth == c.depth and a.stage == c.stage, "step_to(t) == шаги по одному")
	check(mean(a.cover) > 0.0, "есть облака (тест не пустой)")
	# назад во времени — reset
	c.step_to(50.0)
	check(c.time == 50.0, "t назад → reset(t)")


func test_snapshot_and_image() -> void:
	var f := flat_field(blob(0.0, 0.0, 5000.0, 300.0), 2500.0)
	var cf := CloudField.new(cfg())
	cf.set_inputs(field_inputs(f, 2000.0))
	cf.reset(0.0)
	cf.step_to(2400.0)
	var img := cf.to_image()
	check(img.get_width() == N and img.get_height() == N and img.get_format() == Image.FORMAT_RGBA8, "to_image: nx × ny RGBA8")
	var c_max := 0
	var c_max_val := 0.0
	for c in N * N:
		if cf.cover[c] > c_max_val:
			c_max_val = cf.cover[c]
			c_max = c
	var i := c_max % N
	var j := c_max / N
	var px := img.get_pixel(i, N - 1 - j)
	approx(px.r, c_max_val, 1.0 / 255.0, "R = cover в строке ny − 1 − j")
	approx(px.g, cf.depth[c_max] / float(cfg().depth_max_m), 1.0 / 255.0, "G = depth/depth_max_m")
	approx(px.a, cf.activity[c_max], 1.0 / 255.0, "A = activity")
	var snap := cf.snapshot()
	check(snap.size() > 0 and snap.size() < N * N * 4, "снимок сжат (%d байт)" % snap.size())
	var other := CloudField.new(cfg())
	other.setup_grid(N, N, DX, cf.x0, cf.y0)
	check(other.apply_snapshot(snap, 1.0), "снимок применился на той же сетке")
	var worst := 0.0
	for c in N * N:
		worst = maxf(worst, absf(other.cover[c] - cf.cover[c]))
		worst = maxf(worst, absf(other.depth[c] - cf.depth[c]) / float(cfg().depth_max_m))
	check(worst <= 1.0 / 255.0 + 1.0e-6, "поле из снимка — в пределах квантования (%.4f)" % worst)
	check(other.base_msl == cf.base_msl, "base_msl из снимка")
	var alien := CloudField.new(cfg())
	alien.setup_grid(N, N, 200.0, cf.x0, cf.y0)
	check(not alien.apply_snapshot(snap, 1.0), "чужая сетка — false")
	check(not alien.apply_snapshot(PackedByteArray([1, 2, 3]), 1.0), "мусор — false")
	# после снимка поле живёт дальше без ошибок
	other.set_inputs(field_inputs(f, 2000.0))
	other.step_to(2460.0)
	_invariants(other, "после снимка")


func test_analytic_thermals() -> void:
	var cf := CloudField.new(cfg())
	cf.setup_grid(N, N, DX, -N * DX * 0.5, -N * DX * 0.5)
	var th := AtmoThermal.new()
	th.src = Vector3(2000.0, 1000.0, -3000.0)
	th.top = 2600.0
	th.strength = 3.0
	th.radius = 180.0
	th.env = 1.0
	th.cloud_depth = 600.0
	var dry := AtmoThermal.new()
	dry.src = Vector3(-6000.0, 1000.0, 6000.0)
	dry.top = 1800.0
	dry.strength = 3.0
	dry.radius = 180.0
	dry.env = 1.0
	cf.set_inputs({
		thermals = [th, dry], cloudbase_msl = 2500.0, ground_ref = 1000.0,
		wind_at = func(_z: float) -> Vector2: return Vector2.ZERO,
	})
	cf.reset(0.0)
	cf.step_to(1800.0)
	check(cf.base_msl == 2500.0, "основание — кромка (без погоды)")
	var s := cf.sample(Vector3(2000.0, 0, -3000.0))
	check(s.x > 0.05, "облако над термиком до кромки (cover %.3f)" % s.x)
	check(cf.sample(Vector3(-6000.0, 0, 6000.0)).x == 0.0, "термик ниже кромки — без облака")
	_invariants(cf, "аналитика")


func test_decay_delay_and_stage() -> void:
	var f := flat_field(blob(0.0, 0.0, 5000.0, 300.0), 2500.0)
	var cf := CloudField.new(cfg())
	var inp := field_inputs(f, 2000.0)
	cf.set_inputs(inp)
	cf.reset(0.0)
	var q0 := mean(cf.cover)
	cf.step_to(300.0)
	var c0 := N / 2 * N + N / 2
	var st_growth := cf.stage[c0]
	cf.step_to(3600.0)
	var q_full := mean(cf.cover)
	check(absf(q_full - q0) < 0.05 * maxf(q0, 1.0e-3) + 1.0e-3, "после разгона поле установилось (%.3f → %.3f)" % [q0, q_full])
	# подъём выключен: облака держатся и тают с задержкой
	cf.set_inputs({weather = weather(2000.0), wind_field = f, seed = 1})
	cf.step_to(3600.0 + 300.0)
	var q5 := mean(cf.cover)
	check(q5 > 0.5 * q_full, "через 5 мин без подъёма облака ещё есть (%.3f из %.3f)" % [q5, q_full])
	check(cf.stage[c0] < 0.0, "стадия — тает (%.2f)" % cf.stage[c0])
	cf.step_to(3600.0 + 5400.0)
	var q90 := mean(cf.cover)
	check(q90 < 0.1 * q_full, "через 90 мин без подъёма почти растаяли (%.4f)" % q90)
	# стадия при росте: заново от пустого
	cf.set_inputs(inp)
	cf.reset(0.0)
	cf.step_to(300.0)
	check(cf.stage[c0] > 0.0 and st_growth > 0.0, "стадия в начале — растёт (%.2f)" % cf.stage[c0])


func test_advection_downwind() -> void:
	var f := flat_field(blob(-4000.0, 0.0, 2500.0, 300.0), 2500.0, Vector2(6.0, 0.0))
	var cf := CloudField.new(cfg())
	cf.set_inputs(field_inputs(f, 2000.0))
	cf.reset(0.0)
	cf.step_to(3600.0)
	var up := cf.sample(Vector3(-9000.0, 0, 0)).x
	var down := cf.sample(Vector3(2000.0, 0, 0)).x
	check(down > up, "облака сносит по ветру: cover по ветру %.3f > против %.3f" % [down, up])
	_invariants(cf, "снос")
	var out := cf.sample(Vector3(1.0e5, 0, 0))
	approx(out.x, cf.bg_cover, 1.0e-6, "вне сетки — фон")


func test_overdevelopment_towers() -> void:
	var f := flat_field(blob(0.0, 0.0, 6000.0, 400.0), 2800.0)
	var air := AirThermals.new()
	air.build(f, thermals_cfg(1800.0))
	var w := weather(1800.0, 800.0, 0.5)
	var cf := CloudField.new(cfg())
	cf.set_inputs({air = air, wind_field = f, weather = w, seed = 3})
	cf.reset(0.0)
	cf.step_to(7200.0)
	var d_max := 0.0
	for c in N * N:
		d_max = maxf(d_max, cf.depth[c])
	var plain := CloudField.new(cfg())
	plain.set_inputs({air = air, wind_field = f, weather = weather(1800.0, 800.0, 0.0), seed = 3})
	plain.reset(0.0)
	plain.step_to(7200.0)
	var d_plain := 0.0
	for c in N * N:
		d_plain = maxf(d_plain, plain.depth[c])
	check(d_plain <= 800.0 + 1.0, "без переразвития мощность ≤ cloud_depth_m (%.0f)" % d_plain)
	check(d_max > d_plain + 100.0, "с переразвитием есть башни выше (%.0f > %.0f)" % [d_max, d_plain])
