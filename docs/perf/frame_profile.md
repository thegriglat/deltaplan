---
type: "research"
status: "active"
module: "perf"
area: "perf"
updated: "2026-10-15"
summary: "Профиль кадра PF-1: облака 56–93 % GPU; после PF-4…12 GPU medium 14–29 → 5,3–8,2 мс, high 33–83 → 10–12 мс"
related: ["docs/guide/air-model-gpu.md", "docs/guide/game.md", "docs/archive/plan/air-model-baseline.md"]
conclusion: "GPU-кадр на medium/high на 56–93 % — облака (compute-raymarch в CompositorEffect), цена ∝ числу пикселей буфера облаков; без облаков кадр medium 5–6 мс, из них трава 2 мс (36 %), рельеф 1,6 мс. Рывки: AirThermals.build на главном потоке 2,1–2,9 с при каждой смене поля воздуха (старт полёта, конец пересчёта), раз в секунду обновление термиков 24–39 мс и выбор облаков 28–43 мс — 1 %-худших кадров 40–50 мс на любом пресете. Пересчёт поля в полёте: +5…+7 мс к кадру на 8–10 с. ПОСЛЕ волны исправлений (PF-10, тот же стенд): GPU medium 5,3–8,2 мс (было 14–29), high 10–12 (было 33–83), облака medium 1,1–3,6 мс (было 7,8–23,9); трава 0,9 мс (было 2,0); рывки после 2 с — максимум 222 мс (было 2603), пересчёт поля +1,9 мс (было +7,3); 1 %-худших в полёте 21–38 мс (было 41–54) — остаётся CPU: периодические обходы термиков и сцены, а также рывок 3,6 с на первом кадре."
data: "docs/perf/data/pf1_run1.tar.gz («до») и docs/perf/data/pf10_run1.tar.gz («после»): jsonl замеров + report.md; воспроизведение — tools/bench/frame_profile.sh; сравнение — tools/bench/frame_profile_compare.py"
applied_in: "PF-4, PF-5, PF-7, PF-8, PF-9, PF-11, PF-12 (ветка feature/perf); итоговый замер PF-10 — frame_profile/after-fixes.md; tools/bench/probe.gd — VSync снимается для замера"
---
# Профиль кадра и настройки рендера (PF-1)

Замеры — один проход, на машине разработки (RTX 4070 SUPER 12 ГБ, Xeon E5-2666 v3, окно
1918×1036, Vulkan, Godot 4.7.2). У пилота — RX 5600 XT 6 ГБ + Ryzen 5 4500: выводы — в долях
кадра; грубый перенос — в конце. Код игры не менялся: опыты — временные переключения свойств узлов
и окна из инструмента замера.

## Главное

| # | Узкое место | Число (RTX 4070 SUPER) | Доля |
|---|---|---|---|
| 1 | Облака: compute-raymarch всех облаков в `CloudCompositorEffect` (проход «Post Transparent Compositor Effects») | medium 7,9–24,8 мс, high 28–69 мс, low 1,6–2,7 мс | medium 56–82 %, high 88–93 %, low 38–55 % GPU |
| 2 | `AirThermals.build` на главном потоке при каждой смене поля воздуха (`ThermalField._update_air`) | 2,1–2,9 с на вызов; рывки 3,7 с (первый кадр полёта), 2,6–2,7 с (~6 с после старта), 2,1 с (конец пересчёта в полёте) | замирание картинки |
| 3 | Периодические работы главного потока раз в 1 с: `Atmosphere.refresh_now` (термики) и `CloudLayer._select` | 24–39 мс и 28–43 мс | 1 %-худших кадров 40–50 мс на любом пресете (low: кадр 11 мс, 1 % 43–48 мс) |
| 4 | Трава (`GrassField`, ~4–5 млн треугольников) | medium 2,0 мс, high 2,6 мс | 36–42 % кадра без облаков |
| 5 | Пересчёт поля воздуха в полёте (локальный RD делит GPU с отрисовкой) | кадр +7,3 мс на 8–10 с (medium, 13,8 → 21,1 мс), low +5,2 мс | +40…+53 % кадра, раз в 15 игровых минут |

