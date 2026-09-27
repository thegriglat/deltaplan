class_name BuildInfo
extends RefCounted
## Версия и сборка для «Об игре»: версия — project.godot → application/config/version,
## коммит — res://data/build_info.json (пишет tools/build.sh при сборке; в git не хранится).
## Без файла (запуск из редактора/исходников) — коммит берётся из git, если он есть.

const INFO_PATH := "res://data/build_info.json"


static func version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## Первые 6 символов коммита сборки («» — неизвестно); «+» в конце — были незакоммиченные правки.
static func commit() -> String:
	if FileAccess.file_exists(INFO_PATH):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(INFO_PATH))
		if d is Dictionary:
			return String(d.get("commit", ""))
	return _git_commit()


## «Версия 0.4.0 · сборка 1a2b3c».
static func text() -> String:
	var c := commit()
	if c == "":
		return TranslationServer.translate("Версия %s") % version()
	return TranslationServer.translate("Версия %s · сборка %s") % [version(), c]


static func _git_commit() -> String:
	if OS.has_feature("template"):
		return ""
	var out: Array = []
	var root := ProjectSettings.globalize_path("res://")
	if OS.execute("git", ["-C", root, "rev-parse", "--short=6", "HEAD"], out) != 0 or out.is_empty():
		return ""
	return String(out[0]).strip_edges()
