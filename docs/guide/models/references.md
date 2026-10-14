---
type: "guide"
status: "active"
module: "models"
area: "flight"
updated: "2026-10-15"
summary: "Скриншоты моделей, приёмка по фото реальных прототипов, что улучшить, источники референсов."
related: ["docs/guide/models.md"]
---
# Скриншоты, приёмка по фото, источники

`docs/models/screenshots/<модель>/` — `bottom.png`, `front.png`, `side.png`, `iso45.png` (1280×720,
одинаковый светлый фон и свет, Blender Eevee; у крыльев без пилота) и у крыльев `cockpit.png` — из `CockpitCamera`
(крыло + pilot.glb без Helmet + instrument.glb + vario_90s.glb, вертикальный FOV 95°). Есть для всех 48 крыльев (`glider_<id>/`) и для `pilot/`,
`instrument/`, `vario_90s/`, `trees/` (`<вид>.png` — LOD0 | LOD1 | LOD2, `trees_iso45.png` — все виды сверху под 45°).
`control_frame/` — трапеция в игре до/после деталировки (`<крыло>_<вид>_before|after.jpg`: L — взгляд влево на стойку, DS — вниз стоя, DF — вниз в полёте) и крупные планы `frame_*.jpg` из
`tools/shots/frame_shot.tscn` (крыло + пилот на пустой сцене: виды из глаз F, DF, U, L, R, UB и снаружи XA — подвес и узел стоек, XC — угол, XS, XF; запуск — в шапке скрипта).
Проверка в Godot: `scenes/models_preview/models_preview.tscn` (три крыла с пилотом и приборами),
снимок: `xvfb-run -a godot --path . --rendering-method gl_compatibility res://scenes/models_preview/models_preview.tscn -- --view=iso|below|side|cockpit --shot=/путь.png`.

**Для сайта.** `docs/models/screenshots/glider_<id>/iso45.jpg` (все 48 крыльев) — JPEG качество 85, 1280×720, крыло обрезано по содержимому и центрировано с полем ~3,5%, заливка фона. Генерация: `tools/blender/render_wings_site.sh` → рендер PNG через `render_views.py` и преобразование `wings_site_jpg.py`.

## Приёмка: сравнение с фото

Для каждой модели 3 фото реального прототипа (в репозиторий не кладём) → рендер модели в близком
ракурсе → коллаж «фото | модель» (вне репозитория). Вердикт — по чек-листу: силуэт в плане,
стреловидность/размах, кингпост есть/нет, трапеция, пилот, прибор.

