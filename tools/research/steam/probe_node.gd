extends Node
# Для экспортированных сборок: та же проверка, что probe.gd, плюс метка steam и список аргументов.
func _ready() -> void:
	var loaded := Engine.has_singleton("Steam")
	var info := ""
	if loaded:
		var s: Object = Engine.get_singleton("Steam")
		var r: Dictionary = s.call("steamInitEx", 480, false)
		info = " gs_version=%s init=%s" % [s.call("get_godotsteam_version"), r.get("status")]
	else:
		info = " init=none"
	print("STEAM_EXPORT loaded=%s%s feature_steam=%s args=%s" % [str(loaded).to_lower(), info, OS.has_feature("steam"), OS.get_cmdline_args()])
	get_tree().quit(0)
