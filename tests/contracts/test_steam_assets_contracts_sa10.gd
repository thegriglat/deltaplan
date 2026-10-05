extends TestCase
## SA-10: VC++ runtime из VS Build Tools через msvc-wine: скрипт воспроизведения и закрепления в build.sh.


func test_fetch_script() -> void:
	var s := FileAccess.get_file_as_string("res://tools/release/fetch_msvc_redist.sh")
	check(not s.is_empty(), "нет tools/release/fetch_msvc_redist.sh")
	check(s.contains("MSVC_ACCEPT_LICENSE"), "скрипт: явное согласие с лицензией")
	check(s.contains("MSVC_WINE_COMMIT="), "скрипт: закреплён коммит msvc-wine")
	check(s.contains("--accept-license"), "скрипт: vsdownload.py с --accept-license")
	check(s.contains("CRT.Redist.X64"), "скрипт: только Redist x64")


func test_build_sh_pins() -> void:
	var s := FileAccess.get_file_as_string("res://native/air_onnx/build.sh")
	check(s.contains("MSVC_RT_VER=14.44.35211"), "build.sh: версия VC++ runtime")
	check(s.contains("fetch_msvc_redist.sh"), "build.sh: ссылка на скрипт получения Redist")
	for d in ["msvcp140.dll", "msvcp140_1.dll", "vcruntime140.dll", "vcruntime140_1.dll"]:
		check(s.contains(d + "="), "build.sh: нет хэша %s" % d)