**glider_training** — фото: [Falcon 4 снизу](https://commons.wikimedia.org/wiki/File:Wills_Wing_Falcon_4_hang_glider.jpg),
[Falcon 4 снизу 3/4](https://www.willswing.com/hang-gliders/falcon-4/),
[Aeros Target сбоку](https://commons.wikimedia.org/wiki/File:Aeros_target_single_surface_hangglider.jpg).
✔ план (угол носа ~122°, широкая хорда, скруглённые концы), цветная полоса передней кромки, латы
линиями, видимая снизу поперечина, кингпост с верхними тросами, трапеция с колёсами, пилот под крылом.
✘ нет «пузыря» паруса между латами и прозрачности; колёса крупноваты.

**glider_sport** — фото: [Aeros Combat снизу](https://commons.wikimedia.org/wiki/File:Combat-aeros-aile-delta-competition.jpg),
[T3 спереди и сбоку в полёте](https://www.willswing.com/hang-gliders/t3/).
✔ узкий удлинённый план (угол носа 128°, размах 10,4 м), нет кингпоста и верхних тросов, лёгкая «чайка»
(поперечное V −2°) спереди, серая майларовая кромка, обтекатели стоек, спидбар, сдвоенные боковые тросы.
✔ в профиль трапеция — одна наклонная линия (обе стойки совпадают), как на фото T3 сбоку: наклон
≈ 25° вперёд от перпендикуляра к килю (`upright_tilt_deg`). ✘ спереди парус тоньше, чем на широкоугольном фото.

**pilot** — фото: [пилот в коконе сбоку](https://commons.wikimedia.org/wiki/File:Hg_rheinebene_aug2000.jpg),
[T3 крупно](https://www.willswing.com/hang-gliders/t3/),
[вид с киля сзади](https://commons.wikimedia.org/wiki/File:Hang_glider_Pilotenview_oct2005.jpg).
✔ лежит, голова в шлеме чуть позади и выше штанги, руки к штанге, кокон с хвостом, фал к подвесу,
тело человека MakeHuman, кулаки на штанге большими пальцами внутрь.
✘ одежда без складок, руки почти прямые (на фото локти согнуты), кокон уже реального.

**instrument** — фото: [Kobo с XCSoar — экран и с датчиком](https://dukeofted.wordpress.com/2016/06/21/lk8000-and-xcsoar-on-an-unmodified-kobo-mini/),
[смартфон и вариометр в обтекателе на штангу](https://delta-goodies.com/product/altair-hang-gliding-dual-pod-power-ii). ✔ чёрный чехол с большим экраном, кнопка, кронштейн-хомут
на штангу, экран наклонён к лицу (на cockpit.png читаем). ✘ портрет 3:4, а Kobo на фото — альбомный.

**vario_90s** — фото: [Flytec 4005](https://commons.wikimedia.org/wiki/File:Gleitschirmvario.jpg),
[Flytec 3005 SI и VA 2002 со стрелкой](https://naviter.com/brauniger-flytec-naviter/). ✔ «коробочка» со шкалой сверху и блоком круглых кнопок снизу,
хомут на стойку. ✘ у 4005 шкала-столбик ЖК, у нас круглый циферблат (сознательно: обобщённый «старый
стрелочный вариометр», шкала рисуется в SubViewport).

**Деревья** — по 3 фото Wikimedia Commons на вид (часть — Алтай): сосна
[Семей](https://commons.wikimedia.org/wiki/File:Pinus_sylvestris_solitary_tree_in_Semey_Ormany.jpg),
[одиночная](https://commons.wikimedia.org/wiki/File:Pinus-sylvestris-01-fws.jpg),
[Урал](https://commons.wikimedia.org/wiki/File:Pinus_sylvestris_Urals.jpg);
кедр [Чемал](https://commons.wikimedia.org/wiki/File:Chemalsky_District,_Altai_Republic,_Russia_-_panoramio_(23).jpg),
[группа](https://commons.wikimedia.org/wiki/File:Pinus_sibirica_trees_(01).jpg),
[Семинский перевал](https://commons.wikimedia.org/wiki/File:SeminskyPass_013_1582.jpg);
лиственница [Горный Алтай](https://commons.wikimedia.org/wiki/File:%D0%93%D0%BE%D1%80%D0%BD%D1%8B%D0%B9_%D0%90%D0%BB%D1%82%D0%B0%D0%B9_-_panoramio_-_Tanya_Dedyukhina_(12).jpg),
[Юстыд](https://commons.wikimedia.org/wiki/File:Larch_in_the_valley_of_the_river_yustid_02.jpg),
[раскидистая](https://commons.wikimedia.org/wiki/File:%D0%9A%D1%80%D0%B0%D1%81%D0%BD%D0%BE%D1%8F%D1%80%D1%81%D0%BA._%D0%A2%D0%BE%D1%80%D0%B3%D0%B0%D1%88%D0%B8%D0%BD%D1%81%D0%BA%D0%B8%D0%B9_%D1%85%D1%80%D0%B5%D0%B1%D0%B5%D1%82_-_panoramio.jpg);
берёза [Осло](https://commons.wikimedia.org/wiki/File:Silver_Birch_(Betula_pendula)_-_Oslo,_Norway_2020-08-04.jpg),
[одиночная](https://commons.wikimedia.org/wiki/File:Haltern_am_See,_Westruper_Heide,_Solit%C3%A4rbaum_--_2025_--_8748.jpg),
[опушка](https://commons.wikimedia.org/wiki/File:Haltern_am_See,_Westruper_Heide_--_2025_--_8721.jpg);
ель [Эстония](https://commons.wikimedia.org/wiki/File:Kuusk_Keila-Paldiski_rdt_%C3%A4%C3%A4res.jpg),
[Бескиды](https://commons.wikimedia.org/wiki/File:Picea_abies_Beskid_%C5%BBywiecki.JPG),
[ель сибирская](https://commons.wikimedia.org/wiki/File:Picea_obovata_Shekuria_River.jpg).
- `pine` — ✔ высокий голый рыжий ствол, плоская клочковатая крона наверху. ✘ крона симметричнее, чем у старых сосен.
- `cedar` — ✔ густая тёмная широкая крона от ~1/4 высоты, толстый ствол. ✘ нет многовершинности.
- `larch` — ✔ прямой ствол, узкий конус, светлая мягкая хвоя, горизонтальные ветви. ✘ ярусы регулярнее.
- `birch` — ✔ белый ствол с чёрными отметинами и тёмным комлем, овальная светлая крона, свисающие пучки. ✘ крона прозрачнее реальной летней.
- `spruce` — ✔ плотный тёмный узкий конус почти от земли, острая вершина. ✘ нижние ветви не касаются земли.

## Известные упрощения моделей (не сделано)

- Парус: цвета ближе к прототипам (прозрачный серый майлар), пятно солнца сквозь ткань, тень от лат,
  пересчёт нормалей при анимации, частичная тень паруса на пилоте.
- Пилот: поворот головы, складки кокона и одежды, мягкий хвост кокона стоя.
- Приборы: кнопки/надписи текстурой, стекло с бликом.
- Деревья: больше вариаций (2–3 сида на вид), импосторы с 8 ракурсов, ветер в шейдере, осенняя лиственница.

## Источники референсов (в репозиторий не кладутся)

- Wills Wing Falcon 4, Sport 2, T3: https://www.willswing.com/hang-gliders/falcon-4/, …/sport-2/, …/t3/
- Wikimedia Commons: [Falcon 4](https://commons.wikimedia.org/wiki/File:Wills_Wing_Falcon_4_hang_glider.jpg),
  [Aeros Target](https://commons.wikimedia.org/wiki/File:Aeros_target_single_surface_hangglider.jpg),
  [U2C](https://commons.wikimedia.org/wiki/File:Wills_Wing_U2C_160.jpg),
  [Aeros Combat](https://commons.wikimedia.org/wiki/File:Combat-aeros-aile-delta-competition.jpg),
  [T2C](https://commons.wikimedia.org/wiki/File:Wills_Wing_T2C_144.jpg),
  [вид пилота](https://commons.wikimedia.org/wiki/File:Hang_glider,_fly_-_panoramio.jpg),
  [пилоты в коконе](https://commons.wikimedia.org/wiki/File:Hg_rheinebene_aug2000.jpg),
  [ещё](https://commons.wikimedia.org/wiki/File:Hg_Donnersberg_Wald_1993.jpg),
  [зима](https://commons.wikimedia.org/wiki/File:Hg_winter_2006.jpg),
  [с киля](https://commons.wikimedia.org/wiki/File:Hang_glider_Pilotenview_oct2005.jpg)
- Aeros Combat, Moyes Litespeed S4, обтекатели и кронштейны Altair: https://delta-goodies.com/
- Flytec 6030: https://naviter.com/flytec-6030/; XC Tracer: https://www.xctracer.com/en/
- Деревья: Wikimedia Commons (Pinus sylvestris, Pinus sibirica, Larix sibirica, Betula pendula,
  Picea abies / Picea obovata).
Полный список с прямыми ссылками на картинки — в рабочем `refs/SOURCES.txt` агента (76 строк);
при необходимости его можно положить сюда.
