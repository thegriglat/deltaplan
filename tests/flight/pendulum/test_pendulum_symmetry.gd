extends TestCase
## PMD-5: в штиль ответ «Маятника» на ввод по крену симметричен — прямой ввод в PendulumModel,
## мышь и клавиатура через настоящий InputController. За 6 с |крен(+r) + крен(−r)| ≤ 10 % от
## |крен(+r)|, без ввода |крен| ≤ 2°. Однородный ветер по курсу и поперёк — как штиль, боковой —
## зеркальная пара (в однородном ветре крыло летит в воздухе так же: инвариантность Галилея).
## Асимметрия test_bar_mouse_in_air_pendulum до PMD-5 — порывы поля воздуха на месте старта
## (ветер ~4 м/с, вертикаль до ±1,7 м/с, свой на каждом перезапуске), не ввод и не модель.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DUR := 6.0
const TOL_REL := 0.10
const NEUTRAL_DEG := 2.0


## Полёт DUR с ввода src ("direct", "mouse", "key") величины r; wind — однородный ветер (мир игры).
## → [крен через DUR, °; скорость крена, °/с].
func _fly(w: String, src: String, r: float, wind := Vector3.ZERO) -> Array:
	var m := S.make(w)
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0, 0.0, wind)
	var air := Callable()
	if wind != Vector3.ZERO:
		air = func(_p: Vector3) -> Vector3: return wind
	var ic: InputController = null
	var root := (Engine.get_main_loop() as SceneTree).root
	if src != "direct":
		ic = InputController.new()
		root.get_child(root.get_child_count() - 1).add_child(ic)  # корень занят _ready раннера
		ic.roll_mode = "pendulum"
		ic.roll_input = "body"
		ic.on_ground = false
		ic.set_mouse_captured(true)
		if src == "mouse" and r != 0.0:
			# смещение мыши на r хода: полный ход — полвысоты окна / чувствительность
			var sz := root.get_visible_rect().size
			var sens := float(Config.value("controls", "mouse.bar_sensitivity", 1.0))
			var ev := InputEventMouseMotion.new()
			ev.relative = Vector2(r * sz.y * 0.5 / sens, 0.0)
			ev.position = sz * 0.5
			ev.global_position = ev.position
			root.push_input(ev)
		elif src == "key" and r != 0.0:
			Input.action_press("roll_right" if r > 0.0 else "roll_left", absf(r))
	var inp := S.input(0.0, r)
	for i in int(round(DUR / S.DT)):
		if ic != null:
			inp = ic.update(S.DT)
		m.step(S.DT, inp, air, Callable())
	if ic != null:
		Input.action_release("roll_right")
		Input.action_release("roll_left")
		ic.set_mouse_captured(false)
		ic.free()
	check(S.finite(m), "%s %s %+.1f: без NaN" % [w, src, r])
	return [rad_to_deg(m.bank), rad_to_deg(m.roll_rate)]


func _pair(w: String, src: String, r: float) -> void:
	var p := _fly(w, src, r)
	var n := _fly(w, src, -r)
	var asym := absf(p[0] + n[0])
	print("    %s %s r=%.1f: крен %+.2f° / %+.2f° (ω %+.1f / %+.1f °/с), |сумма| %.2f°" % [
		w, src, r, p[0], n[0], p[1], n[1], asym])
	check(p[0] > 5.0, "%s %s +%.1f: крен вправо: %.1f°" % [w, src, r, p[0]])
	check(asym <= TOL_REL * absf(p[0]), "%s %s r=%.1f: |%.1f° + %.1f°| ≤ 10 %%" % [w, src, r, p[0], n[0]])


func test_direct_input_symmetric() -> void:
	for w: String in ["training", "laminar", "sport"]:
		var z := _fly(w, "direct", 0.0)
		check(absf(z[0]) <= NEUTRAL_DEG, "%s: нейтраль %.2f°" % [w, z[0]])
		for r: float in [0.3, 1.0]:
			_pair(w, "direct", r)


func test_mouse_symmetric() -> void:
	var z := _fly("training", "mouse", 0.0)
	check(absf(z[0]) <= NEUTRAL_DEG, "мышь: нейтраль %.2f°" % z[0])
	for r: float in [0.3, 1.0]:
		_pair("training", "mouse", r)


func test_keyboard_symmetric() -> void:
	var z := _fly("training", "key", 0.0)
	check(absf(z[0]) <= NEUTRAL_DEG, "клавиши: нейтраль %.2f°" % z[0])
	for r: float in [0.3, 1.0]:
		_pair("training", "key", r)


## Однородный ветер 4 м/с по курсу и поперёк: ответ тот же, что в штиль; зеркальная пара —
## +r при ветре слева = −(−r при ветре справа).
func test_uniform_wind_mirror() -> void:
	var calm := _fly("training", "direct", 0.3)
	var head := _fly("training", "direct", 0.3, Vector3(0.0, 0.0, 4.0))  # курс север (−Z): в лоб
	var from_left := _fly("training", "direct", 0.3, Vector3(4.0, 0.0, 0.0))  # дует на восток
	var from_right_neg := _fly("training", "direct", -0.3, Vector3(-4.0, 0.0, 0.0))
	print("    ветер 4 м/с, r=0,3: штиль %+.2f°, в лоб %+.2f°, слева %+.2f°, справа (−r) %+.2f°" % [
		calm[0], head[0], from_left[0], from_right_neg[0]])
	var tol: float = TOL_REL * absf(calm[0])
	approx(head[0], calm[0], tol, "ветер в лоб — как штиль")
	approx(from_left[0], calm[0], tol, "ветер слева — как штиль")
	approx(from_left[0], -from_right_neg[0], tol, "зеркальная пара бокового ветра")
