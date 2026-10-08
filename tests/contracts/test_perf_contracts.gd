extends TestCase
## Контрактные тесты модуля perf (docs/contracts/perf.md): PF-К2 — буфер облаков и параметры качества.
## PF-К4 добавляет PF-5 отдельными методами.

const DOC := "res://docs/contracts/perf.md"
const FIELDS := {
	"shadow_map_px": TYPE_INT, "shadow_steps": TYPE_INT, "coarse_steps": TYPE_INT,
	"max_iterations": TYPE_INT, "fine_step_per_m": TYPE_FLOAT, "fine_step_min_m": TYPE_FLOAT,
	"light_steps": TYPE_INT, "detail": TYPE_BOOL, "lowres_scale": TYPE_FLOAT, "max_buffer_px": TYPE_INT,
}


func _presets() -> Dictionary:
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/atmosphere.json"))
	return j.clouds.quality_presets


func test_pf_k2_version_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find("## PF-К2.")
	check(at >= 0 and text.substr(at, text.find("\n", at) - at).contains("версия 1"), "PF-К2 v1 в документе")


func test_pf_k2_preset_fields() -> void:
	var presets := _presets()
	for q in ["low", "medium", "high"]:
		check(presets.has(q), "пресет %s" % q)
		if not presets.has(q):
			continue
		for f in FIELDS:
			check(presets[q].has(f), "%s.%s есть" % [q, f])
			if not presets[q].has(f):
				continue
			var v: Variant = presets[q][f]
			var t := typeof(v)
			var ok: bool = t == FIELDS[f] or (FIELDS[f] == TYPE_FLOAT and t == TYPE_INT) or (FIELDS[f] == TYPE_INT and t == TYPE_FLOAT and v == floorf(v))
			check(ok, "%s.%s нужного типа" % [q, f])
		var s: float = float(presets[q].lowres_scale)
		check(s > 0.0 and s <= 1.0, "%s.lowres_scale в (0,1]" % q)
		check(int(presets[q].max_buffer_px) >= 0, "%s.max_buffer_px >= 0" % q)


func test_pf_k2_buffer_size_formula() -> void:
	var presets := _presets()
	for q in ["low", "medium", "high"]:
		var s: float = float(presets[q].lowres_scale)
		var mx: int = int(presets[q].max_buffer_px)
		for full in [Vector2i(1920, 1080), Vector2i(3024, 1964), Vector2i(3840, 2160), Vector2i(1, 1)]:
			var b := CloudCompositorEffect.buffer_size(full, s, mx)
			check(b.x >= 1 and b.y >= 1, "%s %s: размер >= 1" % [q, full])
			if mx > 0:
				check(b.x * b.y <= mx + b.x + b.y + 1, "%s %s: площадь %d <= предел %d (+округление)" % [q, full, b.x * b.y, mx])
			var area := float(full.x) * float(full.y)
			if full.x >= 1920 and mx > 0 and area * s * s > mx:
				var k := sqrt(mx / area)
				check(b == Vector2i(ceili(full.x * k), ceili(full.y * k)), "%s %s: по формуле" % [q, full])
		# 1920x1080: предел не срабатывает для low/medium
		var f := Vector2i(1920, 1080)
		if q != "high":
			check(CloudCompositorEffect.buffer_size(f, s, mx) == CloudCompositorEffect.buffer_size(f, s, 0), "%s: на 1080p предел не срабатывает" % q)
	check(CloudCompositorEffect.buffer_size(Vector2i(1920, 1080), 0.5, 0) == Vector2i(960, 540), "0 — без предела")
	var big := CloudCompositorEffect.buffer_size(Vector2i(3024, 1964), 0.5, 240000)
	check(big.x * big.y <= 240000 + big.x + big.y, "3024x1964 ограничен")
	check(absf(float(big.x) / big.y - 3024.0 / 1964.0) < 0.01, "пропорции сохранены")
