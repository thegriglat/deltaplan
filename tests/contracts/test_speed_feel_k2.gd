extends TestCase
## Контракт SPF-К2 (docs/contracts/speed-feel.md): поток у узла -> трепет ленточки.
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/speed-feel.md"


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/speed-feel.md читается")
	var re := RegEx.create_from_string("(?m)^## (SPF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("SPF-К2", 0) == 1, "SPF-К2 (v1) в заголовках: %s" % found)


func test_config_keys() -> void:
	var cfg: Dictionary = Config.get_config("instruments").get("telltale", {})
	for k in ["flutter_strouhal", "flutter_ref_len", "flutter_max_hz", "flutter_amp_decay_from_ms", "flutter_amp_decay_exp"]:
		check(cfg.has(k), "telltale.%s" % k)
		check(cfg.has(k + "_doc"), "telltale.%s_doc" % k)
	check(not cfg.has("flutter_hz_per_ms"), "flutter_hz_per_ms убран")
	check(float(cfg.get("flutter_max_hz", 99.0)) <= 15.0, "flutter_max_hz <= 15")


func test_flutter_hz_field() -> void:
	var cfg: Dictionary = Config.get_config("instruments").get("telltale", {})
	var m := TelltaleModel.new()
	m.setup(cfg)
	for i in 60:
		m.step(1.0 / 60.0, Vector3(2.0, 0, 0))
	var expect := minf(
		float(cfg["flutter_strouhal"]) * 2.0 / float(cfg["flutter_ref_len"]), float(cfg["flutter_max_hz"])
	)
	check(absf(m.flutter_hz - expect) < 1.0e-4, "flutter_hz = St*s/L: %s vs %s" % [m.flutter_hz, expect])
