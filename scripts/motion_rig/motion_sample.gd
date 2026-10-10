class_name MotionSample
extends RefCounted
## Величины движения пилота за интервал (MR-К1). Без фильтров и масштабов.

## Удельная сила f = a − g в связанной системе, м/с²: вперёд, вправо, вверх (горизонтальный полёт: heave ≈ +G).
var surge: float = 0.0
var sway: float = 0.0
var heave: float = 0.0
## Ориентация, град: крен (правое крыло вниз > 0), тангаж (нос вверх > 0), курс [0, 360), 0 — север.
var roll: float = 0.0
var pitch: float = 0.0
var yaw: float = 0.0
## Угловые скорости, град/с, в связанной системе: правое крыло вниз / нос вверх / нос вправо > 0.
var roll_rate: float = 0.0
var pitch_rate: float = 0.0
var yaw_rate: float = 0.0
## Воздушная скорость, м/с; скольжение вправо (проекция воздушной скорости на правую ось), м/с.
var airspeed: float = 0.0
var air_lateral: float = 0.0
## false — нет прошлого состояния (после reset()): производные нулевые.
var valid: bool = false
## Время полёта с reset(), с; на земле ли (для формата generic).
var t: float = 0.0
var on_ground: bool = false
