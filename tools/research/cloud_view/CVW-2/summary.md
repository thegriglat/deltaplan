---
type: research
status: active
module: cloud-view
summary: CVW-2 вывод — мгла CloudWhiteout включает туман окружения: скачок неба и переключение дымки облаков в cloud_layer
updated: 2026-11-05
---
# CVW-2: вывод
Цвет облаков и неба меняется на основании слоя облаков, потому что `CloudWhiteout.apply` включает Godot-туман (fog_density > 0 при amount ≈ 0,005): небо получает ступеньку
(+0,14 по G), а `cloud_layer._update_light` при `env.fog_enabled` переключает дымку облаков с 4e-05 на `env.fog_density` — облака синеют (R 0,40 → 0,30). Мгла запускается грубым полем
`cloud_density_at` (cover × профиль), а не видимой формой облака. Подробности и три варианта правки — `README.md`.
