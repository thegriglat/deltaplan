#!/usr/bin/env python3
"""PR-4: разность серий R2-R1 из harness_8/*.csv -> harness_summary.json (счётчики на повтор и на клетку·прогонку)."""
import csv, json, re, os
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness_8')
R1, R2 = 50, 450
N = 460800  # клеток, полная прогонка = 1 клетка·прогонка на клетку
SW = {'dir0': 3, 'dir1': 3, 'dir2': 3}  # 3 компоненты, одно направление, обе чётности = 3 полные прогонки
modes = ['dir0', 'dir1', 'dir2', 'bmom', 'mom', 'bheat', 'heat', 'proj', 'kupd']
res = {}
for m in modes:
    d = {}
    for g in ('cyc', 'ins', 'dTL'):
        v = {}
        for r in (R1, R2):
            for row in csv.reader(l for l in open(f'{here}/{m}_{g}_r{r}.csv') if not l.startswith('#')):
                if len(row) > 5 and row[0].strip().replace('.', '').isdigit():
                    v.setdefault(row[2], {})[r] = (float(row[0]), float(row[4].replace(',', '.')))
        for k, x in v.items():
            d[k] = (x[R2][0] - x[R1][0]) / (R2 - R1)
            d[k + '_run%'] = min(x[R1][1], x[R2][1])
    ts = [float(re.search(r'([\d.]+) ms/rep', l)[1]) for l in open(f'{here}/{m}_time.txt') if 'ms/rep' in l]
    d['ms_per_rep'] = sum(ts) / len(ts)
    if m in SW:
        cs = SW[m] * N
        for k in ('L1-dcache-load-misses', 'LLC-load-misses', 'dTLB-load-misses', 'cycles', 'instructions', 'L1-dcache-loads', 'cache-misses', 'LLC-loads'):
            d[k + '_per_cellsweep'] = d[k] / cs
    res[m] = d
json.dump(res, open(os.path.join(here, '..', 'harness_summary.json'), 'w'), indent=1)
for m, d in res.items():
    print(m, {k: round(v, 3) for k, v in d.items() if '_per_cellsweep' in k or k == 'ms_per_rep'})
    print('   run%', {k: v for k, v in d.items() if k.endswith('run%')})
    print('   ', {k: f'{v:.4g}' for k, v in d.items() if not k.endswith('run%') and '_per_' not in k})
