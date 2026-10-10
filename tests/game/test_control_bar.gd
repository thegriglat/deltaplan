extends TestCase
## CB-2: ход ручки трапеции (BarAxis) и путь «сырая ось → control» в InputController без устройства.

const GP := {"deadzone": 0.08, "expo": 0.0, "sensitivity": 1.0}


func _devs() -> Array:
	return [
		{"id": 3, "guid": "aaa", "name": "Pad"},
		{"id": 5, "guid": "bbb", "name": "Bar"},
	]


func test_calibration_asymmetric() -> void:
	var cal := [-0.5, 0.2, 0.8]
	approx(BarAxis.normalize(0.2, cal), 0.0, 1e-6, "нейтраль")
	approx(BarAxis.normalize(0.5, cal), 0.5, 1e-6, "половина вверх")
	approx(BarAxis.normalize(-0.15, cal), -0.5, 1e-6, "половина вниз")
	approx(BarAxis.normalize(INF, cal), 0.0, 1e-6, "inf → 0")
	approx(BarAxis.normalize(NAN, cal), 0.0, 1e-6, "NaN → 0")


func test_invert_and_cal_of() -> void:
	var cal := [-0.5, 0.2, 0.8]
	var a := BarAxis.axis_value(0.7, cal, false, GP)
	var b := BarAxis.axis_value(0.7, cal, true, GP)
	check(a > 0.0, "ход вперёд положителен")
	approx(a, -b, 1e-6, "инверсия меняет знак")
	check(BarAxis.cal_of({}, "roll") == BarAxis.IDENTITY, "нет калибровки — тождество")
	check(BarAxis.cal_of({"calibration": {"roll": [-1.0, 0.1, 1.0]}}, "roll")[1] == 0.1, "калибровка читается")


func test_pick_device_by_guid() -> void:
	check(BarAxis.pick_device("", _devs()) == 3, "'' — первое")
	check(BarAxis.pick_device("bbb", _devs()) == 5, "по GUID")
	check(BarAxis.pick_device("zzz", _devs()) == -1, "нет такого — -1, не подменять")
	check(BarAxis.pick_device("", []) == -1, "пусто — -1")


func _ic(gp_patch: Dictionary) -> InputController:
	var ic := InputController.new()
	ic.reload_config()
	var cfg: Dictionary = ic._cfg.duplicate(true)
	cfg.invert_pitch = false
	cfg.gamepad.merge(gp_patch, true)
	ic._cfg = cfg
	ic.roll_input = "body"
	return ic


func test_raw_to_control() -> void:
	var ic := _ic({"expo": 0.0, "deadzone": 0.0})
	var sign_r := ic._roll_sign()
	ic.apply_stick(0.5, -0.5)
	approx(ic.control.roll, 0.5 * sign_r, 1e-6, "крен = ход вправо")
	approx(ic.control.pitch, 0.5, 1e-6, "ручка вперёд (ось < 0) — pitch +")
	ic.free()
	# калибровка и инверсия устройства
	ic = _ic({"expo": 0.0, "deadzone": 0.0, "invert_pitch": true, "calibration": {"roll": [-0.5, 0.0, 0.5], "pitch": [-1.0, 0.0, 1.0]}})
	ic.apply_stick(0.25, -0.5)
	approx(ic.control.roll, 0.5 * ic._roll_sign(), 1e-6, "калибровка крена: 0.25 из 0.5")
	approx(ic.control.pitch, -0.5, 1e-6, "инверсия тангажа устройства")
	ic.free()
