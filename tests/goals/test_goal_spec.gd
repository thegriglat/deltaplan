extends TestCase
## GoalSpec (GL-К1): make и validate.


func test_make() -> void:
	var g := GoalSpec.make("height", "easy", 500.0)
	check(g.kind == "height" and g.level == "easy" and g.value == 500.0, "поля")
	check(g.task == "", "task по умолчанию пуст")
	check(GoalSpec.KINDS.size() == 8, "восемь видов")


func test_validate_ok() -> void:
	var goals := [
		GoalSpec.make("height", "easy", 500.0),
		GoalSpec.make("return", "medium", 5000.0),
		GoalSpec.make("speed", "custom", 1800.0),
		GoalSpec.make("route", "medium", 0.0, "some_task"),
		GoalSpec.make("landing", "hard", 25.0),
	]
	check(GoalSpec.validate(goals).is_empty(), "годный список: %s" % GoalSpec.validate(goals))
	check(GoalSpec.validate([]).is_empty(), "пустой список годен")


func test_validate_errors() -> void:
	check(not GoalSpec.validate([GoalSpec.make("fly", "easy", 1.0)]).is_empty(), "неизвестный вид")
	var dup := [GoalSpec.make("height", "easy", 1.0), GoalSpec.make("height", "hard", 2.0)]
	check(not GoalSpec.validate(dup).is_empty(), "повтор вида")
	check(not GoalSpec.validate([GoalSpec.make("height", "easy", 0.0)]).is_empty(), "value > 0")
	check(not GoalSpec.validate([GoalSpec.make("distance", "easy", -5.0)]).is_empty(), "value < 0")
	check(not GoalSpec.validate([GoalSpec.make("route", "easy", 0.0)]).is_empty(), "route без task")
	check(not GoalSpec.validate([GoalSpec.make("height", "wow", 100.0)]).is_empty(), "уровень")
	check(not GoalSpec.validate([GoalSpec.make("speed", "easy", 600.0)]).is_empty(), "speed без маршрута")
	var sp := [GoalSpec.make("speed", "easy", 600.0), GoalSpec.make("triangle", "easy", 6000.0)]
	check(GoalSpec.validate(sp).is_empty(), "speed с triangle годен")
	check(not GoalSpec.validate([5]).is_empty(), "не словарь")
