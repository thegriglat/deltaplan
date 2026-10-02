extends Node
## AS-2: ветер на 1,5 м над стартом с полем воздуха GPU (сцена игры, main.tscn → _fly, ветер
## «встречный» 6 м/с) — болтанка по подобию приземного слоя (docs/guide/air-model.md → «Масштаб 3:
## возмущения из поля», «У земли»). Точка неподвижна, время атмосферы — шагом 0,1 с, 20 с × 3 сида.
## Теория — для u* в точке (κ·U_поле/ln(z/z0)) и z/L по w*, z_i поля:
##   σw = 1,25 u* (1 + 3|z/L|)^(1/3); σu = u* (12 + 0,5 z_i/|L|)^(1/3) (2,4 u* в нейтрали);
##   σv = u* (1,9³ + 0,5 z_i/|L|)^(1/3) (Panofsky et al. 1977; Panofsky & Dutton 1984).
## Пороги: σ модели в точке — ±30 % от теории; ряд (60 с) — σw ±40 % (выборка); нет признака отрыва и
## обратного потока на наветренном старте; max|θ| за 20 с < 90° (средний ветер ≥ 3 м/с, σθ ≈ 15–25°:
## разворот ≥ 90° — событие > 3σ); max|ΔU| за 0,5 с < 2,5 σu теории (время вихря L_u/U ≈ 5 с: СКО
## приращения за 0,5 с ≈ 0,45 σu, максимум из 120 — ≈ 3 этих СКО).
## Запуск: flock /tmp/heat_ca_gpu.lock tools/gpu_tests.sh --filter=start_air_gpu

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SITES := ["ongudai/kayancha_south", "aushkul/aushtau_east"]
const WIND_KMH := 21.6
const SEEDS := [0.0, 1500.0, 3000.0]
const KAPPA := 0.4

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_start_air_surface_layer() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var menu: Node = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	(main.get("opts") as Object).set("autostart", true)
	(main.get("opts") as Object).set("bots", 0)
	for site: String in SITES:
		var s := FlightSettings.defaults()
		s.location_id = site.get_slice("/", 0)
		s.site_id = site.get_slice("/", 1)
		s.wind_speed_kmh = WIND_KMH
		await main.call("_fly", s)
		game.process_mode = Node.PROCESS_MODE_DISABLED
		_check_site(game, site)
		game.process_mode = Node.PROCESS_MODE_INHERIT
	main.queue_free()


