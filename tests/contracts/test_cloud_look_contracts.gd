extends TestCase
## Контрактные тесты cloud-look (docs/contracts/cloud-look.md). CLK-К1 v1 — стенд кадров меню:
## сюжеты tools/shots/menu_art.json не меняются ради картинки (решение пользователя 2026-10-23).
## CLK-К2 v1 — имена стыка поля (CLF-К2) и света солнца (HH4) в общем шейдере облаков на месте.

const MENU_ART := "res://tools/shots/menu_art.json"
const MENU_ART_SHA256 := "b0a066f1789bb1452145d9f6dbf224c62ad809d18f44367f8ea313da612dcb44"
const CLOUD_COMMON := "res://scripts/atmosphere/cloud_common.gdshaderinc"


func test_k1_menu_art_unchanged() -> void:
	check(FileAccess.file_exists(MENU_ART), "menu_art.json есть")
	var sha := FileAccess.get_sha256(MENU_ART)
	check(sha == MENU_ART_SHA256, "menu_art.json не менялся (CLK-К1): sha256 %s" % sha)


func test_k2_shader_interface_names() -> void:
	var src := FileAccess.get_file_as_string(CLOUD_COMMON)
	check(src != "", "cloud_common.gdshaderinc читается")
	for name: String in ["cf_rect", "cf_base", "cf_edge", "cloud_sun_l(", "cf_sample("]:
		check(src.contains(name), "в cloud_common.gdshaderinc есть %s (CLF-К2 / HH4)" % name)
