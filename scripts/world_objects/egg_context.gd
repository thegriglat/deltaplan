class_name EggContext
extends RefCounted
## Контекст пасхалки (docs/easter_eggs_contracts.md → К2): планировщик заполняет один раз за
## update() и отдаёт всем пасхалкам. ТОЛЬКО ЧТЕНИЕ: ничего из этого пасхалка не меняет.

## Время мира, с (Game.world_time(); в сети — часы зоны).
var t := 0.0
## Час по часам места, 0–24.
var hour := 12.0
## Единичный вектор к солнцу, мир (Y вверх); y < 0 — солнце под горизонтом.
var to_sun := Vector3.UP
## Ключ мира (сид, место, дата, погода) — от него зависит расписание.
var world_key := ""
## Текущая камера (headless — может быть null).
var camera: Camera3D
## Положение крыла игрока, мир, м.
var pilot_pos := Vector3.ZERO
## Погода атмосферы (air.weather): не менять, не хранить дольше кадра.
var weather: Dictionary = {}
## Кромка облаков над уровнем моря, м; нет облаков — NAN.
var cloudbase_msl := NAN
## Пресет графики: low / medium / high.
var graphics := "high"
## Высота рельефа, м: Callable(x: float, z: float) -> float.
var height_at := func(_x: float, _z: float) -> float: return 0.0
## Плотность облака в точке, 0–1: Callable(p: Vector3) -> float (нет облаков — 0).
var cloud_density_at := func(_p: Vector3) -> float: return 0.0
## Рельеф и слои OSM — только чтение (E6, E7, E8, E10).
var terrain: Terrain
## Воздух — только чтение (air_velocity_at — лишь если тест К7 зелёный с этим вызовом).
var air: Node3D
