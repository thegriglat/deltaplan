---
type: "research"
status: "active"
module: "start-dog"
updated: "2026-10-17"
summary: "DOG-1: собака Quaternius Shiba Inu (CC0) по DOG-K2 — 8 клипов, замер speed_ms/cycle_s, 4 гавка CC0"
related: ["docs/contracts/start-dog.md", "docs/plan/start-dog.md"]
conclusion: "Shiba Inu из Ultimate Animated Animal Pack годится: есть Gallop/Walk/Idle/Idle_2_HeadLow, скелет с IK ног; trot/bark/lie/sit дописаны ключами. Скорость без проскальзывания при воспроизведении 1,0: галоп 1,68 м/с (цикл 0,567 с), трусца 1,60 (0,40 с), шаг 0,60 (1,07 с) — шаг ног в готовой анимации короткий, передние и задние лапы расходятся на ±30 %."
data: "tools/research/start_dog/"
applied_in: "assets/easter_eggs/start_dog/, configs/easter_eggs.json → eggs.start_dog.anims"
---
# DOG-1: модель собаки, клипы, лай

## Источники и лицензии
| Что | Источник | Лицензия |
|---|---|---|
| модель ShibaInu (+ рассмотрены Husky, Wolf того же пака) | Quaternius, «Ultimate Animated Animal Pack» (July 2021), [quaternius.com/packs/ultimateanimatedanimals.html](https://quaternius.com/packs/ultimateanimatedanimals.html); официальная ссылка — Google Drive пака (в момент работы — «Quota exceeded»), скачано из зеркала пака на GitHub (`francisb1996/brave-chicken-assets`, `quaternius/ultimate_animated_animals_july_2021/`, тот же `License.txt`) | CC0 1.0 (License.txt пака и страница пака) |
| bark_1 | [freesound 630648](https://freesound.org/s/630648/) haulaway, «single bark - small to medium dog» | CC0 1.0 |
| bark_2 | [freesound 535457](https://freesound.org/s/535457/) exe2be, «Single bark of a dog» | CC0 1.0 |
| bark_3 | [freesound 277058](https://freesound.org/s/277058/) kwahmah_02, «Single Dog Bark» | CC0 1.0 |
| bark_4 | [freesound 699822](https://freesound.org/s/699822/) 8bitmyketison, «Dog Bark.wav» | CC0 1.0 |

Звуки взяты из HQ-превью Freesound (mp3 ~128 кбит/с; оригинал требует входа) — для гавка на 0,2 с этого
достаточно. Сырые файлы в репозиторий не кладём (локально в каталоге сессии).

## Кандидаты
| Модель | Источник, лицензия | Треуг. | Клипы | Решение |
|---|---|---|---|---|
| ShibaInu | Quaternius UAAP, CC0 | 1950 | Attack, Death, Eating, Gallop, Gallop_Jump, Idle, Idle_2, Idle_2_HeadLow, Idle_HitReact_L/R, Jump_ToIdle, Walk | **взята**: рыжая — похожа на дворнягу; скелет с IK ног |
| Husky | Quaternius UAAP, CC0 | 1920 | те же | запасная: тот же скелет, тот же скрипт сборки годится (окрас «хаски» узнаваем) |
| Wolf / Fox | Quaternius UAAP, CC0 | 1962 / — | те же | не собака |
| Poly Pizza, Kenney, OpenGameArt, Sketchfab | — | — | — | не смотрели: первый кандидат по порядку подошёл (poly.pizza к тому же не отвечал — таймаут Cloudflare) |

## Что сделано с моделью (`build_dog.py`, геометрия не менялась)
- NLA-дорожки пака сняты (иначе подмешиваются к действию); 6 материалов → атрибут цвета вершин по углам граней
  + один материал; в Godot — внешний `dog_material.tres` (`vertex_color_use_as_albedo`) через `dog.glb.import`
  (импортёр glTF Godot 4.7 цвета вершин в альбедо сам не включает).
- Масштаб 0,226 (холка 2,30 ед. модели → 0,52 м), поворот 180° вокруг Z Blender (морда в −Z Godot), начало —
  посередине между передними и задними лапами. Габариты в покое: 0,24 × 0,70 × 0,94 м (ширина × высота с ушами × длина).
- Клипы: `gallop`←Gallop, `walk`←Walk, `idle`←Idle, `sniff`←Idle_2_HeadLow (переименование);
  `trot` — Walk, кривые каждой ноги сдвинуты по фазе в диагональные пары (LF+RH, RF+LH; касания в Walk: LF 0, RH 9,5,
  RF 16, LH 27 из 32 кадров), цикл сжат до 12 кадров (0,4 с); `bark` — поза Idle + два рывка шеи/головы вверх и
  груди (челюсти в модели нет), пики в 0,25 и 0,70 с цикла 1,2 с; `lie` — Body опущен на 0,88 ед., IK передних
  лап вперёд, задних — под бока, дыхание (Torso/Torso2 ±0,025 рад, 2 с); `sit` — Body повернут на −0,55 рад вокруг
  таза и опущен, задние IK под тазом, дыхание. Все клипы зациклены (`settings/loop_mode` в `.import`).
- 1950 треугольников (бюджет 5000), LOD — `meshes/generate_lods=true`, текстур нет.

## Замер speed_ms / cycle_s
Конец кости стопы (`FF.*`, `FFB.*`) в мире по кадрам (30 к/с), после масштаба. Опора — z ≤ p30(z) + 0,006 ед.
(≈1,4 мм) и стопа движется назад. speed = Σ смещений стоп назад в опоре / Σ времени опоры по 4 лапам —
скорость тела, при которой лапы в опоре в среднем не скользят при воспроизведении 1,0.

| Клип | cycle_s | speed_ms | ПЛ | ПП | ЗЛ | ЗП |
|---|---|---|---|---|---|---|
| gallop | 0,567 | 1,68 | 1,20 | 1,60 | 2,09 | 2,09 |
| trot | 0,400 | 1,60 | 1,17 | 1,28 | 1,98 | 1,93 |
| walk | 1,067 | 0,60 | 0,44 | 0,47 | 0,74 | 0,74 |

(по лапам — м/с; полные числа — `measure.json`). Задние лапы в анимации пака проходят в опоре больший путь, чем
передние, поэтому одна скорость тела даёт скольжение передних/задних ±30 % — свойство готовой анимации.
Ориентиры для собаки ~0,5 м в холке: шаг 1–1,5 м/с, трусца 2–4, галоп 7–12 м/с. Без проскальзывания это
`anim_scale` ≈ 2 для шага и трусцы и ≈ 4–6 для галопа (цикл 0,14–0,1 с, 7–10 шагов в секунду — у живой собаки
на галопе ~3–4). Галоп пака «семенящий»: путь стопы в опоре 0,24–0,28 м за 0,13–0,2 с.

## Лай (`cut_barks.py`)
ffmpeg → моно 48 кГц; огибающая RMS 5 мс; самый громкий участок выше −32 дБ от пика (разрывы < 40 мс склеены);
8 мс до начала, +20 мс хвоста, затухание 15 мс; пик −3 dBFS; ogg vorbis q5. Итог — `barks.json`:
0,197–0,255 с, тишина по краям ≤ 12 мс, основной тон 505–632 Гц (средняя собака), центроид 0,86–2,9 кГц.

## Воспроизведение
```
# модель (Blender 4.3; ShibaInu.blend — из пака, см. «Источники»):
blender --background <ShibaInu.blend> --python tools/research/start_dog/build_dog.py -- assets/easter_eggs/start_dog [<каталог_превью>]
godot --headless --path . --import          # dog.glb.import уже содержит loop_mode и внешний материал
# лай (mp3-превью Freesound: https://cdn.freesound.org/previews/<id/1000>/<id>_<user>-hq.mp3):
python3 -I tools/research/start_dog/cut_barks.py <каталог_mp3> assets/easter_eggs/start_dog tools/research/start_dog/barks.json
# осмотр исходника: inspect_blend.py, measure_rest.py (профиль высот), foot_tracks.py (траектории стоп)
# кадры клипов в игре:
tools/shots/start_dog_clips.sh            # → /home/greg/deltaplan/build/screenshots/start-dog/DOG-1/<NN>_<клип>.jpg
# тест контракта DOG-K2/K3:
godot --headless --path . res://tests/run_tests.tscn -- --filter=start_dog_assets
```