func _check_site(game: Game, site: String) -> void:
	var air: Atmosphere = game.air
	check(air.is_air_field_on(), "%s: поле воздуха включено" % site)
	if not air.is_air_field_on():
		return
	game.restart()
	var p := game.glider.model.position + Vector3.UP * 1.5
	var gs := air.ground.sample(p.x, p.z)
	var agl := p.y - gs.x
	var fw := air.air_field.sample(p, gs.x)
	check(fw.w > 0.99, "%s: старт внутри поля (доля %.2f)" % [site, fw.w])
	var tb := air.air_field.sample_turb(p, gs.x)
	var uf := Vector2(fw.x, fw.z).length() / maxf(fw.w, 1.0e-3)
	var ft := air.field_turb
	# теория подобия в точке
	var z := maxf(agl, 1.0)
	var us := KAPPA * uf / log(z / ft.z0)
	var ws := tb[WindField.T_WSTAR]
	var zi := tb[WindField.T_HMIX]
	var th := _theory(us, ws, zi, z)
	# модель в точке
	var sg := ft.sigma(agl, tb, Vector2.ZERO, uf)
	var sv := ft.last_sv
	var lee_f := ft.lee(uf, agl, tb)
	# ряды
	var var_u := 0.0
	var var_v := 0.0
	var var_w := 0.0
	var th_max := 0.0
	var du_max := 0.0
	for sd: float in SEEDS:
		var st := _series(air, p, sd)
		var_u += st.su * st.su / SEEDS.size()
		var_v += st.sv * st.sv / SEEDS.size()
		var_w += st.sw * st.sw / SEEDS.size()
		th_max = maxf(th_max, st.th_max)
		du_max = maxf(du_max, st.du_max)
	var line := (
		"%s: Ū %.2f, u* %.2f, z/L %.3f | σw %.2f/%.2f (ряд %.2f), σu %.2f/%.2f (ряд %.2f), σv %.2f/%.2f (ряд %.2f) | max|θ| %.0f°, max|ΔU| %.2f, lee %.2f"
		% [site, uf, us, th.zl, sg.y, th.sw, sqrt(var_w), sg.x, th.su, sqrt(var_u), sv, th.sv, sqrt(var_v), th_max, du_max, lee_f]
	)
	print("  " + line)
	check(lee_f == 0.0, "%s: нет признака отрыва на наветренном старте (%s)" % [site, line])
	check(absf(sg.y / th.sw - 1.0) <= 0.3, "%s: σw модели ±30 %% теории (%s)" % [site, line])
	check(absf(sg.x / th.su - 1.0) <= 0.3, "%s: σu модели ±30 %% теории (%s)" % [site, line])
	check(absf(sv / th.sv - 1.0) <= 0.3, "%s: σv модели ±30 %% теории (%s)" % [site, line])
	check(absf(sqrt(var_w) / th.sw - 1.0) <= 0.4, "%s: σw ряда ±40 %% теории (%s)" % [site, line])
	if uf >= 3.0:
		check(th_max < 90.0, "%s: max|θ| за 20 с < 90° (%s)" % [site, line])
	check(du_max < 2.5 * th.su, "%s: max|ΔU| за 0,5 с < 2,5 σu (%s)" % [site, line])


static func _theory(us: float, ws: float, zi: float, z: float) -> Dictionary:
	if ws > 0.0 and zi > 0.0:
		var el := -us * us * us * zi / (KAPPA * ws * ws * ws)
		var zl := z / el
		var zil := zi / absf(el)
		return {
			"zl": zl,
			"sw": 1.25 * us * pow(1.0 + 3.0 * absf(zl), 1.0 / 3.0),
			"su": us * pow(12.0 + 0.5 * zil, 1.0 / 3.0),
			"sv": us * pow(1.9 * 1.9 * 1.9 + 0.5 * zil, 1.0 / 3.0),
		}
	return {"zl": 0.0, "sw": 1.25 * us, "su": 2.4 * us, "sv": 1.9 * us}


## Ряд 20 с шагом 0,1 с в неподвижной точке: σ вдоль/поперёк среднего, σw, max|θ| от среднего,
## max|ΔU| (модуль горизонтали) за 0,5 с.
static func _series(air: Atmosphere, p: Vector3, t0: float) -> Dictionary:
	var n := 200
	var hs: Array[Vector2] = []
	var ws := PackedFloat32Array()
	var m := Vector2.ZERO
	for i in n:
		air.time_s = t0 + i * 0.1
		var v := air.air_velocity_at(p)
		hs.append(Vector2(v.x, v.z))
		ws.append(v.y)
		m += Vector2(v.x, v.z) / n
	var e := m.normalized()
	var su := 0.0
	var sv := 0.0
	var sw := 0.0
	var mw := 0.0
	for i in n:
		mw += ws[i] / n
	var th_max := 0.0
	var du_max := 0.0
	for i in n:
		var al := hs[i].dot(e) - m.length()
		var cr := hs[i].dot(Vector2(-e.y, e.x))
		su += al * al / n
		sv += cr * cr / n
		sw += (ws[i] - mw) * (ws[i] - mw) / n
		th_max = maxf(th_max, absf(rad_to_deg(atan2(cr, hs[i].dot(e)))))
		if i + 5 < n:
			du_max = maxf(du_max, absf(hs[i + 5].length() - hs[i].length()))
	return {"su": sqrt(su), "sv": sqrt(sv), "sw": sqrt(sw), "th_max": th_max, "du_max": du_max}
