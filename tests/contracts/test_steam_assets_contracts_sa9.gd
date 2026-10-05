extends TestCase
## SA-9: build_inventory.py сопоставляет файлы рядом с exe по шаблонам <exe>/<имя> (SA-К3 v2),
## лицензия Microsoft разрешает коммерческое использование (с атрибуцией); build.sh не берёт DLL из PyPI.
## Без сети и GPU: подставной ASSETS.md во временном файле, python3 из системы.

const PY := """
import sys, os, tempfile
sys.path.insert(0, 'tools/release')
import build_inventory as b
md = '''## Тест
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| @<exe>/foo.dll@, @<exe>/bar.*@ | x | y | [Microsoft Software License Terms (VS)](licenses/msvc-runtime.txt) | z |
| @addons/x/baz.dll@ | x | y | MIT | z |
'''
f = tempfile.NamedTemporaryFile('w', suffix='.md', delete=False, encoding='utf-8'); f.write(md.replace('@', chr(96))); f.close()
m = b.build_matcher(b.parse_assets(f.name)); os.unlink(f.name)
def it(path, src):
    return b.make_item(path, 'beside_exe', 1, src, m)
a = it('<exe>/foo.dll', 'addons/x/baz.dll')
print('A', a['commercial_ok'], a['attribution'], a['license'].startswith('[Microsoft'))
c = it('<exe>/bar.so', 'addons/x/none.so')
print('B', c['commercial_ok'])
d = it('<exe>/other/foo.dll', 'nowhere/foo.dll')
print('C', d['assets_md'])
"""


func test_exe_templates_and_microsoft_license() -> void:
	var out := []
	var code := OS.execute("python3", ["-c", PY], out, true)
	var text := "".join(out)
	check(code == 0, "python3 завершился с %d: %s" % [code, text])
	check(text.contains("A True True True"), "шаблон <exe>/foo.dll + Microsoft: %s" % text)
	check(text.contains("B True"), "шаблон <exe>/bar.*: %s" % text)
	check(text.contains("C None"), "<exe> — не любой сегмент пути: %s" % text)


func test_build_sh_no_pypi() -> void:
	var s := FileAccess.get_file_as_string("res://native/air_onnx/build.sh")
	check(not s.is_empty(), "нет build.sh")
	check(not s.contains("pythonhosted"), "build.sh ссылается на PyPI")
	check(s.contains("MSVC_REDIST_DIR"), "build.sh: источник DLL — MSVC_REDIST_DIR")
	check(s.contains("MSVC_ACCEPT_LICENSE"), "build.sh: явное согласие с лицензией")
