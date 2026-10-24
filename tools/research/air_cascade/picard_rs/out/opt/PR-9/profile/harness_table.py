#!/usr/bin/env python3
"""PR-9: R2-R1 series difference from harness_<tag>/*.csv -> harness_summary_<tag>.json (counters per repeat and per cell-sweep)."""
import csv, json, re, os, sys
tag = sys.argv[1] if len(sys.argv) > 1 else 'before'
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'harness_{tag}')
R1, R2 = 20, 120
N = 460800  # cells; one full sweep = one cell-sweep per cell
SW = {'dir0': 3, 'dir1': 3, 'dir2': 3}  # 3 components, one direction, both colours = 3 full sweeps
modes = [m for m in ['dir0', 'dir1', 'dir2', 'bmom', 'mom', 'bheat', 'heat', 'proj', 'kupd'] if os.path.exists(f'{here}/{m}_cyc_r{R1}.csv')]
res = {}
for m in modes:
    d = {}
    for g in ('cyc', 'ins', 'dTL'):
        v = {}
        for r in (R1, R2):
            for row in csv.reader(l for l in open(f'{here}/{m}_{g}_r{r}.csv') if not l.startswith('#')):
                if len(row) > 3 and row[0].strip().replace('.', '').isdigit():
                    v.setdefault(row[2], {})[r] = float(row[0])
        for k, x in v.items():
            d[k] = (x[R2] - x[R1]) / (R2 - R1)
    ts = [float(re.search(r'([\d.]+) ms/rep', l)[1]) for l in open(f'{here}/{m}_time.txt') if 'ms/rep' in l]
    d['ms_per_rep'] = sum(ts) / len(ts)
    if m in SW:
        cs = SW[m] * N
        for k in ('L1-dcache-load-misses', 'LLC-load-misses', 'cycles', 'instructions', 'L1-dcache-loads'):
            d[k + '_per_cellsweep'] = d[k] / cs
    res[m] = d
json.dump(res, open(os.path.join(here, '..', f'harness_summary_{tag}.json'), 'w'), indent=1)
for m, d in res.items():
    print(m, {k.replace('_per_cellsweep', '/cs'): round(v, 3) for k, v in d.items() if '_per_cellsweep' in k or k == 'ms_per_rep'})
