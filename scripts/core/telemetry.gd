class_name Telemetry
extends RefCounted
## Состояние полёта для приборов, звука и камер. Заполняет планер каждый шаг физики.
## Всё в СИ. Приборы сами решают, что и в каких единицах показать.

var time_s: float = 0.0             ## время с начала полёта
var position: Vector3 = Vector3.ZERO ## мир: X — восток, Y — высота над уровнем моря, −Z — север
var velocity: Vector3 = Vector3.ZERO ## путевая скорость (относительно земли), м/с
var air_velocity: Vector3 = Vector3.ZERO ## скорость относительно воздуха, м/с
var airspeed: float = 0.0           ## воздушная скорость, м/с
var groundspeed: float = 0.0        ## горизонтальная путевая скорость, м/с
var vario: float = 0.0              ## вертикальная скорость (чистая, без фильтра), м/с, + вверх
var altitude_msl: float = 0.0       ## высота над уровнем моря, м
var altitude_agl: float = 0.0       ## высота над землёй, м
var heading_deg: float = 0.0        ## курс (куда смотрит нос), 0 — север, по часовой
var track_deg: float = 0.0          ## путевой угол
var bank_deg: float = 0.0           ## крен, + вправо
var pitch_deg: float = 0.0          ## тангаж, + нос вверх
var on_ground: bool = true
var stalled: bool = false
var glide_ratio: float = 0.0        ## текущее качество по земле (горизонт/снижение), 0 если набор
var basis: Basis = Basis.IDENTITY   ## ориентация крыла для камер и модели
