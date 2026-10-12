extends TestCase
## Контрактные тесты pilot-hud (docs/contracts/pilot-hud.md). Версии — координатор; проверки формы и
## инвариантов дописывают владельцы: PH-К1 — PH-1, PH-К2 — PH-2/PH-7, PH-К3 — PH-3, PH-К4 — PH-5/PH-6,
## PH-К5 — PH-9, PH-К6 — PH-4, PH-К7 — PH-8. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-hud.md"
const VERSIONS := {
	"PH-К1": 1, "PH-К2": 1, "PH-К3": 1, "PH-К4": 1, "PH-К5": 1, "PH-К6": 1, "PH-К7": 1,
}


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


## PH-К7 (владелец PH-8): интерфейс затенения и инварианты.
func test_sky_shade_contract_ph_k7() -> void:
	var area := 13.5
	var cfg := {"gain": 1.6, "sky_share": 0.3, "h_max_m": 12.0}
	var prev := 2.0
	for h in [1.0, 2.0, 4.0, 8.0]:
		var d := SkyShade.darkening(0.0, h, area, cfg)
		check(d < prev and d <= 1.0, "убывает по h, ≤ 1: %.3f" % d)
		prev = d
	check(SkyShade.darkening(0.0, 13.0, area, cfg) == 0.0, "ноль выше h_max")
	var d_touch := SkyShade.darkening(1.0, 2.5, area, cfg)
	check(d_touch > 0.1 * SkyShade.darkening(0.0, 2.5, area, cfg), "у касания охватывает точку под ногами")
