class_name PilotLegs
extends RefCounted
## Ноги пилота на касании земли (PD-К6 v1, PD-38): вертикальная скорость тела гасится сгибанием
## коленей на конечном ходе, а не за шаг физики. Общая для «Смещения веса» (FlightModel, посадка —
## LandingFlare) и «Маятника» (PendulumGround.legs). Числа — configs/pilot.json → legs.
##
## Сжатие ноги x (м, от касания ступнями) и его скорость xd (м/с, > 0 — тело опускается):
## - стойка (только «Маятник»): нога — жёсткая пружина-демпфер stance_k/stance_c (pendulum.json →
##   ground), сила не больше hold — пока нагрузка меньше hold, колени прямые (стоит, бежит);
## - колени (сгиб y = x − hold/stance_k, 0…travel): F = hold + k·y + c·xd, не больше f_max; k такая,
##   что в конце хода F = f_max (сопротивление нарастает с приседом), c — демпфирование (мышцы
##   гасят энергию, отскока нет: выпрямление — c_ext, медленнее сгибания);
## - ход исчерпан (y > travel) — упор: f_max + k_bottom·(y − travel) + c_bottom·xd (критическое
##   демпфирование) — колени/таз в землю, это и есть жёсткая посадка.
## Вес W = m·g, m — масса, которую ноги держат стоя (пилот + крыло).

var hold: float = 0.0  ## Н: до этой силы колени прямые
var f_max: float = 0.0  ## Н: сила ног в конце хода и предел
var travel: float = 0.3  ## м: ход сгиба коленей
var k: float = 0.0  ## Н/м: нарастание сопротивления с приседом
var c_bend: float = 0.0  ## Н·с/м: демпфирование при сгибании
var c_ext: float = 0.0  ## Н·с/м: при выпрямлении
var k_bottom: float = 0.0  ## Н/м: упор после хода
var c_bottom: float = 0.0  ## Н·с/м
var stance_k: float = 0.0  ## Н/м: прямая нога (0 — абсолютно жёсткая, сгиб с первого касания)
var stance_c: float = 0.0  ## Н·с/м


## cfg — pilot.json → legs; m — масса, которую ноги держат стоя, кг; stance_k, stance_c — прямая нога.
func setup(cfg: Dictionary, m: float, stance_k_: float = 0.0, stance_c_: float = 0.0) -> void:
	var w := m * Units.G
	hold = float(cfg.hold_body_weights) * w
	f_max = float(cfg.force_max_body_weights) * w
	travel = float(cfg.travel_m)
	k = (f_max - hold) / travel
	var crit := 2.0 * sqrt(k * m)
	c_bend = float(cfg.damping_ratio_bend) * crit
	c_ext = float(cfg.damping_ratio_extend) * crit
	k_bottom = float(cfg.bottom_stiffness_n_per_m)
	c_bottom = 2.0 * sqrt(k_bottom * m)
	stance_k = stance_k_
	stance_c = stance_c_


## Сжатие, с которого гнутся колени (прямая нога держит hold), м.
func straight_x() -> float:
	return hold / stance_k if stance_k > 0.0 else 0.0


## Сила ног вверх (≥ 0), Н. x — сжатие от касания, м (≤ 0 — ступни не касаются); xd — его скорость, м/с.
func force(x: float, xd: float) -> float:
	if x <= 0.0:
		return 0.0
	var xh := straight_x()
	if x <= xh:
		return clampf(stance_k * x + stance_c * xd, 0.0, hold)
	var y := x - xh
	if y > travel:
		return maxf(f_max + k_bottom * (y - travel) + c_bottom * maxf(xd, 0.0), 0.0)
	var c := c_bend if xd > 0.0 else c_ext
	return clampf(hold + k * y + c * xd, 0.0, f_max)
