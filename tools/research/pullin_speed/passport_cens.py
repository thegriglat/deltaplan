"""Какие из полного-«на себя» паспортов крыльев игры (full_pull_speed_kmh = DHV Vmax VG 0) упираются в предел испытания Vne."""
import json, glob, re, os, csv
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '../../..')
M = {r['key']: r for r in json.load(open(root + '/tools/research/data/wing_passports/wings_merged.json'))}
rows = []
for f in sorted(glob.glob(root + '/configs/wings/*.json')):
    d = json.load(open(f))
    if 'pendulum' not in d: continue
    doc = d.get('full_pull_speed_kmh_doc', '')
    m = re.search(r'паспорт: ([^:]+): DHV vmax_vg0_kmh ([\d.]+)', doc)
    w = os.path.basename(f)[:-5]
    if not m:
        rows.append(dict(wing=w, source='масштаб класса', vmax=d['full_pull_speed_kmh'])); continue
    rec = M.get(m.group(1))
    fl = rec['fields'] if rec else {}
    v0 = fl.get('vmax_vg0_kmh'); vne = fl.get('vne_kmh')
    q = v0['sources'][0]['quote'] if v0 else ''
    rows.append(dict(wing=w, source='DHV VG0 ' + m.group(1), vmax=d['full_pull_speed_kmh'], vmax_vg0_dhv=v0 and v0['value'],
                     vne=vne and vne['value'], at_vne=bool(v0 and vne and v0['value'] >= vne['value']), quote=q[:80]))
keys = sorted({k for r in rows for k in r})
with open(here + '/out/passport_censoring.csv', 'w', newline='') as fh:
    w_ = csv.DictWriter(fh, fieldnames=keys); w_.writeheader(); w_.writerows(rows)
dh = [r for r in rows if r['source'].startswith('DHV')]
print(len(rows), 'wings;', len(dh), 'DHV VG0;', sum(1 for r in dh if r.get('at_vne')), 'at Vne cap;', sum(1 for r in dh if '>' in r.get('quote', '')), 'quote with ">"')
