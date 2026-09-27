class_name InstrumentTask
extends RefCounted
## Задание на приборе и глиссада до цели (страницы 3–4, FR-25).
## Пункты: [{name: String, position: Vector3 (y — высота земли у пункта), radius_m: float}].
## Цель — активный пункт. Требуемое качество = расстояние / (высота − высота цели − запас).

## Пункты задания (пусто — «нет задания»).
var points: Array[Dictionary] = []
## Индекс активного пункта (цели).
var active: int = 0
var safety_height_m: float = 150.0
## Состояние соревнования от TaskTracker.get_state() (пусто — просто пункты, без гонки).
var race: Dictionary = {}
var default_radius_m: float = 400.0


func setup(cfg: Dictionary = {}) -> void:
	if cfg.is_empty():
		cfg = Config.get_config("instruments")
	var t: Dictionary = cfg.get("task", {})
	safety_height_m = float(t.get("safety_height_m", safety_height_m))
	default_radius_m = float(t.get("reach_radius_default_m", default_radius_m))


func set_points(list: Array, active_index: int = 0) -> void:
	points.clear()
	for p in list:
		var d: Dictionary = p
		points.append(d)
	active = clampi(active_index, 0, maxi(points.size() - 1, 0))


## Идёт соревнование (есть состояние от TaskTracker).
func is_race() -> bool:
	return not race.is_empty()


## Пункт пройден: до активного в гонке (в гоуле — все).
func is_passed(i: int) -> bool:
	if not is_race():
		return false
	if String(race.get("phase", "")) == "goal":
		return true
	return i < active


## Расстояние «до цели» для страницы 3: в гонке — оптимизированное до гоула, иначе до пункта.
func distance_for_glide(pos: Vector3) -> float:
	if is_race():
		return float(race.get("remaining_distance_m", INF))
	return distance_to_target(pos)


## Требуемое качество для страницы 3: в гонке — от TaskTracker (до гоула), иначе геометрия.
func glide_needed(pos: Vector3, altitude_msl: float) -> float:
	if is_race():
		var g := float(race.get("required_glide", INF))
		return INF if is_nan(g) or g <= 0.0 else g
	return required_glide(pos, altitude_msl)


## Высота прибытия (на гоул в гонке, на цель иначе) при качестве glide, м; NAN — нельзя оценить.
func arrival_for_glide(pos: Vector3, altitude_msl: float, glide: float) -> float:
	if not is_race():
		return arrival_height(pos, altitude_msl, glide)
	if points.is_empty() or glide == INF or glide <= 0.0:
		return NAN
	var goal: Vector3 = points[points.size() - 1].get("position", Vector3.ZERO)
	return altitude_msl - goal.y - distance_for_glide(pos) / glide


func has_target() -> bool:
	return active >= 0 and active < points.size()


func target() -> Dictionary:
	return points[active] if has_target() else {}


func target_name() -> String:
	return String(target().get("name", "")) if has_target() else ""


## Горизонтальное расстояние до края цилиндра цели, м (INF — цели нет).
func distance_to_target(pos: Vector3) -> float:
	if not has_target():
		return INF
	return distance_to_point(pos, active)


func distance_to_point(pos: Vector3, i: int) -> float:
	var p: Dictionary = points[i]
	var tp: Vector3 = p.get("position", Vector3.ZERO)
	var r := float(p.get("radius_m", default_radius_m))
	return maxf(Vector2(tp.x - pos.x, tp.z - pos.z).length() - r, 0.0)


## Требуемое качество до цели с запасом высоты; INF — не долететь (высоты не хватает) или цели нет.
func required_glide(pos: Vector3, altitude_msl: float) -> float:
	if not has_target():
		return INF
	var tp: Vector3 = target().get("position", Vector3.ZERO)
	var usable := altitude_msl - tp.y - safety_height_m
	if usable <= 0.0:
		return INF
	return distance_to_target(pos) / usable


## Высота прибытия над целью (без запаса) при текущем качестве glide, м; NAN — нельзя оценить.
func arrival_height(pos: Vector3, altitude_msl: float, glide: float) -> float:
	if not has_target() or glide == INF or glide <= 0.0:
		return NAN
	var tp: Vector3 = target().get("position", Vector3.ZERO)
	return altitude_msl - tp.y - distance_to_target(pos) / glide
