class_name WingCatalog
extends RefCounted
## Каталог крыльев для меню «Полёт…»: группы из configs/wing_groups.json (в порядке файла),
## крылья группы из configs/wings/*.json (по полю group), диапазоны качества и ветра группы.
## Путь крыла — как в FlightSettings.wing: "wings/<id>". План — docs/plan/wings_lineup.md §2, §6.

const GROUPS_CONFIG := "wing_groups"


## Группы по порядку: [{id, name, hint}] (name, hint — ключи перевода).
static func groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g: Dictionary in Config.get_config(GROUPS_CONFIG).get("groups", []):
		out.append(g)
	return out


## Id группы крыла ("wings/<id>" или "<id>"); "" — нет такого крыла или группа не задана.
static func group_of(wing_path: String) -> String:
	var path := _path(wing_path)
	if not Config.list_configs("wings").has(path):
		return ""
	return String(Config.get_config(path).get("group", ""))


## Крылья группы ("wings/<id>"): по возрастанию reference.best_glide, при равенстве — wind_max_ms.
static func wings_in_group(group_id: String) -> PackedStringArray:
	var items: Array[Dictionary] = []
	for w in Config.list_configs("wings"):
		var cfg := Config.get_config(w)
		if String(cfg.get("group", "")) != group_id:
			continue
		items.append({"path": String(w), "glide": best_glide(cfg), "wind": wind_max(cfg)})
	items.sort_custom(_less)
	var out := PackedStringArray()
	for it in items:
		out.append(it.path)
	return out


## Диапазон качества крыльев группы: Vector2(мин, макс); нулевой, если крыльев нет.
static func glide_range(group_id: String) -> Vector2:
	return _range(group_id, best_glide)


## Диапазон «ветер до» крыльев группы, м/с: Vector2(мин, макс); нулевой, если крыльев нет.
static func wind_range(group_id: String) -> Vector2:
	return _range(group_id, wind_max)


static func best_glide(cfg: Dictionary) -> float:
	return float(cfg.get("reference", {}).get("best_glide", 0.0))


static func wind_max(cfg: Dictionary) -> float:
	return float(cfg.get("wind_max_ms", 0.0))


static func _range(group_id: String, value: Callable) -> Vector2:
	var r := Vector2(INF, -INF)
	for w in wings_in_group(group_id):
		var v: float = value.call(Config.get_config(w))
		r = Vector2(minf(r.x, v), maxf(r.y, v))
	return r if r.x <= r.y else Vector2.ZERO


static func _less(a: Dictionary, b: Dictionary) -> bool:
	if a.glide != b.glide:
		return a.glide < b.glide
	if a.wind != b.wind:
		return a.wind < b.wind
	return a.path < b.path


static func _path(wing: String) -> String:
	return wing if wing.begins_with("wings/") else "wings/" + wing
