extends TestCase
## Контракты модуля ui-controls (docs/ui-controls_contracts.md): У1 — раскладка тангажа.
## Ломается, если раскладку или смысл действий поменяли без правки контракта.


func _keys(action: String) -> Array:
	return Config.get_config("controls").keys.get(action, [])


func test_u1_pitch_actions_shape() -> void:
	var cfg: Dictionary = Config.get_config("controls")
	check(cfg.keys.has("pitch_push_out") and cfg.keys.has("pitch_pull_in"), "У1: действия тангажа есть")
	check(cfg.has("invert_pitch") and cfg.invert_pitch is bool, "У1: invert_pitch: bool")
	check(cfg.invert_pitch == false, "У1: инверсия по умолчанию выключена")
	check(cfg.gamepad.has("pitch_axis"), "У1: gamepad.pitch_axis")
	check("pitch" in ControlInput.new(), "У1: ControlInput.pitch")


func test_u1_default_keys_hang_glider() -> void:
	check("W" in _keys("pitch_push_out") and "Up" in _keys("pitch_push_out"), "У1 v2: W, ↑ — от себя")
	check("S" in _keys("pitch_pull_in") and "Down" in _keys("pitch_pull_in"), "У1 v2: S, ↓ — на себя")
	check(not ("W" in _keys("pitch_pull_in")), "У1 v2: W не «на себя»")
	check(not ("S" in _keys("pitch_push_out")), "У1 v2: S не «от себя»")
