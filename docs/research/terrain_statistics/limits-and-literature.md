---
type: "research"
status: "closed"
module: "air-synth"
area: "air"
updated: "2026-10-04"
summary: "Замерены 4 места (Южный Урал, Алтай); Альпы и Кавказ не измерены; первоисточники ряда законов не открывались."
conclusion: "Ограничения: четыре места, спектр одномерный, жадное разложение на формы, Fastscape подобран грубо; закон Хака, Хортон, Hovius, Musgrave и др. — по пересказам; ниже список литературы для всей работы."
data: "tools/research/air_synth/terrain_stats/out/ (stats_tables.md, compare_tables.md, decomp.json, fastscape_metrics.json, forms_gen_metrics.json); код — tools/research/air_synth/terrain_stats/README.md"
applied_in: "в игре напрямую нет: вход генератора корпуса air-synth (docs/archive/rejected/air-synth.md §2)"
related: ["docs/research/terrain_statistics.md"]
---
# Что посчитать позже, ограничения замеров и список литературы

Часть исследования [«Статистика горного рельефа для генератора air-synth»](../terrain_statistics.md); нумерация разделов сохранена; номера в квадратных скобках — список литературы в [limits-and-literature.md](limits-and-literature.md).

## 7. Что посчитать на большом наборе реальных DEM позже (без запуска)

Скрипты `tools/research/air_synth/terrain_stats/` (`stats.py`, `run_stats.py`) принимают любой DEM (float32 с шагом dx) без правок; нужно написать только загрузчик. Набор: 30–100 квадратов 40 × 40 км из Copernicus GLO-30 или SRTM по типам (холмогорье, Южный Урал, Карпаты/Татры, Альпы, Кавказ, Алтай, Саяны, Тянь-Шань), без озёр и морей; поля 1° в Terrarium z10–z11 качаются бесплатно, но лицензию фиксировать в `ASSETS.md`. Величины: (1) вершины ≥ 10, 30, 50, 100, 200, 300, 500 м на квадрат при 25/100/400 м; (2) CCDF prominence и b; (3) расстояние до родителя, расстояние и глубина ключевой седловины; (4) β по полосам, излом масштаба; (5) уклоны (средний, p90, p99, доля > 20°, > 30°) на 25, 100, 400 м; (6) анизотропия (простирание, вытянутость), асимметрия; (7) Dd при водосборе 0,25; 1; 4 км² и закон Хака; (8) перепад в окнах 1,25–20 км (H); (9) гипсометрический интеграл. Метод — тот же, что в разделе 6.1; сравнение — медиана и 10–90 % квадратов типа против 12–1000 сгенерированных. Критерий «правдоподобно» — попадание медиан в 10–90 % реального типа по пунктам 1, 5, 7 (для решателя ветра главное: перепад, уклоны на 400 м, число и высота вершин, седловины).

## 8. Ограничения
- Данные: четыре места — Южный Урал (два), Алтай (два). Альпы, Кавказ, холмогорье Европы не измерены; разброс типов определён по этим четырём; far (Terrarium) сглажен и на масштабах < 1 км недостоверен; «altai» — смесь гор и равнины (в far 5 квадратов с нулём вершин ≥ 100 м).
- Спектр: одномерные профили, окно 40 км, полоса 10–40 км смещена окном.
- Prominence главной вершины области — нижняя оценка; вершины на краях квадрата получают prominence через соседние квадраты только в far.
- Разложение на формы — жадное, локальный минимум; число форм до 30; нет проверки на соседних квадратах (обобщение).
- Fastscape: параметры подобраны по статистикам (грубо, 12 + 12 сочетаний), равновесие не достигнуто (T = 4 млн лет), размерности U, K не сверены с литературой; на рисунке видно, что поле — «купол», а не пояс хребтов. Литературные числа по методам из разделов 5.1–5.2, 5.5 взяты из аннотаций и описаний, не воспроизводились.
- Hovius (1996), Hack, Horton, Strahler, Musgrave, Mei, Stava — по пересказам и общеизвестным значениям; первоисточники не открывались (платные).

