#!/usr/bin/env python3
"""PR-4: summary.json = summary_numbers.json (build_summary.py) + hot + findings (выводы по профилю)."""
import json, os
here = os.path.dirname(os.path.abspath(__file__))
s = json.load(open(here + '/summary_numbers.json'))
s['hot'] = [  # функция (ветка avx2_fma — горячая, база не вызывалась), доля циклов %, t8 / t18; perf record -F 499
    {'fn': 'lines::solve_line_avx2_fma_version (прогонка Томаса, ядра импульса, тепла, сглаживание V-цикла)', 't8': 74.46, 't18': 67.61, 'l1d_miss_share_t8': 92.0},
    {'fn': 'kernels::build_mom_chunk_avx2_fma_version', 't8': 5.83, 't18': 6.70, 'l1d_miss_share_t8': 1.85},
    {'fn': 'kernels::build_heat_chunk_avx2_fma_version', 't8': 3.50, 't18': 4.03, 'l1d_miss_share_t8': 1.18},
    {'fn': 'kernels::kloc_chunk_avx2_fma_version', 't8': 3.05, 't18': 2.83, 'l1d_miss_share_t8': 0.42},
    {'fn': 'rayon bridge_producer_consumer::helper (все варианты, сумма)', 't8': 4.1, 't18': 3.3, 'l1d_miss_share_t8': 1.3},
    {'fn': 'lines::resid_chunk_avx2_fma_version', 't8': 1.24, 't18': 1.26, 'l1d_miss_share_t8': 0.66},
    {'fn': 'mg::prolong_chunk_avx2_fma_version', 't8': 1.07, 't18': 0.88, 'l1d_miss_share_t8': 0.11},
    {'fn': 'solver::Picard::project (последовательный код: pfull.fill, halo_index, apply_phi)', 't8': 0.88, 't18': 0.48, 'l1d_miss_share_t8': 0.29},
    {'fn': 'util::det_sum closure (редукция в project)', 't8': 0.65, 't18': 0.58, 'l1d_miss_share_t8': None},
    {'fn': 'rayon_core WorkerThread take_local_job / crossbeam steal / wait_until_cold (планировщик)', 't8': 1.44, 't18': 3.6, 'l1d_miss_share_t8': 0.7},
    {'fn': 'ядро Linux (sysret, syscall, sched)', 't8': 2.07, 't18': 5.99, 'l1d_miss_share_t8': None},
    {'fn': 'mg::restrict_chunk_avx2_fma_version', 't8': 0.37, 't18': 0.46, 'l1d_miss_share_t8': 0.14}]
s['hot_note'] = ('Доли — из report_u3_heat_t{8,18}.txt (self, cycles, -F 499); строки rayon/ядро — сумма по символам. Горячая ветка multiversion — '
                 'avx2_fma (isa_branch=x86_64+avx2+fma), базовой ветки в отчёте нет. Имена rust v0 perf не демангл-ит: имена в отчёте mangled.')
s['sweep_time_split_t8'] = {'x_pct': 18.6, 'y_pct': 47.2, 'z_pct': 34.2, 'note': 'доли времени 3-компонентной прогонки (harness, мс): 3.19 / 8.09 / 5.85'}
s['sequential_t8'] = {'project_self_cpu_s': 1.34, 'ms_per_iter': 7.0, 'wall_pct': 6.6,
                      'idle_thread_time_pct_t8': 6.5, 'idle_thread_time_pct_t18': 15.1,
                      'note': 'Picard::project (self) выполняется одним потоком: CPU-секунды = стена. Совпадает с долей простоя пула на 8 потоках (process_cpu 152,4 с против 8×20,39 с).'}
s['divide'] = {'vdivps_per_cell': 1, 'share_of_solve_line_samples_pct': 8, 'recurrence_floor_cycles': '≈18–20 (fma 5 + div 13)',
               'note': 'компилятор слил два деления в один vdivps xmm; выборки на и сразу после vdivps ≈ 8 % solve_line; нижняя граница цепочки зависимостей 18–20 тактов на клетку против 63 (x) … 149 (y) измеренных'}
s['solve_line_annotate_t8_pct'] = {'x-neighbour loads (Shared::get + fma с памятью)': 25.3, 'row loads (rows[idx], RHS)': 18.2, 'stores cps/dps/xs (Shared::set)': 17.1,
                                   'ветвления o==lo||hi, c!=0, границы q': 19.8, 'остальное (счётчики цикла, итератор)': 19.6}
s['l1d_miss_by_line_t8_pct'] = {'util.rs:88 Shared::get': 17.7, 'f32.rs:1981 (fma с операндом из памяти — сосед x)': 17.2, 'take.rs/iterator (строка row)': 13.0 + 2.6,
                                'util.rs:78 Shared::set': 7.7, 'прочее lines.rs': 40}
