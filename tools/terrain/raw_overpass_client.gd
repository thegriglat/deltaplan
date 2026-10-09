extends OverpassClient
## Клиент Overpass «из файлов» (OA-7, сборка встроенных мест без сети): вместо запроса склеивает элементы
## сырых ответов <dir>/<id>_<слой>.json (~/.cache/deltaplan_osm, только чтение) в один ответ.
## Упаковку делает тот же OsmStage.

const LAYERS := ["roads", "buildings", "power", "water", "places", "landuse"]

var dir: String = ""
var id: String = ""


func fetch(_ctx: LocationBuildContext, _urls: Array, _query: String, _timeout_s: float, _user_agent: String) -> PackedByteArray:
	var elements: Array = []
	for layer: String in LAYERS:
		var path := dir.path_join("%s_%s.json" % [id, layer])
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not raw is Dictionary:
			last_error = "нет сырого ответа " + path
			return PackedByteArray()
		elements.append_array(raw.elements)
	return JSON.stringify({"elements": elements}).to_utf8_buffer()
