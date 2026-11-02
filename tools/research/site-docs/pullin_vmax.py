#!/usr/bin/env python3
"""SD-13: сводка перемера Vmax «на себя» — raw/raw_*.json → pullin_vmax.json и pullin_vmax.md.
Воспроизведение: tools/research/site-docs/run_pullin_vmax.sh, затем этот скрипт. Из любого места."""
import csv, glob, json, os, statistics as st, subprocess

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '../../..')
C = {}
for f in sorted(glob.glob(here + '/raw/raw_*.json')):
    C.update(json.load(open(f))['wings'])
cens = {r['wing']: r for r in csv.DictReader(open(os.path.join(root, 'tools/research/pullin_speed/out/passport_censoring.csv')))}
wings = {}
for w, c in sorted(C.items()):
    cfg = json.load(open(os.path.join(root, 'configs/wings/%s.json' % w)))
    ref = cfg['full_pull_speed_kmh']
    wings[w] = dict(config_ref_kmh=ref, normal_kmh=round(c['normal']['V_kmh'], 1), full_kmh=round(c['full']['V_kmh'], 1),
                    full_std_kmh=round(c['full']['V_std_kmh'], 2),
                    passport_vmax_vg0_kmh=float(cens[w]['vmax']) if w in cens else None,
                    passport_censored_by_vne=(cens[w].get('at_vne') == 'True') if w in cens else None,
                    full_to_ref=round(c['full']['V_kmh'] / ref, 3), normal_to_ref=round(c['normal']['V_kmh'] / ref, 3))
unc = [v for v in wings.values() if v['passport_vmax_vg0_kmh'] and not v['passport_censored_by_vne']]
commit = subprocess.run(['git', '-C', root, 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True).stdout.strip()
s = dict(task='SD-13', game_commit=commit, wings=len(wings),
         median_full_to_ref=round(st.median(v['full_to_ref'] for v in wings.values()), 3),
         median_normal_to_ref=round(st.median(v['normal_to_ref'] for v in wings.values()), 3),
         median_full_to_passport_uncensored=round(st.median(v['full_kmh'] / v['passport_vmax_vg0_kmh'] for v in unc), 3),
         n_uncensored=len(unc))
json.dump(dict(summary=s, wings=wings), open(os.path.join(here, 'pullin_vmax.json'), 'w'), ensure_ascii=False, indent=1)
with open(os.path.join(here, 'pullin_vmax.md'), 'w') as f:
    f.write('# Vmax «на себя» в игре (SD-13)\n\nКоммит игры %s; %d крыльев. Медиана «с добором» / эталон конфига: %s; без добора: %s; '
            'с добором / паспорт Vmax VG 0 (без усечённых Vne, %d): %s.\n\n' % (
                commit, len(wings), s['median_full_to_ref'], s['median_normal_to_ref'], len(unc), s['median_full_to_passport_uncensored']))
    f.write('| крыло | эталон конфига, км/ч | без добора | с добором | с добором / эталон |\n|---|---|---|---|---|\n')
    for w, v in wings.items():
        f.write('| %s | %s | %s | %s | %s |\n' % (w, v['config_ref_kmh'], v['normal_kmh'], v['full_kmh'], v['full_to_ref']))
print(json.dumps(s, ensure_ascii=False))
