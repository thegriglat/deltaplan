"""Сводные таблицы VM-1 из out/cases.json → out/tables.md, out/summary.json, out/wings_table.csv."""
import json, os, csv, statistics as st
here = os.path.dirname(os.path.abspath(__file__))
C = json.load(open(here + '/out/cases.json'))
def V(w, c): return C[w][c]['V_kmh']
def interp_x(xs, ys, y):  # x при y (ys монотонно растёт с убыванием индекса не гарантируем): линейная по соседним
    pts = sorted(zip(ys, xs))
    for (y0, x0), (y1, x1) in zip(pts, pts[1:]):
        if y0 <= y <= y1 and y1 > y0:
            return x0 + (x1 - x0) * (y - y0) / (y1 - y0)
    return None
groups = {}
rows = []
for w, c in sorted(C.items()):
    cfg = c['cfg']; b = c['base']
    pas = float(cfg['full_pull'])
    r = dict(wing=w, group=cfg['group'], trim_pass=cfg['trim'], vmax_pass=pas, vmax_model=b['V_kmh'], ratio=b['V_kmh'] / pas,
             deficit=pas - b['V_kmh'], trim_model=b['trim_V_kmh'], kn=b['kn'], cg_minus_hang_cm=cfg['cg_minus_hang_m'] * 100,
             stall_frac=b['stall'], p2p=b['V_p2p'], finite=b['finite'], phi_deg=b['phi_deg'], bar_x=b['bar_x'], n=b['n'])
    r['kmh_per_cm_full'] = (V(w, 'hang+3') - V(w, 'hang-3')) / 6.0
    r['kmh_per_cm_trim'] = (c['hang+3']['trim_V_kmh'] - c['hang-3']['trim_V_kmh']) / 6.0
    g = c['cg25']
    ok = not g.get('failed')
    r.update(cg25_shift_cm=g.get('hang_cm'), cg25_vmax=g['V_kmh'] if ok else None, cg25_kn=g['kn'] if ok else None, cg25_dcm0=g['dcm0'] if ok else None,
             cg25_trim=g['trim_V_kmh'] if ok else None, dcm0_base=b['dcm0'])
    # retrim-кривая: Vmax и Kn по сдвигу подвески
    sh = [s_ for s_ in [4, 2, 0, -2, -4, -6, -8, -10, -12, -16] if not c['retrim%+d' % s_].get('failed') and c['retrim%+d' % s_]['kn'] > 0.0 and c['retrim%+d' % s_]['finite']]
    vs = [c['retrim%+d' % s_]['V_kmh'] for s_ in sh]; kns = [c['retrim%+d' % s_]['kn'] for s_ in sh]
    r['retrim_kmh_per_cm'] = (vs[sh.index(4)] - vs[sh.index(-4)]) / 8.0 if (4 in sh and -4 in sh) else None
    r['retrim_dkn_per_cm'] = (kns[sh.index(4)] - kns[sh.index(-4)]) / 8.0 if (4 in sh and -4 in sh) else None
    r['kn_min_ok'] = min(kns); r['vmax_at_kn_min'] = vs[kns.index(min(kns))]
    # сдвиг подвески назад, при котором Vmax = паспорт (retrim); None — не достигнут в пределах −16 см
    r['shift_for_pass_cm'] = interp_x(sh, vs, pas)
    r['kn_for_pass'] = interp_x(kns, vs, pas)
    r['vmax_at_kn0'] = None
    r['vmax_retrim_m16'] = vs[-1]; r['kn_retrim_m16'] = kns[-1]
    r['k'] = (b['V_kmh'] ** 2 / b['trim_V_kmh'] ** 2 - 1) * b['kn']
    r['kn_need'] = r['k'] / ((pas / b['trim_V_kmh']) ** 2 - 1)
    if 0 in sh and any(x < 0 for x in sh):
        s1 = min(sh); slope = (kns[sh.index(0)] - kns[sh.index(s1)]) / (-s1)  # падение Kn на см назад
        r['dkn_per_cm_back'] = slope
        r['back_cm_need'] = (b['kn'] - r['kn_need']) / slope
        r['hang_vs_cg_at_need_cm'] = r['cg_minus_hang_cm'] - r['back_cm_need']
    else:
        r['dkn_per_cm_back'] = r['back_cm_need'] = r['hang_vs_cg_at_need_cm'] = None
    if 'pullcons' in c and 'V_kmh' in c['pullcons']:
        r['v_pullcons'] = c['pullcons']['V_kmh']; r['pullcons_m'] = c['pullcons']['pull_m']; r['bar_depth_m'] = c['pullcons']['bar_depth_m']
    else:
        r['v_pullcons'] = r['pullcons_m'] = r['bar_depth_m'] = None
    r['kn_cg25_lin'] = b['kn'] - r['dkn_per_cm_back'] * (r['cg_minus_hang_cm'] - 2.5) if r['dkn_per_cm_back'] else None
    r['vmax_cg25_pred'] = (b['trim_V_kmh'] * (1 + r['k'] / r['kn_cg25_lin']) ** 0.5) if r['kn_cg25_lin'] and r['kn_cg25_lin'] > 0.005 else None
    f = c['fmax']; r['vmax_fmax_free'] = f['V_kmh']; r['d_fmax'] = f['V_kmh'] - b['V_kmh']
    r['d_slope_p10'] = c['slope1.1']['V_kmh'] - b['V_kmh']; r['d_slope_m10'] = c['slope0.9']['V_kmh'] - b['V_kmh']
    r['d_cda_half'] = c['cda0.5']['V_kmh'] - b['V_kmh']; r['d_cda_x2'] = c['cda2.0']['V_kmh'] - b['V_kmh']
    r['d_wash_half'] = c['wash0.5']['V_kmh'] - b['V_kmh']; r['trim_wash_half'] = c['wash0.5']['trim_V_kmh'] - b['trim_V_kmh']; r['d_dcm0_half'] = c['dcm0x0.5']['V_kmh'] - b['V_kmh']
    r['d_vgproxy'] = c['wash0.5_dcm0x0.5']['V_kmh'] - b['V_kmh']
    r['trim_vgproxy'] = c['wash0.5_dcm0x0.5']['trim_V_kmh'] - b['trim_V_kmh']
    pm = [0.45, 0.6, 0.8, 1.0, 1.2]
    okp = [(p, (b if p == 0.45 else c['pull%.2f' % p])) for p in pm]
    okp = [(p, x) for p, x in okp if 'V_kmh' in x and x['finite'] and x['stall'] < 0.05]
    pm = [p for p, _ in okp]; pv = [x['V_kmh'] for _, x in okp]
    r['pull_for_pass_m'] = interp_x(pm, pv, pas)
    r['pull_max_ok_m'] = max(pm); r['v_at_pull_max_ok'] = pv[-1]
    r['pull_phi_for_pass_deg'] = None
    
    rows.append(r)
    groups.setdefault(cfg['group'], []).append(r)
