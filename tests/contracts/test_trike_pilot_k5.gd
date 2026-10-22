extends TestCase
## Контракт TP-К5 (docs/contracts/trike-pilot.md): выбор старта «Дельталёт».


func _site(loc: String, id: String) -> Dictionary:
	for st: Dictionary in Locations.config(loc).get("start_sites", []):
		if String(st.get("id", "")) == id:
			return st
	return {}


func test_trike_allowed() -> void:
	var tow_site := _site("wilotree_park", "runway_36")
	var plain := _site("altai", "sinyukha_west")
	check(not tow_site.is_empty() and not plain.is_empty(), "места из configs/locations/ читаются")
	check(FlightSettings.trike_allowed(tow_site, false), "место с tow, без сети — можно")
	check(not FlightSettings.trike_allowed(tow_site, true), "в сети — нельзя")
	check(not FlightSettings.trike_allowed(plain, false), "место без tow — нельзя")
	check(not FlightSettings.trike_allowed({}, false), "точка с карты — нельзя")


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
