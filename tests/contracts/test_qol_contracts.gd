extends TestCase
## Контрактные тесты модуля qol (docs/contracts/qol.md): QL-К1 — номер полёта и перезапуски.
## Правка контракта (версия +1) — вместе с этим файлом. Поведение — tests/game/test_qol_cycle.gd.

const DOC := "res://docs/contracts/qol.md"


func _doc_line(head: String) -> String:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find(head)
	return text.substr(at, text.find("\n", at) - at) if at >= 0 else ""


func test_k1_version_in_doc() -> void:
	check(_doc_line("## QL-К1.").contains("(v1)"), "QL-К1 v1 в документе")


func test_k1_game_interface() -> void:
	var scr: Script = load("res://scripts/game/game.gd")
	var props := scr.get_script_property_list().map(func(p: Dictionary) -> String: return p.name)
	check(props.has("flight_no"), "Game.flight_no")
	var restart: Dictionary = {}
	for m in scr.get_script_method_list():
		if m.name == "restart":
			restart = m
	check(not restart.is_empty(), "Game.restart")
	if not restart.is_empty():
		check(restart.args.size() == 1 and restart.args[0].name == "keep_clock", "restart(keep_clock)")
		check(restart.default_args.size() == 1 and restart.default_args[0] == false, "keep_clock = false по умолчанию")
	var sigs := scr.get_script_signal_list()
	var found := false
	for s in sigs:
		if s.name == "flight_ended":
			found = s.args.size() == 2 and s.args[0].name == "kind" and s.args[1].name == "info"
	check(found, "flight_ended(kind, info)")
