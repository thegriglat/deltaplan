"""Разбор логов зонда LT-11: out/starts.csv, out/profiles.csv, out/grid.csv, out/summary.json.
python3 analyze.py out/logs/<лог>.log [--tag ltm]  (аргумент --tag — метка поля/модели в столбце model)"""
import csv, json, sys, os, math
from branches import branches

def parse(path):
    pts, starts, grids = [], {}, {}
    for line in open(path, errors='replace'):
        if line.startswith('LT11S '):
            j = json.loads(line[6:]); starts[j['key']] = j
        elif line.startswith('LT11G '):
            j = json.loads(line[6:]); grids[j['tag']] = j['rows']
        elif line.startswith('LT11 '):
            pts.append(json.loads(line[5:]))
    return pts, starts, grids

def row_for(j, starts, model):
    key, kind = j['tag'].rsplit('.', 1)
    ch = j['chan']; tb = ch['tb']
    b = branches(ch['agl'], tb, ch['uf'], ch['z0'], ch['lee_f'], ch['relief'], ch['u_h'], ch['dx'][0])
    ts = j['term_sigma']
    r = dict(model=model, start=key, dir=kind, from_deg=j['from_deg'], x=j['p'][0], y=j['p'][1], z=j['p'][2],
             agl=ch['agl'], ground=ch['ground'], sigma=j['sigma'], sigma_rec=b['su_rec'],
             w=j['w'], mean_w=j['mean'][1], speed_mean=math.hypot(j['mean'][0], j['mean'][2]),
             share=ch['share'], uf=ch['uf'], dx=ch['dx'][0], z0=ch['z0'],
             shear=tb[0], n2=tb[1], ustar=tb[2], u_out=tb[3], a_out=tb[4], desc=tb[5], wstar=tb[6], hmix=tb[7],
             lee_f=ch['lee_f'], relief=ch['relief'], u_h=ch['u_h'], du=b['du'],
             w_sep=b['w_sep'], unres=b['unres'], u_wall=b['u_wall'], u_shear=b['u_shear'],
             su_wall=b['su_wall'], su_shear=b['su_shear'], su_shear_nocut=b['su_shear_nocut'], su_m=b['su_m'], su_c=b['su_c'],
             su_layer=b['su_layer'], sw_layer=b['sw_layer'], win=b['win'],
             term_sigma_field=ts.get('turb', ts.get('field_turb', '')), term_names='|'.join(ts))
    return r

def main():
    log = sys.argv[1]; model = sys.argv[sys.argv.index('--tag') + 1] if '--tag' in sys.argv else 'ltm'
    pts, starts, grids = parse(log)
    rows = [row_for(j, starts, model) for j in pts]
    out = os.path.join(os.path.dirname(__file__), 'out'); os.makedirs(out, exist_ok=True)
    suf = '' if model == 'ltm' else '_' + model
    with open(f'{out}/starts{suf}.csv', 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    with open(f'{out}/profiles{suf}.csv', 'w', newline='') as f:
        w = csv.writer(f); w.writerow(['model', 'start', 'dir', 'agl', 'sigma', 'uf', 'lee_f', 'relief', 'u_h', 'shear', 'ustar', 'u_out', 'a_out', 'desc', 'hmix', 'wstar', 'su_wall', 'su_shear', 'su_layer', 'su_c', 'win'])
        for j in pts:
            key, kind = j['tag'].rsplit('.', 1)
            g0 = j['chan']['ground']
            for q in j['prof']:
                tb = q['tb']
                b = branches(q['agl'], tb, q['uf'], j['chan']['z0'], q['lee_f'], q['relief'], q['u_h'], j['chan']['dx'][0])
                w.writerow([model, key, kind, q['agl'], q['sigma'], q['uf'], q['lee_f'], q['relief'], q['u_h'], tb[0], tb[2], tb[3], tb[4], tb[5], tb[7], tb[6], b['su_wall'], b['su_shear'], b['su_layer'], b['su_c'], b['win']])
    with open(f'{out}/grid{suf}.csv', 'w', newline='') as f:
        w = csv.writer(f); w.writerow(['model', 'start', 'dir', 'd_m', 'agl', 'ground', 'vx', 'vy', 'vz', 'sigma'])
        for tag, rr in grids.items():
            key, kind = tag.rsplit('.', 1)
            for r in rr: w.writerow([model, key, kind] + r)
    json.dump({'starts': starts}, open(f'{out}/scan_points{suf}.json', 'w'), ensure_ascii=False, indent=1)
    print(len(rows), 'rows')

main()
