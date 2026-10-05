extends TestCase
## Activity (S3) и SteamPresence (ST-7) на подставном синглтоне: последовательность
## меню → загрузка → старт → полёт → посадка → меню, частота ≤ 1/с, без Steam — ноль обращений.

const Fake := preload("res://tests/steam/fake_steam.gd")
const Service := preload("res://scripts/steam/steam_service.gd")
const ActivityScript := preload("res://scripts/core/activity.gd")
const Presence := preload("res://scripts/steam/steam_presence.gd")


func _rig(active: bool) -> Array:
	var f := Fake.new()
	var s := Service.new()
	s.configure(["--steam"] if active else [], [], false, f if active else null)
	var a := ActivityScript.new()
	var p := Presence.new()
	p.service = s
	p.activity = a
	a.changed.connect(p._mark_dirty)
	return [f, s, a, p]


func _free(r: Array) -> void:
	for o: Object in r:
		o.free()


func test_activity_changed_only_on_change() -> void:
	var a := ActivityScript.new()
	var hits := [0]
	a.changed.connect(func(): hits[0] += 1)
	a.set_state({"mode": "menu"})
	check(hits[0] == 0, "то же значение — тишина")
	a.set_state({"mode": "loading", "place": "X", "bogus": 1})
	check(hits[0] == 1 and a.state().mode == "loading" and a.state().place == "X", "смена")
	check(not a.state().has("bogus"), "неизвестные ключи не пускаем")
	a.free()


func test_mode_for_phase() -> void:
	var m := ActivityScript.mode_for_phase
	check(m.call("standing") == "launch" and m.call("walking") == "launch" and m.call("running") == "launch", "старт")
	check(m.call("flying") == "flying" and m.call("landed") == "landed" and m.call("failed") == "landed", "полёт/посадка")


func test_sequence_keys_and_rate() -> void:
	var r := _rig(true)
	var f: Object = r[0]
	var a: Node = r[2]
	var p: Node = r[3]
	var t := 0.0
	var seq := [
		[{"mode": "menu"}, "#St_Menu"],
		[{"mode": "loading", "place": "Алтай"}, "#St_Loading"],
		[{"mode": "launch"}, "#St_Launch"],
		[{"mode": "flying", "alt_msl": 1850}, "#St_Flying"],
		[{"mode": "landed"}, "#St_Landed"],
		[{"mode": "menu", "place": ""}, "#St_Menu"],
	]
	for step: Array in seq:
		a.set_state(step[0])
		t += 1.0
		p.flush(t)
		check(f.rp.get("steam_display") == step[1], "%s -> %s" % [step[1], f.rp.get("steam_display")])
	check(f.rp.get("place", "") == "" and f.rp.get("alt") == "1850", "alt остался, place очищен: %s" % [f.rp])
	_free(r)


func test_rate_limit_and_only_changed() -> void:
	var r := _rig(true)
	var f: Object = r[0]
	var a: Node = r[2]
	var p: Node = r[3]
	a.set_state({"mode": "flying", "place": "Алтай", "alt_msl": 1000})
	var n1: int = p.flush(10.0)
	check(n1 > 0, "первая отправка")
	a.set_state({"alt_msl": 1100})
	check(p.flush(10.5) == 0, "раньше секунды — нет")
	var before: int = f.rp_calls.size()
	check(p.flush(11.0) == 1 and f.rp_calls.size() == before + 1 and f.rp_calls.back() == ["alt", "1100"], "только изменившийся ключ")
	check(p.flush(20.0) == 0, "ничего не менялось — нет вызовов")
	_free(r)


func test_net_and_lobby_keys() -> void:
	var r := _rig(true)
	var f: Object = r[0]
	var a: Node = r[2]
	var p: Node = r[3]
	a.set_state({"mode": "flying", "net": true, "zone_code": "ABC", "peers": 3, "place": "Алтай"})
	p.set_lobby(12345)
	p.flush(5.0)
	check(f.rp.get("steam_display") == "#St_Flying_Net" and f.rp.get("peers") == "3", "сетевой токен")
	check(f.rp.get("steam_player_group") == "12345" and f.rp.get("steam_player_group_size") == "3", "группа")
	check(f.rp.get("connect") == "+connect_lobby 12345", "connect")
	p.set_lobby(0)
	p.flush(7.0)
	check(f.rp.get("steam_player_group") == "" and f.rp.get("connect") == "" and f.rp.get("steam_player_group_size") == "", "вне лобби очищены")
	_free(r)


func test_inactive_makes_no_calls() -> void:
	var r := _rig(false)
	var a: Node = r[2]
	var p: Node = r[3]
	a.set_state({"mode": "flying", "alt_msl": 500})
	check(p.flush(100.0) == 0, "неактивен — ноль вызовов")
	p._exit_tree()
	check(r[1].api() == null, "api() пуст")
	_free(r)


func test_exit_clears_presence() -> void:
	var r := _rig(true)
	r[3].flush(5.0)
	r[3]._exit_tree()
	check(r[0].rp_cleared == 1, "clearRichPresence при выходе")
	_free(r)


func test_token_file() -> void:
	var text := FileAccess.get_file_as_string("res://steam/partner/rich_presence.vdf")
	for lang in ["english", "russian"]:
		check(text.contains("\"%s\"" % lang), lang)
	for m in Presence.MODES:
		var tok: String = "#St_" + m.capitalize()
		check(text.count("\"%s\"" % tok) == 2 and text.count("\"%s_Net\"" % tok) == 2, "токен " + tok)
	check(FileAccess.file_exists("res://steam/partner/.gdignore"), ".gdignore")
