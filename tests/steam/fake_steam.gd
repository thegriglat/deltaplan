extends Object
## Подставной «синглтон» GodotSteam для тестов логики SteamService без расширения.

var init_status := 0
var persona := "Steam Eagle"
var callbacks := 0
var init_calls := 0
var init_app_id := -1


func steamInitEx(app_id: int = 0, _embed: bool = false) -> Dictionary:
	init_calls += 1
	init_app_id = app_id
	return {"status": init_status, "verbal": "fake"}


func run_callbacks() -> void:
	callbacks += 1


func getSteamID() -> int:
	return 76561198000000001


func getPersonaName() -> String:
	return persona


func getCurrentGameLanguage() -> String:
	return "russian"
