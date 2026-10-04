class_name WingCatalog
extends RefCounted
## Каталог крыльев для меню «Полёт…»: группы из configs/wing_groups.json (в порядке файла),
## крылья группы из configs/wings/*.json (по полю group), диапазоны качества и ветра группы.
## Путь крыла — как в FlightSettings.wing: "wings/<id>". План — docs/archive/plan/wings-lineup.md §2, §6.

const GROUPS_CONFIG := "wing_groups"
const CLASSES_CONFIG := "wing_classes"


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


## Крылья группы ("wings/<id>"): по возрастанию reference.best_glide, при равенстве — верхний предел ветра класса.
static func wings_in_group(group_id: String) -> PackedStringArray:
	var items: Array[Dictionary] = []
	for w in Config.list_configs("wings"):
		var cfg := Config.get_config(w)
		if String(cfg.get("group", "")) != group_id:
			continue
		items.append({"path": String(w), "glide": best_glide(cfg), "wind": wind_limit(cfg).y})
	items.sort_custom(_less)
	var out := PackedStringArray()
	for it in items:
		out.append(it.path)
	return out


## Диапазон качества крыльев группы: Vector2(мин, макс); нулевой, если крыльев нет.
static func glide_range(group_id: String) -> Vector2:
	return _range(group_id, best_glide)


## Диапазон предела ветра крыльев группы, м/с: Vector2(наименьший lo, наибольший hi); нулевой, если крыльев нет.
static func wind_range(group_id: String) -> Vector2:
	var r := Vector2(INF, -INF)
	for w in wings_in_group(group_id):
		var l := wind_limit(Config.get_config(w))
		r = Vector2(minf(r.x, l.x), maxf(r.y, l.y))
	return r if r.x <= r.y else Vector2.ZERO


static func best_glide(cfg: Dictionary) -> float:
	return float(cfg.get("reference", {}).get("best_glide", 0.0))


## Класс крыла 1–4 (поле wind_class); 0 — не задан.
static func wind_class(cfg: Dictionary) -> int:
	return int(cfg.get("wind_class", 0))


## Ключ перевода названия класса крыла (по поперечине); "" — класс не задан.
static func class_name_key(cfg: Dictionary) -> String:
	return String(_class(cfg).get("name_key", ""))


## Предел ветра класса крыла, м/с: Vector2(от, до); нулевой, если класс не задан. Подсказка, не запрет.
static func wind_limit(cfg: Dictionary) -> Vector2:
	var lim: Array = _class(cfg).get("wind_limit_ms", [])
	return Vector2(float(lim[0]), float(lim[1])) if lim.size() == 2 else Vector2.ZERO


## Диапазон слайдера ветра меню «Полёт…» и зажим настроек: Vector3(мин, макс, шаг), м/с.
## Низ 0, шаг 1, верх — наибольший hi предела ветра среди классов (configs/wing_classes.json).
static func wind_menu_range() -> Vector3:
	var hi := 0.0
	for c: Dictionary in Config.get_config(CLASSES_CONFIG).get("classes", {}).values():
		var lim: Array = c.get("wind_limit_ms", [])
		if lim.size() == 2:
			hi = maxf(hi, float(lim[1]))
	return Vector3(0.0, hi, 1.0)


static func _class(cfg: Dictionary) -> Dictionary:
	return Config.get_config(CLASSES_CONFIG).get("classes", {}).get(str(wind_class(cfg)), {})


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
