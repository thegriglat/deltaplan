class_name LocationBuildContext
extends RefCounted
## Контекст сборки места (контракт OA-К3, docs/contracts/osm-any.md). Стадии (DemStage, RiverStage,
## SurfaceStage) читают его и пишут файлы в dir. Менять — только через координатора модуля.

signal progress(stage: String, fraction: float)

## Ключ места (OA-К4).
var key: String = ""
## Центр места, градусы WGS84 (привязан к сетке location_builder.snap_deg).
var center_lat: float = 0.0
var center_lon: float = 0.0
## Папка, куда стадия пишет файлы (временная, user://…).
var dir: String = ""
## Конфиг места (как configs/locations/<id>.json: dem.layers, surface.layers, rivers…).
var spec: Dictionary = {}
## Узел в дереве для HTTPRequest.
var host: Node
## true — сеть запрещена: только кеши и локальные файлы, иначе стадия возвращает ERR_UNAVAILABLE.
var offline: bool = false
## Стадия проверяет между шагами и выходит с ERR_SKIP.
var cancelled: bool = false
## id слоя → PackedFloat32Array высот (после DemStage).
var heights: Dictionary = {}
## id слоя → словарь слоя из meta.json (после DemStage).
var layers: Dictionary = {}
## Число сетевых запросов стадий (проверка «из кеша — без сети»).
var net_requests: int = 0
## Строки журнала сборки (ошибки и замечания стадий).
var log_lines: PackedStringArray = PackedStringArray()


func report(stage: String, fraction: float) -> void:
	progress.emit(stage, clampf(fraction, 0.0, 1.0))


func log_line(text: String) -> void:
	log_lines.append(text)
