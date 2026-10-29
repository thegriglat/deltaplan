extends TestCase
## Перистая пелена (VR-28), грозы Cb (VR-26), подветренные волны (VR-27) — через фасад W2 v4
## (tests/atmosphere/air_rig.gd). Внутренности GD-слагаемых (ячейки грозы, ось термика, поток
## Cb) — крейт (RW-12s: проверки через ячейки грозы и поле GD удалены, эквиваленты ниже).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const RIDGE_H := 800.0
const RIDGE_W := 1500.0
const R_CORES := 8000.0


## Хребет поперёк ветра (гребень вдоль Z на x = 0).
static func _ridge(x: float, _z: float) -> float:
	return 500.0 + RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


## (средняя сила ядер, число ядер) вокруг фокуса.
func _mean_strength(a: Atmosphere) -> Vector2:
	var c := a.cores(Vector3(0.0, 300.0, 0.0), R_CORES)
	var n := c.size() / Atmosphere.CORE_STRIDE
	var s := 0.0
	for j in n:
		s += c[j * Atmosphere.CORE_STRIDE + Atmosphere.CORE_W]
	return Vector2(s / maxi(n, 1), n)


func test_cirrus_weakens_thermals() -> void:
	var clear := Rig.make(
		{"preset": "weather/strong", "over": {"cirrus_cover": 0.0}, "moist": func(_x: float, _z: float) -> float: return 0.8,
		"advance": 0.01}
	)
	var veil := Rig.make(
		{"preset": "weather/strong", "over": {"cirrus_cover": 0.9}, "moist": func(_x: float, _z: float) -> float: return 0.8,
		"advance": 0.01}
	)
	var c := _mean_strength(clear)
	var v := _mean_strength(veil)
	var ins_c := clear.get_insolation()
	var ins_v := veil.get_insolation()
	check(ins_v < ins_c and ins_v < 0.6, "пелена снижает прогрев: %.2f < %.2f" % [ins_v, ins_c])
	check(v.x < c.x * 0.9, "термики под пеленой слабее: %.2f < %.2f м/с" % [v.x, c.x])
	check(v.y < c.y, "и реже: %d < %d" % [int(v.y), int(c.y)])
	clear.free()
	veil.free()


# test_cb_downdraft_and_outflow (ливневый поток, растекание, фронт) — rust/dp-air/tests/terms_storm.rs
# (cb_downdraft_outflow_and_front, overlapping_outflows_do_not_add, intensity_follows_life);
# test_cb_suck_under_base (подсос под основанием Cb) — terms_thermal_cloud.rs (suck_points_from_gd_in_tolerance)
# и terms_clouds.rs (physics_suck_vs_gd).


func test_storm_preset_makes_cb() -> void:
	var a := Rig.make({"preset": "weather/storm", "advance": 0.01})
	var n := 0
	for th: Dictionary in a.thermals_near(Vector3(0.0, 300.0, 0.0), R_CORES):
		if bool(th.is_cb):
			n += 1
	check(n > 0, "в грозовой день есть Cb: %d" % n)
	a.free()


