class_name EasterEgg
extends Node3D
## Базовый класс пасхалки (docs/easter_eggs_contracts.md → К3). Пасхалка — ТОЛЬКО картинка
## (и звук): без физики, столкновений, глобального генератора случайных чисел, записи в чужие
## узлы, текстов и подсказок. Все случайные параметры — из rng в begin(). Траектория — функция
## времени мира ctx.t − t0 (скачок времени = пасхалка сразу в нужной точке пути).
## Как добавить: docs/world_objects.md → «Пасхалки».

## Идентификатор (ключ блока configs/easter_eggs.json → eggs.<id>); ставит планировщик.
var id := ""
## Время мира появления, с; ставит планировщик.
var t0 := 0.0
## Срок жизни из блока конфига (lifetime_s), с; 0 — постоянная (до reset()).
var lifetime_s := 0.0


## Условия появления (ночь, погода, геометрия) — дёшево; по умолчанию можно всегда.
## Вызывается на классе: EasterEgg-скрипт.can_appear(ctx, cfg).
static func can_appear(_ctx: EggContext, _cfg: Dictionary) -> bool:
	return true


## Параметры появления — только из rng и только здесь. cfg — свой блок eggs.<id>.
func begin(_ctx: EggContext, _cfg: Dictionary, _rng: RandomNumberGenerator, _t0: float) -> void:
	pass


## Поставить себя в момент ctx.t; false — кончилась (планировщик уберёт).
func update(_ctx: EggContext) -> bool:
	return true
