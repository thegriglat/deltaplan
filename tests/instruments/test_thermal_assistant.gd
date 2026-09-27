extends TestCase
## Помощник центровки: синтетический термик со смещённым центром, учёт задержки датчика, прямая.

const DT := 1.0 / 120.0


func _cfg(lag_s: float) -> Dictionary:
	var cfg: Dictionary = Config.get_config("instruments").duplicate(true)
	cfg.thermal_assistant.sensor_lag_s = lag_s
	return cfg


## Кружим радиусом 40 м вокруг (0, 0) со скоростью rate_dps (+ вправо), ядро термика смещено
## на 30 м по пеленгу core_bearing. Вариометр — через фильтр прибора (Vario, τ из конфига).
## Возвращает ошибку пеленга «сильной стороны», градусы.
func _circle(ta: ThermalAssistant, rate_dps: float, core_bearing: float, seconds: float) -> float:
	var vario := Vario.new()
	vario.setup()
	var cb := deg_to_rad(core_bearing)
	var core := Vector2(sin(cb), -cos(cb)) * 30.0
	var hdg := 0.0
	var dir := signf(rate_dps)
	for i in int(seconds / DT):
		hdg = fposmod(hdg + rate_dps * DT, 360.0)
		var phi := deg_to_rad(hdg - 90.0 * dir)
		var pos := Vector2(sin(phi), -cos(phi)) * 40.0
		var lift := 3.0 * exp(-pos.distance_squared_to(core) / (50.0 * 50.0)) - 0.5
		vario.update_raw(lift, DT)
		ta.update(hdg, vario.vario_ms, DT)
	return absf(wrapf(ta.strong_bearing_deg - core_bearing, -180.0, 180.0))


func test_points_to_core_right_turn() -> void:
	var ta := ThermalAssistant.new()
	ta.setup(Config.get_config("instruments"), 0.7)
	var err := _circle(ta, 20.0, 90.0, 60.0)
	check(ta.circling, "кружение обнаружено")
	check(ta.turn_dir == 1, "вираж вправо")
	check(err < 8.0, "сильная сторона — к ядру (ошибка %.1f°)" % err)
	check(ta.asymmetry_ms > 0.3, "асимметрия заметна: %.2f" % ta.asymmetry_ms)
	check(ta.circle_average_ms > -0.5 and ta.circle_average_ms < 2.5, "среднее за круг разумно")


func test_points_to_core_left_turn() -> void:
	var ta := ThermalAssistant.new()
	ta.setup(Config.get_config("instruments"), 0.7)
	var err := _circle(ta, -18.0, 225.0, 60.0)
	check(ta.turn_dir == -1, "вираж влево")
	check(err < 8.0, "левый вираж, ядро на ЮЗ (ошибка %.1f°)" % err)


func test_sensor_lag_compensated() -> void:
	var tau: float = Config.get_config("instruments").vario.filter_time_constant_s
	var with_lag := ThermalAssistant.new()
	with_lag.setup(_cfg(-1.0), tau)
	approx(with_lag.get_sensor_lag_s(), tau, 1e-6, "задержка = τ фильтра")
	var err_comp := _circle(with_lag, 25.0, 0.0, 60.0)
	var no_lag := ThermalAssistant.new()
	no_lag.setup(_cfg(0.0), tau)
	var err_raw := _circle(no_lag, 25.0, 0.0, 60.0)
	check(err_comp < err_raw, "с учётом задержки точнее: %.1f° против %.1f°" % [err_comp, err_raw])
	check(err_raw > 8.0, "без учёта задержки видна ошибка (%.1f°)" % err_raw)


func test_straight_no_circling() -> void:
	var ta := ThermalAssistant.new()
	ta.setup(Config.get_config("instruments"), 0.7)
	for i in int(30.0 / DT):
		ta.update(45.0 + 2.0 * sin(i * DT), 1.5, DT)
	check(not ta.circling, "на прямой — нет кружения")
	var any := false
	for v in ta.sectors:
		any = any or not is_nan(v)
	check(not any, "диаграмма пуста")


func test_relative_direction() -> void:
	var ta := ThermalAssistant.new()
	ta.setup(Config.get_config("instruments"), 0.7)
	ta.strong_bearing_deg = 90.0
	approx(ta.strong_relative_deg(0.0), 90.0, 1e-6, "курс север, сильнее на востоке — справа")
	approx(ta.strong_relative_deg(180.0), -90.0, 1e-6, "курс юг — слева")
