"""Пары Vmax VG 0 / VG 100 из набора паспортов (tools/research/data/wing_passports/wings_merged.json,
карточки DHV Geräteportal https://service.dhv.de/db1/ + страницы производителей). Только чтение."""
import json, os, statistics as st
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, '../data/wing_passports/wings_merged.json')
d = json.load(open(src))
rows = []
for r in d:
    f = r['fields']
    a, b = f.get('vmax_vg0_kmh'), f.get('vmax_vg100_kmh')
    if not (a and b):
        continue
    vne = f.get('vne_kmh', {}).get('value')
    q0 = a['sources'][0]['quote']; q1 = b['sources'][0]['quote']
    cens = ('>' in q0) or ('>' in q1) or (b['value'] >= (vne or 999) and a['value'] >= (vne or 999))
    rows.append(dict(manufacturer=r['manufacturer'], family=r['family'], size=r.get('size'), vmax_vg0=a['value'],
                     vmax_vg100=b['value'], vne=vne, delta=b['value'] - a['value'], quote0=q0, quote100=q1,
                     censored=bool(('>' in q1) or ('>' in q0)), at_vne_cap=bool(vne and b['value'] >= vne),
                     kinds='/'.join(r['source_kinds'])))
import csv
with open(os.path.join(here, 'out/vg_pairs.csv'), 'w', newline='') as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
dl = [x['delta'] for x in rows]
unc = [x['delta'] for x in rows if not x['censored']]
rt = [x['vmax_vg100'] / x['vmax_vg0'] for x in rows]
summ = dict(n_pairs=len(rows), delta_mean=st.mean(dl), delta_median=st.median(dl), n_without_gt=len(unc),
            delta_without_gt_mean=(st.mean(unc) if unc else None), delta_without_gt_median=(st.median(unc) if unc else None),
            ratio_median=st.median(rt), ratio_mean_without_gt=st.mean([x['vmax_vg100']/x['vmax_vg0'] for x in rows if not x['censored']]), ratio_max=max(rt), n_at_cap=sum(x['at_vne_cap'] for x in rows),
            n_censored_gt=sum(x['censored'] for x in rows),
            n_vg100_below_vg0=sum(1 for x in dl if x < 0))
json.dump(summ, open(os.path.join(here, 'out/vg_pairs_summary.json'), 'w'), ensure_ascii=False, indent=1)
print(json.dumps(summ, ensure_ascii=False, indent=1))
for x in rows[:0]: print(x)