## 9. Литература
1. Huang J., Turcotte D.L. (1989) Fractal mapping of digitized images: application to the topography of Arizona and comparisons with synthetic images. J. Geophys. Res. 94(B6), 7491–7495. doi:10.1029/JB094iB06p07491
2. Mark D.M., Aronson P.B. (1984) Scale-dependent fractal dimensions of topographic surfaces. Math. Geol. 16, 671–683. doi:10.1007/BF01033029
3. Perron J.T., Kirchner J.W., Dietrich W.E. (2008) Spectral signatures of characteristic spatial scales and nonfractal structure in landscapes. J. Geophys. Res. 113, F04003. doi:10.1029/2007JF000866
4. Perron J.T., Kirchner J.W., Dietrich W.E. (2009) Formation of evenly spaced ridges and valleys. Nature 460, 502–505. doi:10.1038/nature08174
5. Perron J.T., Dietrich W.E., Kirchner J.W. (2008) Controls on the spacing of first-order valleys. J. Geophys. Res. 113, F04016. doi:10.1029/2007JF000977
6. Hovius N. (1996) Regular spacing of drainage outlets from linear mountain belts. Basin Res. 8, 29–44 (по пересказам).
7. Burbank D.W. et al. (1996) Bedrock incision, rock uplift and threshold hillslopes in the northwestern Himalayas. Nature 379, 505–510. doi:10.1038/379505a0
8. Montgomery D.R., Brandon M.T. (2002) Topographic controls on erosion rates in tectonically active mountain ranges. Earth Planet. Sci. Lett. 201, 481–489.
9. Roering J.J., Kirchner J.W., Dietrich W.E. (1999) Evidence for nonlinear, diffusive sediment transport on hillslopes and implications for landscape morphology. Water Resour. Res. 35, 853–870. doi:10.1029/1998WR900090
10. Montgomery D.R., Dietrich W.E. (1992) Channel initiation and the problem of landscape scale. Science 255, 826–830. doi:10.1126/science.255.5046.826
11. Imre A.R., Novotný J. (2016) Fractals and the Korcak-law: a history and a correction. Eur. Phys. J. H 41, 69–91. doi:10.1140/epjh/e2016-60039-8
12. Kirmse A., de Ferranti J. (2017) Calculating the prominence and isolation of every mountain in the world. Prog. Phys. Geogr. 41(6), 788–802. doi:10.1177/0309133317738163
13. Kirmse A., страница https://www.andrewkirmse.com/prominence (7,8 млн вершин ≥ 100 футов; список 2023 года — 2 027 005 вершин ≥ 300 футов, по результатам поиска).
14. Argudo O., Galin E., Peytavie A., Paris A., Gain J., Guérin E. (2019) Orometry-based terrain analysis and synthesis. ACM Trans. Graph. 38(6). https://github.com/oargudo/orometry-terrains
15. Rak R., Kwapień J., Oświęcimka P., Zięba P., Drożdż S. (2019) Universal features of mountain ridge networks on Earth. arXiv:1804.03457
16. Maxwell J.C. (1870) On hills and dales. Phil. Mag. 40, 421–427 (Cayley A. 1859, On contour and slope lines).
17. Braun J., Willett S.D. (2013) A very efficient O(n), implicit and parallel method to solve the stream power equation governing fluvial incision and landscape evolution. Geomorphology 180–181, 170–179. doi:10.1016/j.geomorph.2012.10.008
18. Cordonnier G., Braun J., Cani M.-P., Benes B., Galin É., Peytavie A., Guérin É. (2016) Large scale terrain generation from tectonic uplift and fluvial erosion. Comput. Graph. Forum 35(2), 165–175. doi:10.1111/cgf.12820
19. Schott H., Paris A., Fournier L., Guérin E., Galin E. (2023) Large-scale terrain authoring through interactive erosion simulation. ACM Trans. Graph. 42(5).
20. Galin É., Guérin É., Peytavie A., Cordonnier G., Cani M.-P., Benes B., Gain J. (2019) A review of digital terrain modeling. Comput. Graph. Forum 38(2), 553–577. doi:10.1111/cgf.13657
21. Guérin É. et al. (2017) Interactive example-based terrain authoring with conditional generative adversarial networks. ACM Trans. Graph. 36(6), 228.
22. Lochner J., Gain J., Perche S., Peytavie A., Galin E., Guérin E. (2023) Interactive authoring of terrain using diffusion models. Comput. Graph. Forum (Pacific Graphics) 42(7).
23. Hobley D.E.J. et al. (2017) Creative computing with Landlab. Earth Surf. Dynam. 5, 21–46. doi:10.5194/esurf-5-21-2017
24. Zhang W., Montgomery D.R. (1994) Digital elevation model grid size, landscape representation, and hydrologic simulations. Water Resour. Res. 30, 1019–1028. doi:10.1029/93WR03553
25. fastscapelib 0.3.0 (PyPI), https://github.com/fastscape-lsa/fastscapelib
26. Данные: Copernicus DEM GLO-30 (ESA, © DLR/Airbus; условия — meta.json мест); Terrain Tiles/Terrarium (Mapzen/AWS Open Data, https://github.com/tilezen/joerd/blob/master/docs/attribution.md).
27. Tzathas P., Gailleton B., Steer P., Cordonnier G. (2024) Physically-based analytical erosion for fast terrain generation. Comput. Graph. Forum 43(2). doi:10.1111/cgf.15033
28. Hack J.T. (1957) Studies of longitudinal stream profiles in Virginia and Maryland. USGS Prof. Paper 294-B; Horton R.E. (1945) GSA Bull. 56, 275–370; Strahler A.N. (1952) GSA Bull. 63, 1117–1142; Strahler A.N. (1957) Trans. AGU 38, 913–920 (общеизвестные соотношения, не открывались).