s['findings'] = [
    {'n': 3, 'status': 'подтверждена', 'gain_pct': '12–25 (потолок 30)', 'number': 'L1-промахов на клетку·прогонку: x 1,09; z 2,95; y 7,81; тактов x 63 / z 106 / y 149; LLC-промахов x 0,11 / y 0,77 / z 0,82',
     'detail': 'y — 47 %, z — 34 %, x — 19 % времени прогонок; 92 % всех L1-промахов программы — в solve_line. Если y и z дойдут до уровня x: −40 % времени solve_line (≈ −30 % итерации — потолок).'},
    {'n': 5, 'status': 'подтверждена', 'gain_pct': '10–20', 'number': 'инструкций на клетку·прогонку 169 (x) … 186 (z); IPC 2,7 в x; ветвлений 56 на клетку·прогонку (минимум ≈ 10); ≈ 20 % выборок solve_line — на проверках o==lo||hi, c!=0, границах',
     'detail': 'направление x без кэш-проблем (1,09 L1-промаха) всё равно 63 такта: упор в число инструкций, а не в память или деление'},
    {'n': 8, 'status': 'подтверждена, больше оценки', 'gain_pct': '4–7', 'number': 'Picard::project (self) 1,34 с CPU = 7,0 мс/итерацию последовательно = 6,6 % стены на 8 потоках (7,4 % на 18); par_iter_mut().enumerate с q % nx в solver.rs:151,165,178 ≈ 1,0 %',
     'detail': 'приоритет 2 пользователя: последовательные циклы вне пула; потолок — почти всё 6,6 %'},
    {'n': 7, 'status': 'частично', 'gain_pct': '2–4', 'number': 'rayon+crossbeam self 6,5 % (8) / 8,5 % (18); простой потоков 6,5 % (8) / 15 % (18); steal 0,48 → 2,2 %',
     'detail': 'вклад грубого уровня отдельно не выделен (код не менялся)'},
    {'n': 4, 'status': 'не измерена отдельно, верхняя оценка', 'gain_pct': '≤ 3', 'number': 'весь планировщик rayon (take_local_job, steal, helper) ≈ 4–6 % циклов; половина задач — пустые по чётности',
     'detail': 'нижней оценки нет без правки кода'},
    {'n': 6, 'status': 'ветка выбрана (avx2_fma), но код скалярный (vmovss, vfnmadd231ss)', 'gain_pct': '1,3–2× после 3 и 5 (перестройка)', 'number': 'IPC 2,05 при 4-кратном запасе по ширине; SIMD поперёк линий возможен только вместе с пачками линий (находка 3)',
     'detail': 'не отдельный круг: следует за 3'},
    {'n': 1, 'status': 'опровергнута как упор', 'gain_pct': '≤ 3', 'number': 'два деления уже слиты в один vdivps; ≈ 8 % выборок solve_line на и после vdivps; цепочка 18–20 тактов против 63–149 измеренных',
     'detail': 'по решению пользователя арифметику не трогаем: исключить'},
    {'n': 2, 'status': 'опровергнута как упор', 'gain_pct': '≤ 5 (возможен минус: больше трафика)', 'number': 'арифметика ≤ 10 % времени прогонки; ядро ограничено загрузками (43 % выборок — x-соседи и строка) и инструкциями; кэш cp/den добавляет чтения',
     'detail': 'исключить'},
    {'n': 9, 'status': 'подтверждена (пренебрежимо)', 'gain_pct': '< 1', 'number': 'det_sum 0,65 % + par_max 0,13 % циклов', 'detail': ''}]
s['new_findings'] = [
    'Внутри solve_line 25 % выборок — загрузки x-соседей, 18 % — строка row[RHS], 17 % — записи cps/dps/xs: память и инструкции, не деление.',
    'Прогонки по y в 2,4 раза дороже по тактам, чем по x, и дают 7,8 L1-промахов на клетку·прогонку: strides 3,1 КБ (y) и 307 КБ (z) между строками по 32 Б; соседние линии (i, i+2) делят кэш-линии в cps/dps/x и обрабатываются разными вызовами — вероятно, ложное разделение и повторные загрузки (гипотеза, не проверена).',
    'Масштабирование 8→18 потоков: IPC 2,05 → 1,18, тактов на клетку·прогонку 117 → 210, L1-промахов 4,98 → 7,01 (физических ядер 10, 20 логических): 18 потоков — это гиперпотоки; выигрыш всего ×1,18 по мс/итерацию.',
    'Поточечные ядра (build_mom 5,8 %, build_heat 3,5 %, kloc 3,1 %, resid 1,2 %, prolong 1,1 %) — ≈ 15 % циклов, IPC 2,9, L1-промахов мало (< 2 % всех).',
    'Таймеры фаз и perf record не искажают время: 101,3 (без perf) / 102,9 (record) / 101,9 мс/итерацию (stat); PR-1 дал 105,05 (−3,6 % к нему: разброс серий, вне ±3 % на 0,6 п.п.).',
    'dTLB-промахи пренебрежимо малы (0,011 на клетку·прогонку), ошибки ветвлений 0,17 %.']
json.dump(s, open(here + '/summary.json', 'w'), indent=1, ensure_ascii=False)
