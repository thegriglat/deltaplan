class_name AirWindowCase
extends AirCase
## Вход решения окна клипмапа (AM-04): сетка окна 64 × 64 (Δx 100 или 50 м, Δz = Δx/2), рельеф,
## погода и солнце — как у области (AirPlace), граница — от родителя (AirWindowJob). Отличия от
## области по эталону (tools/research/air3d/air.py, nest ≠ None; reference.md → «Граничные
## условия области»): губки — зона релаксации к родителю (Дэвис 1976): у всех боковых граней на
## nest_sponge_cells клеток (для импульса и θ′), у потолка на nest_sponge_top_m; нагрев у края не
## гасится; фон ветра на гранях setup не пишет (P_NEST) — его кладёт air_window.glsl:nest.
##
## prepare() — один раз (дорогая часть на CPU: гаусс K_b; её можно сделать в рабочем потоке,
## вместе с without_heat()), дальше — без повторного счёта.

const N_WINDOW := 64
const TOP_ABOVE := 2000.0  # потолок окна над максимумом его рельефа, м (real.grid_window)
const P_NEST := 19  # air_picard.glsl

var _prepared := false
var _mech_case: AirWindowCase = null


func _init() -> void:
	p.nest_sponge_cells = 4.0
	p.nest_sponge_top_m = 1000.0
	taper = false


## Окно с клеткой dx и центром (cx, cy) в осях решателя (x — восток, y — север; = мир (x, −z)):
## как real.grid_window — угол окна кратен 25 м, dz = dx/2, z_bot = ⌊h_min/dz⌋·dz − dz, верх —
## TOP_ABOVE над максимумом, nz чётное; вход погоды и солнца — как AirPlace.domain_case.
## ctx — AirPlace.context (дорогой; передать готовый, если есть). null — окно вне слоя.
static func window_case(
	detail: HeightLayer,
	water: Image,
	loc: Dictionary,
	dx: float,
	cx: float,
	cy: float,
	hour: float,
	u10: float,
	wdir: float,
	t_max := NAN,
	sky := "clear",
	heat := true,
	ctx := {},
	n := N_WINDOW
) -> AirWindowCase:
	var half := 0.5 * n * dx
	var x0 := roundf((cx - half) / 25.0) * 25.0
	var y0 := roundf((cy - half) / 25.0) * 25.0
	return window_at(detail, water, loc, dx, x0, y0, hour, u10, wdir, t_max, sky, heat, ctx, n)


## То же с углом окна (x0, y0) — сдвиг окна кратно клетке.
static func window_at(
	detail: HeightLayer,
	water: Image,
	loc: Dictionary,
	dx: float,
	x0: float,
	y0: float,
	hour: float,
	u10: float,
	wdir: float,
	t_max := NAN,
	sky := "clear",
	heat := true,
	ctx := {},
	n := N_WINDOW
) -> AirWindowCase:
	var hc := AirPlace.block_mean(detail, x0, y0, dx, n, n)
	if hc.is_empty():
		return null
	var dz := dx / 2.0
	var lo := INF
	var hi := -INF
	for v in hc:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var zb := floorf(lo / dz) * dz - dz
	var nz := ceili((hi + TOP_ABOVE - zb) / dz)
	nz += nz % 2
	var c := AirWindowCase.new()
	c.set_grid(dx, n, n, dz, zb, nz, x0, y0)
	c.hc = hc
	c.u10 = u10
	c.wdir = wdir
	var cfg := WeatherModel.config()
	if ctx.is_empty():
		ctx = AirPlace.context(detail, loc, cfg)
	if is_nan(t_max):
		t_max = WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)
	var d := AirPlace.day(ctx, hour, t_max, sky, cfg)
	c.z_i = d.z_i
	c.gam.resize(nz + 2)
	for k in nz + 2:
		c.gam[k] = AirPlace.gamma(d, c.zc(k))
	if heat:
		c.heat = AirPlace.solar_flux(
			hc, dx, n, n, d, ctx, cfg, AirPlace.water_fraction(water, detail, x0, y0, dx, n, n)
		)
	c.label = (
		"%s окно %sм (%s, %s) %sч U%s %s°%s"
		% [String(loc.get("id", "")), dx, x0, y0, hour, u10, wdir, "" if heat else " без нагрева"]
	)
	return c


func prepare() -> bool:
	if _prepared:
		return true
	taper = false
	if not super.prepare():
		return false
	var nyx := nx_h * ny_h
	var rate := float(p.sponge_rate)
	# зона релаксации: боковые грани — nest_sponge_cells клеток (все четыре, и для θ′)
	var ls := float(p.nest_sponge_cells) * dx
	var lx := nx * dx
	var ly := ny * dx
	for j in ny_h:
		var yj := (j - 0.5) * dx
		var ry := maxf(_ramp(yj, ls, rate), _ramp(ly - yj, ls, rate))
		for i in nx_h:
			var xi := (i - 0.5) * dx
			var s := maxf(maxf(_ramp(xi, ls, rate), _ramp(lx - xi, ls, rate)), ry)
			col[6 * nyx + j * nx_h + i] = s
			col[7 * nyx + j * nx_h + i] = s
	# потолок — nest_sponge_top_m
	var ztop := z_bot + nz * dz
	var top := float(p.nest_sponge_top_m)
	for k in nz_h:
		var z := zc(k)
		lev[3 * nz_h + k] = _ramp(ztop - z, top, rate)
		lev[4 * nz_h + k] = _ramp(ztop - (z - 0.5 * dz), top, rate)
	prm[P_NEST] = 1.0
	_prepared = true
	return true


## Без нагрева (w_mech): тот же класс, готовится один раз (можно заранее в рабочем потоке).
func without_heat() -> AirCase:
	if _mech_case != null:
		return _mech_case
	var c := AirWindowCase.new()
	c.p = p.duplicate()
	c.set_grid(dx, nx, ny, dz, z_bot, nz, x0, y0)
	c.hc = hc
	c.gam = gam
	c.z_i = z_i
	c.u10 = u10
	c.wdir = wdir
	c.label = label + " без нагрева"
	_mech_case = c
	return c


## Подготовить оба случая (с нагревом и без) — для рабочего потока до AirWindowJob.start().
func prepare_pair() -> bool:
	if not prepare():
		return false
	if heat.is_empty():
		return true
	return without_heat().prepare()


func meta() -> Dictionary:
	var m := super.meta()
	m.level = "window"
	return m