with open(here + '/out/wings_table.csv', 'w', newline='') as fh:
    w_ = csv.DictWriter(fh, fieldnames=list(rows[0])); w_.writeheader(); w_.writerows(rows)
def mean(xs): xs = [x for x in xs if x is not None]; return sum(xs) / len(xs) if xs else None
def agg(rs, k): return mean([r[k] for r in rs])
keys = ['trim_pass', 'vmax_pass', 'vmax_model', 'deficit', 'ratio', 'kn', 'kmh_per_cm_full', 'kmh_per_cm_trim', 'cg25_vmax', 'cg25_kn',
        'retrim_kmh_per_cm', 'kn_for_pass', 'shift_for_pass_cm', 'd_fmax', 'd_slope_p10', 'd_slope_m10', 'd_cda_half', 'd_cda_x2', 'd_vgproxy',
        'trim_vgproxy', 'kn_cg25_lin', 'vmax_cg25_pred', 'k', 'kn_need', 'back_cm_need', 'hang_vs_cg_at_need_cm', 'v_pullcons', 'pullcons_m', 'bar_depth_m', 'kn_min_ok', 'vmax_at_kn_min', 'pull_for_pass_m', 'phi_deg', 'bar_x', 'cg_minus_hang_cm', 'vmax_retrim_m16', 'kn_retrim_m16']
