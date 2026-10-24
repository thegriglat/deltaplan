#!/usr/bin/env python3
"""PR-4: summary.json из stat_*.txt (perf stat), harness_summary.json (harness_table.py) и R2-прогонов в ~/data/air_cascade/picard_rs/prof/."""
import json, os, re
here = os.path.dirname(os.path.abspath(__file__))
D = os.path.expanduser('~/data/air_cascade/picard_rs/prof/')
CELLSWEEPS_IT = 47 * 460800  # README «Где запас»: 47 полных прогонок × 460 800 клеток


def stat(path):
    d = {}
    for l in open(path):
        m = re.match(r'\s*(\d[\d\s]*?)\s{2,}([A-Za-z0-9-]+)', l)
        if m:
            d[m[2]] = float(m[1].replace(' ', '').replace(' ', ''))
    return d


out = {'cell_sweeps_per_iter': CELLSWEEPS_IT, 'ipc': {}, 'l1d_miss_per_cell_sweep': {}, 'llc_miss_per_cell_sweep': {},
       'dtlb_miss_per_cell_sweep': {}, 'cycles_per_cell_sweep': {}, 'instr_per_cell_sweep': {}, 'branches_per_cell_sweep': {},
       'branch_miss_rate': {}, 'l1d_miss_rate': {}, 'ms_per_iter': {}, 'phase_share_pct': {}, 'phase_ms': {}}
for t in (1, 8, 18):
    s = stat(f'{here}/stat_u3_heat_t{t}.txt')
    r = json.load(open(D + f'r2_all_t{t}.json'))
    it = r['iters']
    cs = it * CELLSWEEPS_IT
    k = str(t)
    out['ipc'][k] = round(s['instructions'] / s['cycles'], 2)
    out['l1d_miss_per_cell_sweep'][k] = round(s['L1-dcache-load-misses'] / cs, 2)
    out['llc_miss_per_cell_sweep'][k] = round(s['LLC-load-misses'] / cs, 3)
    out['dtlb_miss_per_cell_sweep'][k] = round(s['dTLB-load-misses'] / cs, 4)
    out['cycles_per_cell_sweep'][k] = round(s['cycles'] / cs, 1)
    out['instr_per_cell_sweep'][k] = round(s['instructions'] / cs, 1)
    out['branches_per_cell_sweep'][k] = round(s['branches'] / cs, 1)
    out['branch_miss_rate'][k] = round(s['branch-misses'] / s['branches'], 5)
    out['l1d_miss_rate'][k] = round(s['L1-dcache-load-misses'] / s['L1-dcache-loads'], 4)
    out['ms_per_iter'][k] = round(r['time']['ms_per_iter'], 1)
    out['iters'] = it
    ph = r['time']['phase_ms']
    tot = sum(ph.values())
    out['phase_ms'][k] = {a: round(b, 2) for a, b in ph.items()}
    out['phase_share_pct'][k] = {a: round(100 * b / tot, 1) for a, b in ph.items()}
# t8: точные группы без мультиплексирования
A, B, C = (stat(f'{here}/stat_u3_heat_t8_{g}.txt') for g in 'ABC')
cs = 191 * CELLSWEEPS_IT
out['t8_exact_groups'] = {
    'ipc': round(A['instructions'] / A['cycles'], 2),
    'l1d_miss_per_cell_sweep': round(B['L1-dcache-load-misses'] / cs, 2),
    'llc_miss_per_cell_sweep': round(B['LLC-load-misses'] / cs, 3),
    'dtlb_miss_per_cell_sweep': round(C['dTLB-load-misses'] / cs, 4),
    'l1d_loads_per_cell_sweep': round(B['L1-dcache-loads'] / cs, 1)}
# фазы без perf и под perf record (R2 v2)
for name, f in (('noperf', 'r2_noperf_t{}.json'), ('record', 'r2_rec_t{}.json')):
    out.setdefault('phase_share_pct_' + name, {})
    for t in (8, 18):
        r = json.load(open(D + f.format(t)))['time']
        tot = sum(r['phase_ms'].values())
        out['phase_share_pct_' + name][str(t)] = {'ms_per_iter': round(r['ms_per_iter'], 1), **{a: round(100 * b / tot, 1) for a, b in r['phase_ms'].items()}}
out['pr1_ms_per_iter_t8'] = json.load(open(here + '/../base/ongudai_d400_u3_heat_release_t8.json'))['time']['ms_per_iter']
h = json.load(open(here + '/harness_summary.json'))
out['by_direction_t8'] = {n: {'ms_per_3comp_sweep': round(h[m]['ms_per_rep'], 2),
                              'cycles_per_cell_sweep': round(h[m]['cycles_per_cellsweep'], 1),
                              'instr_per_cell_sweep': round(h[m]['instructions_per_cellsweep'], 1),
                              'l1d_miss_per_cell_sweep': round(h[m]['L1-dcache-load-misses_per_cellsweep'], 2),
                              'llc_miss_per_cell_sweep': round(h[m]['LLC-load-misses_per_cellsweep'], 2),
                              'dtlb_miss_per_cell_sweep': round(h[m]['dTLB-load-misses_per_cellsweep'], 4)}
                          for n, m in (('x', 'dir0'), ('y', 'dir1'), ('z', 'dir2'))}
out['by_phase_t8_harness'] = {m: {'ms': round(h[m]['ms_per_rep'], 1), 'instr_M': round(h[m]['instructions'] / 1e6), 'l1d_miss_M': round(h[m]['L1-dcache-load-misses'] / 1e6, 2),
                                  'llc_miss_M': round(h[m]['LLC-load-misses'] / 1e6, 2)} for m in ('bmom', 'mom', 'bheat', 'heat', 'proj', 'kupd')}
json.dump(out, open(here + "/summary_numbers.json", "w"), indent=1, ensure_ascii=False)
print(json.dumps(out, indent=1, ensure_ascii=False))
