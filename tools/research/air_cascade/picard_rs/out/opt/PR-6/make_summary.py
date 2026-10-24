#!/usr/bin/env python3
"""PR-6: summary.json from before/, after/, perf_*.txt, harness_after/ (+ PR-4 harness_summary.json as 'before')."""
import csv, json, os, re
here = os.path.dirname(os.path.abspath(__file__))
def perf(p):
    v = {}
    for l in open(p):
        m = re.match(r'\s*([\d\s]+?)\s+(cycles|instructions|L1-dcache-loads|L1-dcache-load-misses|LLC-loads|LLC-load-misses)\b', l)
        if m: v[m[2]] = float(m[1].replace(' ', '').replace(' ', ''))
    return v
def r2(w, c='u3_heat'):
    return json.load(open(f'{here}/{w}/ongudai_d400_{c}_release_t8.json'))
pb, pa = perf(f'{here}/perf_before_u3_heat_t8.txt'), perf(f'{here}/perf_after_u3_heat_t8.txt')
s = {'ms_per_iter': {}, 'phase_ms': {}, 'cases_ms_per_iter': {}}
for w in ('before', 'after'):
    d = r2(w)
    s['phase_ms'][w] = {k: round(v, 3) for k, v in d['time']['phase_ms'].items()}
    s['ms_per_iter'][w] = round(d['time']['ms_per_iter'], 3) if 'ms_per_iter' in d['time'] else None
    s['cases_ms_per_iter'][w] = {c: round(r2(w, c)['time']['ms_per_iter'], 3) for c in ('u3_heat', 'u3_mech', 'u0_heat', 'u6_heat')}
s['l1_misses'] = {'before': pb['L1-dcache-load-misses'], 'after': pa['L1-dcache-load-misses']}
s['l1_ratio'] = pa['L1-dcache-load-misses'] / pb['L1-dcache-load-misses']
s['ipc'] = {'before': pb['instructions'] / pb['cycles'], 'after': pa['instructions'] / pa['cycles']}
s['perf'] = {'before': pb, 'after': pa}
# per-direction counters (harness of PR-4: R2-R1 repeats), before = PR-4 harness_summary.json
R1, R2, N = 50, 450, 460800
base = json.load(open(f'{here}/../../prof/harness_summary.json'))
s['l1_per_cellsweep'] = {}
for m, nm in (('dir0', 'x'), ('dir1', 'y'), ('dir2', 'z')):
    v = {}
    for r in (R1, R2):
        for row in csv.reader(l for l in open(f'{here}/harness_after/{m}_cyc_r{r}.csv') if not l.startswith('#')):
            if len(row) > 3 and row[0].strip().replace('.', '').isdigit():
                v.setdefault(row[2], {})[r] = float(row[0])
    a = {k: (x[R2] - x[R1]) / (R2 - R1) / (3 * N) for k, x in v.items()}
    s['l1_per_cellsweep'][nm] = {
        'before': round(base[m]['L1-dcache-load-misses_per_cellsweep'], 3), 'after': round(a['L1-dcache-load-misses'], 3),
        'cycles_before': round(base[m]['cycles_per_cellsweep'], 1), 'cycles_after': round(a['cycles'], 1)}
json.dump(s, open(f'{here}/summary.json', 'w'), indent=1)
print(json.dumps(s, indent=1))
