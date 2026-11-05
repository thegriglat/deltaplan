class_name ScenicPlaces
extends RefCounted
## Каталог «Красивые места» (SCP-К1/SCP-К3, docs/contracts/scenic-places.md): загрузка файла, группировка
## по странам, подписи на языке интерфейса. Только static, без состояния.

const FORMAT := "deltaplan.scenic_places"
const KINDS: PackedStringArray = [
	"mountain", "canyon", "lake", "coast", "volcano", "glacier", "valley", "fjord", "desert", "island"
]


static func _empty() -> Dictionary:
	return {"countries": {}, "places": []}


## Каталог из файла; нет файла или неверный формат — пустой каталог + предупреждение.
static func load_catalog(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("ScenicPlaces: нет файла каталога %s" % path)
		return _empty()
	var root: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not root is Dictionary or String(root.get("format", "")) != FORMAT:
		push_warning("ScenicPlaces: неверный формат каталога %s" % path)
		return _empty()
	var countries: Variant = root.get("countries", {})
	var places: Variant = root.get("places", [])
	if not countries is Dictionary or not places is Array:
		push_warning("ScenicPlaces: неверный формат каталога %s" % path)
		return _empty()
	var good: Array = []
	for p: Variant in places:
		if p is Dictionary and p.has("lat") and p.has("lon") and p.has("heading_deg"):
			good.append(p)
	return {"countries": countries, "places": good}


static func _field(p: Dictionary, base: String, lang: String) -> String:
	var s := String(p.get("%s_%s" % [base, lang], ""))
	if s == "":
		s = String(p.get("%s_en" % base, ""))
	return s


static func name(p: Dictionary, lang: String) -> String:
	return _field(p, "name", lang)


static func why(p: Dictionary, lang: String) -> String:
	return _field(p, "why", lang)


## Название типа места (ключ scenic_kind_<kind>).
static func kind_text(p: Dictionary) -> String:
	var kind := String(p.get("kind", ""))
	return TranslationServer.translate("scenic_kind_" + kind) if kind in KINDS else kind


static func country_name(catalog: Dictionary, code: String, lang: String) -> String:
	var names: Variant = (catalog.get("countries", {}) as Dictionary).get(code)
	if names is Dictionary:
		var s := String(names.get(lang, ""))
		if s == "":
			s = String(names.get("en", ""))
		if s != "":
			return s
	return code


static func _sort_key(s: String) -> String:
	return s.to_lower().replace("ё", "е")


## [{"code","name","count","places"}]: страны по алфавиту названия на языке lang, места — по названию.
static func group_by_country(catalog: Dictionary, lang: String) -> Array:
	var by_code := {}
	for p: Dictionary in catalog.get("places", []):
		var code := String(p.get("country", ""))
		if not by_code.has(code):
			by_code[code] = []
		(by_code[code] as Array).append(p)
	var groups: Array = []
	for code: String in by_code:
		var places: Array = by_code[code]
		places.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return _sort_key(ScenicPlaces.name(a, lang)) < _sort_key(ScenicPlaces.name(b, lang))
		)
		groups.append(
			{"code": code, "name": country_name(catalog, code, lang), "count": places.size(), "places": places}
		)
	groups.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return _sort_key(String(a.name)) < _sort_key(String(b.name))
	)
	return groups
