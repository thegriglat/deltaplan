extends Node
## Автозагрузка MotionRig (MR-К1 v3 «Кто зовёт»): владеет отправкой движения на платформу. Живёт всё время
## работы игры, тикает и на паузе дерева, после сцены полёта (приоритет выше Game) — один пакет на N тиков физики.
## Game зовёт только attach/detach/step/reset/place.

var output := MotionOutput.new()
## Название места (поле location формата srs).
var place: String:
	get:
		return output.place
	set(v):
		output.place = v

var _game: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 1000
	output.configure()
	Config.reloaded.connect(output.configure)


## Сцена полёта есть (Game: вход в полёт) — удержание позы, когда живых шагов нет.
func attach(game: Node) -> void:
	_game = game
	output.attach()


## Сцены полёта нет (меню, выход, загрузка) — нейтраль. Чужой detach (старая сцена) игнорируется.
func detach(game: Node) -> void:
	if _game != null and game != _game:
		return
	_game = null
	output.detach()


func step(tel: Telemetry, dt: float) -> void:
	output.step(tel, dt)


func reset() -> void:
	output.reset()


## Тик физики; тесты могут звать вручную (set_physics_process(false)).
func advance(dt: float) -> bool:
	return output.tick(dt)


func _physics_process(dt: float) -> void:
	output.tick(dt)


func _exit_tree() -> void:
	output.shutdown()
