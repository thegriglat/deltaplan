class_name Language
extends RefCounted
## Язык интерфейса (NFR-4): строки — ключи в locale/ui.csv (колонки ru, en), tr() по ключу.
## Выбор хранится в configs/game.json → language (правка пилота — user://configs/game.json);
## пусто — английский (язык по умолчанию, от локали ОС не зависит).
## Список языков — game.json → languages {код: название на этом языке}.

const FALLBACK := "en"


## Доступные языки: {код: самоназвание} в порядке переключения.
static func available() -> Dictionary:
	var langs: Variant = Config.value("game", "languages", {"ru": "Русский", "en": "English"})
	return langs if langs is Dictionary else {"ru": "Русский", "en": "English"}


## Язык по сохранённому выбору (выбор есть и известен — он, иначе английский).
static func resolve(saved: String) -> String:
	return saved if saved != "" and available().has(saved) else FALLBACK


## Язык, который должен стоять сейчас (из настроек).
static func configured() -> String:
	return resolve(String(Config.value("game", "language", "")))


static func current() -> String:
	return TranslationServer.get_locale().substr(0, 2)


## Включить язык (без записи).
static func apply(code: String) -> void:
	TranslationServer.set_locale(code)


## Включить и запомнить в профиле пилота (user://configs/game.json).
static func select(code: String, dir: String = UserSettings.DEFAULT_DIR) -> bool:
	apply(code)
	var ok := UserSettings.save_patch("game", {"language": code}, dir)
	Config.reload()
	return ok


## Следующий (step = 1) или предыдущий (step = -1) язык в списке — для переключателя «◀ ▶».
static func neighbour(code: String, step: int) -> String:
	var codes: Array = available().keys()
	if codes.is_empty():
		return code
	var i := codes.find(code)
	return String(codes[posmod(i + step, codes.size())])