summ = {'all': {k: agg(rows, k) for k in keys}, 'n': len(rows)}
for g, rs in groups.items(): summ[g] = dict({k: agg(rs, k) for k in keys}, n=len(rs))
summ['n_cg25_kn_le0'] = sum(1 for r in rows if r['kn_cg25_lin'] is None or r['kn_cg25_lin'] <= 0.005)
summ['n_cg25_retrim_ok'] = sum(1 for r in rows if r['cg25_kn'] is not None and r['cg25_kn'] > 0)
summ['n_kn_for_pass_none'] = sum(1 for r in rows if r['kn_for_pass'] is None)
summ['n_pull_for_pass_none'] = sum(1 for r in rows if r['pull_for_pass_m'] is None)
summ['n_stall_or_nonfinite'] = sum(1 for r in rows if (not r['finite']) or r['stall_frac'] > 0.05)
json.dump(summ, open(here + '/out/summary.json', 'w'), ensure_ascii=False, indent=1)
f = lambda x, p=1: '—' if x is None else ('%.*f' % (p, x)).replace('.', ',')
L = ['| класс | n | трим | Vmax пасп. | Vmax модель | разрыв | k | Kn | Kn для пасп. | подвеска назад, см | подвеска к модельному ЦМ при этом, см | ход для пасп., м |', '|' + '---|' * 12]
for g in ['soviet', 'trainer', 'kingpost', 'topless', 'all']:
    rs = rows if g == 'all' else groups.get(g, [])
    if not rs: continue
    L.append('| %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (g, len(rs), f(agg(rs, 'trim_pass')), f(agg(rs, 'vmax_pass')),
        f(agg(rs, 'vmax_model')), f(agg(rs, 'deficit')), f(agg(rs, 'k'), 3), f(agg(rs, 'kn'), 3), f(agg(rs, 'kn_need'), 3),
        f(agg(rs, 'back_cm_need')), f(agg(rs, 'hang_vs_cg_at_need_cm')), f(agg(rs, 'pull_for_pass_m'), 2)))
open(here + '/out/tables.md', 'w').write('\n'.join(L) + '\n')
print('\n'.join(L)); print(json.dumps({k: v for k, v in summ.items() if k.startswith('n_')}))

# --- таблица «Точка подвески» по 48 крыльям (для документа) ---
root = os.path.join(here, '../../..')
T = ['| крыло | кл. | подвеска от носа, м | ЦМ − подвеска, см | Vmax модель | Vmax пасп. | км/ч на см (полный / трим) | Kn | Kn для пасп. | подвеска назад для пасп., см | ЦМ + 2,5 см: Kn, Vmax |', '|' + '---|' * 11]
cls = {'soviet': 'с', 'trainer': 'у', 'kingpost': 'м', 'topless': 'б'}
for r in rows:
    hang = json.load(open('%s/configs/wings/%s.json' % (root, r['wing'])))['pendulum']['hang_from_nose_m']
    if r['cg25_kn'] is not None and r['cg25_kn'] > 0:
        cg = '%s, %s' % (f(r['cg25_kn'], 3), f(r['cg25_vmax']))
    elif r['kn_cg25_lin'] is not None and r['kn_cg25_lin'] > 0.005:
        cg = '%s*, %s*' % (f(r['kn_cg25_lin'], 3), f(r['vmax_cg25_pred']))
    else:
        cg = 'Kn ≤ 0*'
    T.append('| %s | %s | %s | %s | %s | %s | %s / %s | %s | %s | %s | %s |' % (r['wing'], cls[r['group']], f(hang, 3), f(r['cg_minus_hang_cm']),
        f(r['vmax_model']), f(r['vmax_pass']), f(r['kmh_per_cm_full'], 2), f(r['kmh_per_cm_trim'], 2), f(r['kn'], 3), f(r['kn_need'], 3), f(r['back_cm_need']), cg))
open(here + '/out/wings_table.md', 'w').write('\n'.join(T) + '\n')
