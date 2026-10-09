extends Node
## Подсказка по F-клавишам (FKeyHint): пункт виден, только пока его слой выключен.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _keys(dbg: DebugOverlays) -> PackedStringArray:
	var out: PackedStringArray = []
	for d in FKeyHint.visible_items(dbg):
		out.append(d.key)
	return out


func test_items_follow_state() -> void:
	var dbg := DebugOverlays.new()
	add_child(dbg)  # _ready регистрирует действия F1/F5/F6
	check(_keys(dbg) == PackedStringArray(["F1", "F5", "F6"]), "всё выключено: %s" % [_keys(dbg)])
	dbg.wind_on = true
	check(_keys(dbg) == PackedStringArray(["F1", "F6"]), "ветер включён: %s" % [_keys(dbg)])
	dbg.perf_on = true
	dbg.thermals_on = true
	check(_keys(dbg).is_empty(), "все включены — пусто")
	check(FKeyHint.text_for(dbg) == "", "текст пуст")
	dbg.wind_on = false
	check(FKeyHint.text_for(dbg).begins_with("F5 — "), "ветер вернулся: " + FKeyHint.text_for(dbg))
	check(FKeyHint.text_for(null) == "", "без DebugOverlays пусто")
	dbg.free()


func test_label_updates() -> void:
	var dbg := DebugOverlays.new()
	add_child(dbg)
	var h := FKeyHint.new()
	h.overlays = dbg
	add_child(h)
	var lbl: Label = h.get_node("Hint")
	check(lbl.visible and lbl.text.contains("F6"), "виден: " + lbl.text)
	dbg.perf_on = true
	dbg.wind_on = true
	dbg.thermals_on = true
	h.refresh()
	check(not lbl.visible, "все включены — скрыт")
	h.free()
	dbg.free()
