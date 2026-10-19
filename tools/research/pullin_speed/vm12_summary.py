#!/usr/bin/env python3
"""VM-12 (VM-К7): сводка out/vm12/r1 (после правки release_event) и r0 (до) → out/vm12/summary.json
(временный файл + переименование), out/vm12/tables.md. Паспорт Vmax и цензура Vne — out/passport_censoring.csv (VM-1)."""
import csv, glob, json, math, os, statistics as st

here = os.path.dirname(os.path.abspath(__file__))
O = os.path.join(here, 'out', 'vm12')
cens = {r['wing']: r for r in csv.DictReader(open(os.path.join(here, 'out', 'passport_censoring.csv')))}


def load(r):
    C, T = {}, {}
    for f in sorted(glob.glob(f'{O}/r{r}/raw_*.json')):
        C.update(json.load(open(f))['wings'])
    for f in sorted(glob.glob(f'{O}/r{r}/turb_*.json')):
        for w, c in json.load(open(f))['wings'].items():
            T[w] = c['turb']
    return C, T


def p10(xs):
    xs = sorted(xs)
    k = (len(xs) - 1) * 0.1
    lo = math.floor(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def counts(C):
    rows = []
    for w, c in sorted(C.items()):
        tr = c['vm4_trim']['V_kmh']
        rows.append(dict(wing=w, trim=tr, trim_pass=c['vm4_trim']['passport_kmh'], passport=float(cens[w]['vmax']),
                         censored=cens[w].get('at_vne') == 'True', normal=c['normal']['V_kmh'], full=c['full']['V_kmh'],
                         rs=c['release_smooth'], r8=c['release_1p8'], rn=c['release_smooth_normal'],
                         le2=c['normal']['V_kmh'] <= 2.0 * tr))
    return rows


C1, T1 = load(1)
R1 = counts(C1)
unc = [r for r in R1 if not r['censored']]
s = {
    'contract': 'VM-К7 v2', 'task': 'VM-12', 'wings': len(R1),
    'vmax_ratio_median': st.median(r['full'] / r['passport'] for r in unc),
    'vmax_ratio_p10': p10([r['full'] / r['passport'] for r in unc]),
    'trim_dev_max_kmh': max(abs(r['trim'] - r['trim_pass']) for r in R1),
    'tuck_1p8_count': sum(bool(r['r8']['tuck']) for r in R1),
    'tuck_1p8_wings': [r['wing'] for r in R1 if r['r8']['tuck']],
    'tuck_normal_le2_count': sum(bool(r['rn']['tuck']) for r in R1 if r['le2']),
    'tuck_normal_le2_wings': [r['wing'] for r in R1 if r['le2'] and r['rn']['tuck']],
    'normal_le2_wings_n': sum(r['le2'] for r in R1),
    'tuck_normal_count': sum(bool(r['rn']['tuck']) for r in R1),
    'tuck_normal_wings': [r['wing'] for r in R1 if r['rn']['tuck']],
    'tuck_smooth_count': sum(bool(r['rs']['tuck']) for r in R1),
    'release_g_smooth_max': max([r['rs']['g_max'] for r in R1 if not r['rs']['tuck']] or [float('nan')]),
}
s['turb_upsets'] = {w: T1[w]['upsets'] for w in sorted(T1)}
s['turb_upsets_total'] = sum(s['turb_upsets'].values())
s['turb_n_total'] = sum(T1[w]['n'] for w in T1)
if glob.glob(f'{O}/r0/raw_*.json'):
    C0, T0 = load(0)
    R0 = counts(C0)
    s['turb_upsets_base'] = {w: T0[w]['upsets'] for w in sorted(T0)}
    s['turb_upsets_total_base'] = sum(s['turb_upsets_base'].values())
    s['base'] = {'tuck_1p8_count': sum(bool(r['r8']['tuck']) for r in R0),
                 'tuck_normal_count': sum(bool(r['rn']['tuck']) for r in R0),
                 'tuck_normal_le2_count': sum(bool(r['rn']['tuck']) for r in R0 if r['le2']),
                 'tuck_smooth_count': sum(bool(r['rs']['tuck']) for r in R0),
                 'vmax_ratio_median': st.median(r['full'] / r['passport'] for r in R0 if not r['censored'])}
tmp = O + '/summary.json.tmp'
json.dump(s, open(tmp, 'w'), ensure_ascii=False, indent=1)
os.replace(tmp, O + '/summary.json')
f = lambda x, n=1: '—' if x is None else (f'{x:.{n}f}' if isinstance(x, float) else str(x))  # noqa: E731
L = ['# VM-12: порт отпускания по событию (VM-К7), после правки', '',
     '| крыло | трим | normal | full | normal/трим | normal: V0 → Vконец, θmin | smooth(full): V0 → Vконец, θmin | 1,8: V0 → Vконец, θmin |',
     '|' + '---|' * 8]
for r in R1:
    def c(a):
        return f"{f(a['V0_kmh'], 0)} → {f(a['V_end_kmh'], 0)}, {f(a['theta_min_deg'], 0)}°{' **переворот**' if a['tuck'] else ''}"
    L.append(f"| {r['wing']} | {f(r['trim'])} | {f(r['normal'])} | {f(r['full'])} | {r['normal'] / r['trim']:.2f} | {c(r['rn'])} | {c(r['rs'])} | {c(r['r8'])} |")
open(O + '/tables.md', 'w').write('\n'.join(L) + '\n')
print(json.dumps({k: v for k, v in s.items() if not isinstance(v, list)}, ensure_ascii=False))
print('1p8:', s['tuck_1p8_wings'], '\nnormal_le2:', s['tuck_normal_le2_wings'], '\nnormal:', s['tuck_normal_wings'])
