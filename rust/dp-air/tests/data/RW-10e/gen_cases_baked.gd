extends "res://tools/wind_fixtures/gen_fixtures.gd"
## RW-10e: эталоны ongudai_* на том же поле, что читает крейт (запечённое f16 из tests/data/RW-10d|RW-10e).
## Как gen_fixtures, но поле не считается на GPU, а читается: --fields=<каталог с <случай>/field.json+field.bin>.
## Запуск: run_cases.sh <копия на c591b1026> <каталог вывода> <каталог полей> [случаи]


func _solve_field(c: Dictionary, _ctx: Dictionary, _weather: Dictionary) -> Array:
	var dir := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fields="):
			dir = a.substr(9)
	var fs := AirBakedField.load_file(dir.path_join(String(c.name)).path_join("field.json"))
	if fs == null:
		push_error("gen_cases_baked: нет поля %s" % c.name)
		return []
	var out: Array = []
	for f in fs.levels:
		out.append(f)
	print("gen_cases_baked: %s — поле из файла, уровней %d" % [c.name, out.size()])
	return out
