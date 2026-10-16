extends Node
## TI-3: меню «Полёт…» блокирует погоду у старта с weather и показывает набор.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=training_island_menu

const Fixture := preload("res://tests/fixtures/ti_weather_fixture.gd")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_weather_locked_for_fixed_site() -> void:
	var fx := Fixture.new()
	fx.install()
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	m.settings = Fixture.settings()
	add_child(m)
	check(not m._temp.editable and not m._wind.editable, "ползунки заблокированы")
	check(m._sky_opt.disabled and m._hour.disabled and m._dir_opt.disabled, "списки заблокированы")
	check(not m._day.editable and m._month_opt.disabled, "дата заблокирована")
	check(m._fixed_label.visible, "строка набора видна")
	check(m._fixed_label.text.contains("6") and m._fixed_label.text.contains("270"), "в строке ветер и румб: " + m._fixed_label.text)
	check(m._hours[m._hour.selected] == 12.0 and m._temp.value == 24.0, "показан набор")
	var got: Array = []
	m.done.connect(func(s: FlightSettings) -> void: got.append(s))
	m._on_done()
	check(got.size() == 1 and absf(got[0].wind_speed_kmh - 21.6) < 0.001 and got[0].sky == "partly", "done несёт набор")
	# другое место — снова доступно
	m._row.choose_place({"location": "altai", "site": "tugaya_south"})
	check(m._temp.editable and m._wind.editable and not m._sky_opt.disabled and not m._hour.disabled, "другое место — погода доступна")
	check(not m._fixed_label.visible, "строка скрыта")
	m.queue_free()
	fx.restore()
