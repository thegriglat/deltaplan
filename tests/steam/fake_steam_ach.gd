extends Object
## Подставной синглтон GodotSteam для ачивок: хранит открытые, считает вызовы.

var achieved: Dictionary = {}
var set_calls: Array = []
var store_calls := 0


func steamInitEx(_app_id: int = 0, _embed: bool = false) -> Dictionary:
	return {"status": 0, "verbal": "fake"}


func run_callbacks() -> void:
	pass


func getAchievement(api_name: String) -> Dictionary:
	return {"ret": true, "achieved": achieved.has(api_name)}


func setAchievement(api_name: String) -> bool:
	set_calls.append(api_name)
	achieved[api_name] = true
	return true


func storeStats() -> bool:
	store_calls += 1
	return true