func test_lee_wave_crest_lift() -> void:
	var a := Rig.make(
		{
			"preset": "weather/wave",
			"mode": 1,
			"ground": _ridge,
			"half": 20000.0,  # волна уходит на десятки км за хребет: место с запасом
			"spacing": 250.0,
			"advance": 0.01,
		}
	)
	var info := a.wave_info()
	check(info[Atmosphere.WAVE_INFO_ENABLED] > 0.5, "волна включена")
	var lam := info[Atmosphere.WAVE_INFO_LENGTH]
	check(lam > 3000.0 and lam < 20000.0, "длина волны правдоподобна: %.0f м" % lam)
	# Вдоль ветра (+X) за хребтом на высоте 1,5 км над гребнем — есть и подъём, и опускание.
	var y := 500.0 + RIDGE_H + 1500.0
	var w_max := -1.0e9
	var w_min := 1.0e9
	var x_max := 0.0
	for i in 120:
		var x := 1000.0 + i * 150.0
		var w := a.mean_wind_at(Vector3(x, y, 0.0)).y
		if w > w_max:
			w_max = w
			x_max = x
		w_min = minf(w_min, w)
	var bg := float(a.weather().background_sink_ms)
	check(w_max > bg + 1.0, "в гребне волны подъём: %.2f м/с на x = %.0f" % [w_max, x_max])
	check(w_min < bg - 0.5, "в ложбине опускание: %.2f" % w_min)
	# Высоко над волной поток слабее.
	var w_high := a.mean_wind_at(Vector3(x_max, y + 12000.0, 0.0)).y
	check(absf(w_high - bg) < absf(w_max - bg) * 0.5, "с высотой волна гаснет")
	# Лентикулярные облака: гребни η найдены.
	var cr := a.wave_crests(Vector2(8000, 0), 12000.0, 50.0)
	check(not cr.is_empty(), "гребни волн (лентикуляры) найдены: %d" % (cr.size() / Atmosphere.CREST_STRIDE))
	a.free()


func test_no_wave_without_preset() -> void:
	var a := Rig.make(
		{"mode": 1, "ground": _ridge, "half": 20000.0, "spacing": 250.0, "advance": 0.01}
	)
	check(a.wave_info()[Atmosphere.WAVE_INFO_ENABLED] < 0.5, "в обычный день волн нет")
	a.free()


## Молодой термик (GD AtmoThermal, без атмосферы): рост 300 с, зрелость 600 с, распад 200 с.
func _young(x: float) -> AtmoThermal:
	var th := AtmoThermal.new()
	th.src = Vector3(x, 0.0, 0.0)
	th.top = 1800.0
	th.strength = 4.0
	th.radius = 120.0
	th.id = 1000 + int(x)
	th.t_birth = -5.0
	th.t_grow = 300.0
	th.t_mature = 600.0
	th.t_decay = 200.0
	return th


func test_dust_devils_from_young_thermals_over_dry_ground() -> void:
	var dust_cfg: Dictionary = Config.get_config("atmosphere").dust
	var dm := DustModel.new()
	dm.setup(dust_cfg, Rig.preset("weather/strong", {"dust_devil_chance": 1.0}))
	var crop := func(_x: float, _z: float) -> int: return 3
	var forest := func(_x: float, _z: float) -> int: return 1
	var th := _young(0.0)
	# Ищем момент, когда вихрь жив (он появляется в первой части роста термика).
	var found := {}
	for i in 400:
		var d := dm.devil(th, th.t_birth + i * 1.0, crop, Vector2(2, 0))
		if not d.is_empty():
			found = d
			break
	check(not found.is_empty(), "у молодого термика над пашней есть пылевой вихрь")
	if not found.is_empty():
		var h: float = found.height
		check(h >= 20.0 and h <= 200.0, "высота вихря 20–200 м: %.0f" % h)
		var t_live: float = th.t_birth
		for i in 400:
			if not dm.devil(th, th.t_birth + i * 1.0, crop, Vector2.ZERO).is_empty():
				t_live = th.t_birth + i * 1.0
				break
		check(dm.devil(th, t_live, forest, Vector2.ZERO).is_empty(), "над лесом пыли нет")
		var p0: Vector3 = dm.devil(th, t_live, crop, Vector2(3, 0)).pos
		var p1: Vector3 = dm.devil(th, t_live + 5.0, crop, Vector2(3, 0)).get("pos", p0)
		check(p1.x > p0.x, "вихрь дрейфует с ветром")
	check(dm.devil(th, th.t_birth + 800.0, crop, Vector2.ZERO).is_empty(), "у зрелого термика нет")
	var dw := DustModel.new()
	dw.setup(dust_cfg, Rig.preset("weather/weak", {"dust_devil_chance": 0.0}))
	check(dw.devil(th, th.t_birth + 30.0, crop, Vector2.ZERO).is_empty(), "в слабый день нет")
