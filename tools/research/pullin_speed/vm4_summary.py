#!/usr/bin/env python3
"""VM-4 (VM-К5 v1): сводка замера порта в игре — out/vm4/raw_*.json → out/vm4/cases.json, out/vm4/summary.json
(временный файл + переименование), out/vm4/tables.md. Паспорт Vmax VG 0 и цензура Vne — out/passport_censoring.csv
(VM-1), прототип VM-3 — tools/research/pendulum/out/vm3/summary.json (вариант nl: σ 0,5, добор 0,7 м, без Cmq)."""
import csv, glob, json, math, os, statistics as st

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '../../..')
O = os.path.join(here, 'out', 'vm4')
C = {}
for f in sorted(glob.glob(O + '/raw_*.json')):
    C.update(json.load(open(f))['wings'])
json.dump(C, open(O + '/cases.json', 'w'), ensure_ascii=False, indent=1)
cens = {r['wing']: r for r in csv.DictReader(open(os.path.join(here, 'out', 'passport_censoring.csv')))}
proto = json.load(open(os.path.join(root, 'tools/research/pendulum/out/vm3/summary.json')))['wing_rows']
arms = json.load(open(os.path.join(root, 'configs/pendulum.json')))['arms']


def p10(xs):
    xs = sorted(xs)
    k = (len(xs) - 1) * 0.1
    lo = math.floor(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


rows = []
for w, c in sorted(C.items()):
    pas = float(cens[w]['vmax'])
    censored = cens[w].get('at_vne') == 'True'
    pv = proto.get(w, {}).get('nl', {}).get('full_V_kmh')
    rows.append(dict(wing=w, group=c['cfg']['group'], passport=pas, censored=censored,
                     trim=c['vm4_trim']['V_kmh'], trim_pass=c['vm4_trim']['passport_kmh'],
                     normal=c['normal']['V_kmh'], full=c['full']['V_kmh'], full_std=c['full']['V_std_kmh'],
                     bar=c['full']['bar_force_max_n'], proto_full=pv,
                     rs=c['release_smooth'], r8=c['release_1p8'], rn=c.get('release_smooth_normal')))
unc = [r for r in rows if not r['censored']]
s = {
    'contract': 'VM-К5 v1', 'task': 'VM-4', 'wings': len(rows),
    'vmax_ratio_median': st.median(r['full'] / r['passport'] for r in unc),
    'vmax_ratio_p10': p10([r['full'] / r['passport'] for r in unc]),
    'vmax_ratio_n': len(unc),
    'vmax_ratio_median_normal': st.median(r['normal'] / r['passport'] for r in unc),
    'vmax_full_game_vs_proto_median': st.median(r['full'] / r['proto_full'] for r in rows if r['proto_full']),
    'vmax_std_max_kmh': max(r['full_std'] for r in rows),
    'vmax_std_wing': max(rows, key=lambda r: r['full_std'])['wing'],
    'trim_dev_max_kmh': max(abs(r['trim'] - r['trim_pass']) for r in rows),
    'bar_force_vmax_max_n': round(max(r['bar'] for r in rows), 2),  # Telemetry.bar_force — float32: 300,0001 = предел рук
    'arms_force_max_n': arms['force_max_n'],
    'tuck_smooth_count': sum(bool(r['rs']['tuck']) for r in rows),
    'tuck_1p8_count': sum(bool(r['r8']['tuck']) for r in rows),
    'tuck_smooth_wings': [r['wing'] for r in rows if r['rs']['tuck']],
    'tuck_1p8_wings': [r['wing'] for r in rows if r['r8']['tuck']],
    'release_g_smooth_max': max(r['rs']['g_max'] for r in rows if not r['rs']['tuck']) if any(not r['rs']['tuck'] for r in rows) else float('nan'),
    'release_g_smooth_max_all': max(r['rs']['g_max'] for r in rows),
    'pull_full_m': arms['shift_x_pull_full_m'], 'pull_normal_m': arms['shift_x_pull_m'],
    'pull_full_release_m_s': arms['pull_full_release_m_s'],
    'tuck_smooth_normal_count': sum(bool(r['rn'] and r['rn']['tuck']) for r in rows),  # справочно: без Shift
    'tuck_smooth_normal_wings': [r['wing'] for r in rows if r['rn'] and r['rn']['tuck']],
    'vmax_std_kmh': {r['wing']: r['full_std'] for r in rows if r['wing'] in ('aeros_combat_l', 'moyes_litespeed_s', 'ww_talon')},
}
tmp = O + '/summary.json.tmp'
json.dump(s, open(tmp, 'w'), ensure_ascii=False, indent=1)
os.replace(tmp, O + '/summary.json')
f = lambda x, n=1: '—' if x is None else (f'{x:.{n}f}' if isinstance(x, float) else str(x))  # noqa: E731
L = ['# VM-4: порт в игру (VM-К5)', '',
     '| крыло | класс | трим | паспорт Vmax | цензура Vne | normal | full | СКО full | прототип VM-3 | |F| max, Н | '
     'smooth: V0 → Vконец, θmin, g | 1,8: V0 → Vконец, θmin, g |', '|' + '---|' * 12]
for r in rows:
    a, b = r['rs'], r['r8']
    L.append(f"| {r['wing']} | {r['group']} | {f(r['trim'])} | {f(r['passport'])} | {'да' if r['censored'] else ''} | {f(r['normal'])} | "
             f"{f(r['full'])} | {f(r['full_std'])} | {f(r['proto_full'])} | {f(r['bar'], 0)} | "
             f"{f(a['V0_kmh'], 0)} → {f(a['V_end_kmh'], 0)}, {f(a['theta_min_deg'], 0)}°, {f(a['g_max'])}{' **переворот**' if a['tuck'] else ''} | "
             f"{f(b['V0_kmh'], 0)} → {f(b['V_end_kmh'], 0)}, {f(b['theta_min_deg'], 0)}°, {f(b['g_max'])}{' **переворот**' if b['tuck'] else ''} |")
open(O + '/tables.md', 'w').write('\n'.join(L) + '\n')
print(json.dumps({k: v for k, v in s.items() if not isinstance(v, (list, dict))}, ensure_ascii=False))
print('smooth:', s['tuck_smooth_wings'])
print('1p8:', s['tuck_1p8_wings'])
print('normal smooth:', s['tuck_smooth_normal_count'], s['tuck_smooth_normal_wings'])
