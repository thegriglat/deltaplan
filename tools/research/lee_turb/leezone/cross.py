"""Перекрёстная таблица: поле (срезанные клетки / прежнее) × точка (выбрана в этом поле / в другом): σ_lee, σ_wind, w_lee, w_wind из сетки (шаг 20 м × 7 высот agl)."""
import csv, json, math, collections, statistics as st
LEE_AGL = [10.0, 20.0, 35.0, 50.0, 65.0, 80.0, 100.0]
def grid(suf):
    g = collections.defaultdict(dict)
    for r in csv.DictReader(open(f'out/grid{suf}.csv')):
        g[(r['start'], float(r['d_m']), float(r['agl']))][r['dir']] = (float(r['sigma']), float(r['vy']))
    return g
def cells(suf):
    sp = json.load(open(f'out/scan_points{suf}.json'))['starts']
    out = {}
    for k, s in sp.items():
        h = math.radians(s['heading']); ax, az = math.sin(h), -math.cos(h)
        d = (s['p'][0] - s['site'][0]) * ax + (s['p'][2] - s['site'][2]) * az
        agl = s['p'][1] - s['ground']
        out[k] = (round(d / 20) * 20.0, min(LEE_AGL, key=lambda a: abs(a - agl)), d, agl)
    return out
G = {'new': grid(''), 'old': grid('_old')}
C = {'new': cells(''), 'old': cells('_old')}
rows = []
for s in sorted(C['new']):
    r = {'start': s}
    for fld in ('new', 'old'):
        for pt in ('new', 'old'):
            d, a = C[pt][s][:2]
            v = G[fld][(s, d, a)]
            r[f'{fld}_field_{pt}_pt_sl'] = v['lee'][0]; r[f'{fld}_field_{pt}_pt_sw'] = v['wind'][0]
            r[f'{fld}_field_{pt}_pt_wl'] = v['lee'][1]; r[f'{fld}_field_{pt}_pt_ww'] = v['wind'][1]
    r['pt_new'] = f"d={C['new'][s][2]:.0f} agl={C['new'][s][3]:.0f}"; r['pt_old'] = f"d={C['old'][s][2]:.0f} agl={C['old'][s][3]:.0f}"
    rows.append(r)
with open('out/cross.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
print('start  | new field,new pt | new field,old pt | old field,old pt | old field,new pt  (sl/sw ratio)')
for r in rows:
    def f(a, b): return f"{r[f'{a}_field_{b}_pt_sl']:.2f}/{r[f'{a}_field_{b}_pt_sw']:.2f}={r[f'{a}_field_{b}_pt_sl']/r[f'{a}_field_{b}_pt_sw']:.2f}"
    print(f"{r['start']:28s} {f('new','new')} | {f('new','old')} | {f('old','old')} | {f('old','new')}   {r['pt_new']} / {r['pt_old']}")
import statistics
for a, b in (('new','new'),('new','old'),('old','old'),('old','new')):
    print(a,'field',b,'pt: mean ratio',round(statistics.mean(r[f'{a}_field_{b}_pt_sl']/r[f'{a}_field_{b}_pt_sw'] for r in rows),2),'n(lee>wind)',sum(r[f'{a}_field_{b}_pt_sl']>r[f'{a}_field_{b}_pt_sw'] for r in rows))
