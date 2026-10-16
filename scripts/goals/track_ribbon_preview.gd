extends Node3D
## Превью полосы трека (GL-8): синтетический трек — спираль в термике и планирование — над плоскостью.
## Камера: 1 — в 200 м от трека, 2 — в 30 м, 3 — в 10 км; пробел — по кругу.

const VIEWS := [
	[Vector3(-150.0, 1180.0, 160.0), Vector3(0.0, 1150.0, 0.0)],
	[Vector3(20.0, 1210.0, 75.0), Vector3(0.0, 1200.0, 0.0)],
	[Vector3(-7000.0, 2500.0, 7000.0), Vector3(800.0, 1100.0, 0.0)],
]

var _cam: Camera3D
var _view := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40000.0, 40000.0)
	ground.mesh = plane
	ground.position.y = 1000.0
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.35, 0.5, 0.25)
	ground.material_override = gm
	add_child(ground)
	var ribbon := TrackRibbon.new()
	ribbon.set_track(_synthetic(), func(la: float, lo: float) -> Vector2: return Vector2(lo * 1000.0, -la * 1000.0))
	add_child(ribbon)
	_cam = Camera3D.new()
	_cam.far = 30000.0
	add_child(_cam)
	_apply_view()


## Взлёт у земли, спираль в термике (+2,5 м/с), планирование (−1,2 м/с), участок в сильном снижении.
func _synthetic() -> FlightTrack:
	var t := FlightTrack.new()
	var alt := 1003.0
	var i := 0
	for k in 40:  # у земли — проверка мерцания с рельефом
		t.append(0.0, (-400.0 + k * 10.0) / 1000.0, alt + k * 0.05, float(i))
		i += 1
	var r := 60.0
	for k in 300:
		var a := k * TAU / 25.0
		alt += 2.5
		t.append(-r * sin(a) / 1000.0, r * cos(a) / 1000.0, alt, float(i))
		i += 1
	var x := r
	for k in 300:
		x += 11.0
		alt -= 1.2 if k < 200 else 4.0
		t.append(0.0, x / 1000.0, alt, float(i))
		i += 1
	return t


func _apply_view() -> void:
	var v: Array = VIEWS[_view]
	_cam.position = v[0]
	_cam.look_at(v[1])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match (event as InputEventKey).keycode:
			KEY_1: _view = 0
			KEY_2: _view = 1
			KEY_3: _view = 2
			KEY_SPACE: _view = (_view + 1) % VIEWS.size()
			_: return
		_apply_view()
