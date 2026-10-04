class_name PopularPlaces
extends RefCounted
## Каталог «Популярные места» (PP-К1/PP-К2, docs/contracts/popular-places.md): загрузка файла стартов
## дельтаплана, группировка по странам, поиск по названию, подписи. Только static, без состояния.

const FORMAT := "deltaplan.hg_takeoffs"
## 16 румбов: «откуда ветер»; ключи перевода — DIR_KEYS.
const DIRS: PackedStringArray = [
	"N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
]
const DIR_KEYS := {
	"N": "places_dir_n", "NNE": "places_dir_nne", "NE": "places_dir_ne", "ENE": "places_dir_ene",
	"E": "places_dir_e", "ESE": "places_dir_ese", "SE": "places_dir_se", "SSE": "places_dir_sse",
	"S": "places_dir_s", "SSW": "places_dir_ssw", "SW": "places_dir_sw", "WSW": "places_dir_wsw",
	"W": "places_dir_w", "WNW": "places_dir_wnw", "NW": "places_dir_nw", "NNW": "places_dir_nnw",
}


static func _empty() -> Dictionary:
	return {"countries": {}, "takeoffs": []}


## Каталог из файла; нет файла или неверный формат — пустой каталог + предупреждение.
static func load_catalog(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("PopularPlaces: нет файла каталога %s" % path)
		return _empty()
	var root: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not root is Dictionary or String(root.get("format", "")) != FORMAT:
		push_warning("PopularPlaces: неверный формат каталога %s" % path)
		return _empty()
	var countries: Variant = root.get("countries", {})
	var takeoffs: Variant = root.get("takeoffs", [])
	if not countries is Dictionary or not takeoffs is Array:
		push_warning("PopularPlaces: неверный формат каталога %s" % path)
		return _empty()
	return {"countries": countries, "takeoffs": takeoffs}


## Язык названий: "ru", если интерфейс русский, иначе "en".
static func lang() -> String:
	return "ru" if TranslationServer.get_locale().begins_with("ru") else "en"


static func country_name(catalog: Dictionary, code: String, language: String) -> String:
	if code == "":
		return TranslationServer.translate("places_country_unknown")
	var names: Variant = (catalog.get("countries", {}) as Dictionary).get(code)
	if names is Dictionary:
		var s := String(names.get(language, ""))
		if s == "":
			s = String(names.get("en", ""))
		if s != "":
			return s
	return code


static func display_name(p: Dictionary) -> String:
	var n := String(p.get("name", ""))
	if n != "":
		return n
	return TranslationServer.translate("places_unnamed") % [float(p.get("lat", 0.0)), float(p.get("lon", 0.0))]


static func _sort_key(s: String) -> String:
	return s.to_lower().replace("ё", "е")


## Страны по алфавиту названия (группа без страны — последней); места внутри — по алфавиту.
static func group_by_country(catalog: Dictionary, language: String) -> Array:
	var by_code := {}
	for t: Dictionary in catalog.get("takeoffs", []):
		var code := String(t.get("country", ""))
		if not by_code.has(code):
			by_code[code] = []
		(by_code[code] as Array).append(t)
	var groups: Array = []
	for code: String in by_code:
		var places: Array = by_code[code]
		places.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return _sort_key(display_name(a)) < _sort_key(display_name(b))
		)
		groups.append(
			{
				"code": code,
				"name": country_name(catalog, code, language),
				"count": places.size(),
				"places": places
			}
		)
	groups.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if (a.code == "") != (b.code == ""):
				return b.code == ""
			return _sort_key(String(a.name)) < _sort_key(String(b.name))
	)
	return groups


## Места, в названии которых есть query (без учёта регистра, ё = е, пробелы по краям не считаются).
static func search(places: Array, query: String) -> Array:
	var q := _sort_key(query.strip_edges())
	if q == "":
		return places.duplicate()
	var out: Array = []
	for p: Dictionary in places:
		if _sort_key(display_name(p)).contains(q):
			out.append(p)
	return out


## Направления ветра старта на языке интерфейса через запятую; нет данных — "".
static func orientation_text(p: Dictionary) -> String:
	var parts: PackedStringArray = []
	for d: Variant in p.get("orientation", []):
		if DIR_KEYS.has(d):
			parts.append(TranslationServer.translate(DIR_KEYS[d]))
	return ", ".join(parts)
