---
type: "research"
status: "active"
module: "trike-fix"
area: "flight"
updated: "2026-11-02"
summary: "TKF-9: вывод - знак z у ЦМ тележки, упор -10,87 град"
related: ["docs/research/trike-fix/strut.md"]
---
# TKF-9 вывод
Причина упора на 72-75 км/ч - знак z в CART_CM_MODEL (ЦМ тележки за подвеской по cart.py, в коде впереди): вид повёрнут на 8,75°. Поправка +0,13 даёт совпадение с TT-8 (-4,65 / -0,13 против -4,68 / 0) и касание подкоса ~55 км/ч. Упор a_stop = -10,87°. Ход «на себя» 0,25 м после поправки входит в тело - нужно решение. Подробно: docs/research/trike-fix/strut.md.
