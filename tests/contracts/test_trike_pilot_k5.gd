extends TestCase
## Контракт TP-К5 (docs/contracts/trike-pilot.md): выбор старта «Дельталёт».


func test_trike_allowed() -> void:
	check(FlightSettings.trike_allowed(false), "без сети — можно (TA-К1)")
	check(not FlightSettings.trike_allowed(true), "в сети — нельзя")


func test_vehicle_roundtrip() -> void:
	var s := FlightSettings.defaults()
	check(s.vehicle == "glider", "умолчание glider")
	s.vehicle = "trike"
	s.tow_kind = "aerotow"
	var r := FlightSettings.from_dict(s.to_dict())
	check(r.vehicle == "trike", "trike после сохранения и чтения")
	check(r.tow_kind == "", "при trike tow_kind пуст")
	var b := FlightSettings.from_dict({"vehicle": "bogus"})
	check(b.vehicle == "glider", "bogus -> glider")


func test_launch_option_vehicle() -> void:
	var o := LaunchOptions.parse(PackedStringArray(["--vehicle=trike"]))
	var r := o.apply_to(FlightSettings.defaults())
	check(r.vehicle == "trike", "--vehicle=trike -> trike")
	var o2 := LaunchOptions.parse(PackedStringArray(["--vehicle=zzz"]))
	check(o2.apply_to(FlightSettings.defaults()).vehicle == "glider", "прочее -> glider")