Дальше по убыванию: рельеф 1,6 мс (28 % кадра без облаков), тени солнца 0,74 мс (13 %), деревья
0,42 мс (почти всё — их тени), камни/кусты 0,37 мс, MSAA 2× 0,22 мс, свечение 0,16 мс.
CPU потока отрисовки — 1–2 мс, вызовов отрисовки 300–900: не узкое место.

## Части

- [Что было известно и как мерили](frame_profile/baseline.md) — Профиль кадра PF-1: прежние замеры (NFR-1, AM-00) устарели; стенд, пресеты, опыты и метки движка.
- [Замеры кадра: база, полёт, проходы GPU, опыты, CPU](frame_profile/measurements.md) — Замеры PF-1 на ongudai: проходы GPU, вклад облаков, травы, рельефа, теней; CPU-рывки главного потока раз в 1 с.
- [Вычислительные шейдеры поля воздуха](frame_profile/air-shaders.md) — Поле воздуха на GPU в кадре: задачи и проходы, синхронизации и чтения на CPU, рабочие группы, что можно объединить.
- [Настройки рендера: project.godot, пресеты, ресурсы](frame_profile/render-settings.md) — Проверка настроек рендера Godot: пресеты, шейдер рельефа, почему assets/shaders весит 23 МБ.
- [Предложения по убыванию выигрыша и перенос на машину пилота](frame_profile/proposals.md) — Ранжированные предложения по ускорению кадра и грубая оценка для RX 5600 XT + Ryzen 5 4500 (оценка, не замер).
- [После волны исправлений (PF-4…PF-12)](frame_profile/after-fixes.md) — PF-10: GPU medium 14–29 → 5,3–8,2 мс, high 33–83 → 10–12 мс; что дало каждое исправление, что осталось.

## Воспроизведение

```bash
# всё (≈ 50 мин на 4 прогона по 3 отметки; под замком GPU):
/home/greg/deltaplan/.dpcli/dpcli job --lock gpu start pf1 5400 \
  tools/bench/frame_profile.sh build/perf/run1 "medium low high" "ongudai" --sample=2
tools/bench/frame_profile.sh build/perf/run1 "medium" "altai" --sample=2
# опыты без облаков (фон):
SKIP_FLY=1 TAG_SUFFIX=_noclouds tools/bench/frame_profile.sh build/perf/run1 "medium high" ongudai \
  --sample=2 --keep=nocloudfx --exps=base,scale50,scale75,nomsaa,noshadow,shadow1k,noglow,notrees,notreeshadow,noimpostors,nograss,noscatter,noobjects,nohaze,noterrain,base2
# итог (таблицы markdown):
python3 tools/bench/frame_profile_report.py build/perf/run1 > build/perf/run1/report.md
```

Нужен дисплей `DISPLAY=:0`; профиль Godot — временный (`out_dir/xdg_<пресет>`). Опыты
(`--exps=`): base, scale50/75, nomsaa, noshadow, shadow1k, noglow, nocloudfx, noclouds, notrees,
notreeshadow, noimpostors, nograss, noscatter, noobjects, nohaze, noterrain, cloudres33/25,
cloudit64, cloudlight3, clouddetail0, base2. Данные PF-1 — `docs/perf/data/pf1_run1.tar.gz`, PF-10 (те же команды, `build/perf/run1`) — `docs/perf/data/pf10_run1.tar.gz`
(jsonl по строке на опыт + `report.md`).

Границы замера: одна машина, одно время дня (12:00, ясно, 3 м/с); high и altai — автопилот сел до
отметок 30/60 с, их полётные строки и пересчёт воздуха не годятся (в таблицы не вошли); CPU по
поддеревьям — грубо (полёт идёт дальше, шум ±1–2 мс).
