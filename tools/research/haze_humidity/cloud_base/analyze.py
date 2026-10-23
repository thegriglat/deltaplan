"""Замер яркостей по кадрам (field_shot/storm_shot): <tag>_<вид>.png (с облаками) и _off.png (без).
Кадры линейные (тонмаппер LINEAR, экспозиция из META) → Y = 0.2126R+0.7152G+0.0722B в линейном sRGB / экспозиция.
Облако: |Y_on − Y_off| > 0.08·max(Y_off, 0.05) (тени облаков на земле отключены).
Основание: нижние 20% каждой вертикальной связной серии облачных пикселей (серии ≥ 24 px);
верх: 95-й перцентиль Y облачных пикселей вида; небо: пиксели без облака в тех же колонках, 12..70 px ниже
серии, у которых в кадре без облаков B/R > 1.8 (небо, не рельеф).
Запуск: python analyze.py <каталог кадров> <ratios.csv>"""
import sys, json, re, glob, os
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from model import lit_ratio, Yw

def lin(a):
    a = a / 255.0
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)

def load(p, exp):
    return lin(np.asarray(Image.open(p).convert('RGB')).astype(float)) / exp

def ranges(meta, H, W):
    """Расстояние по лучу до плоскости основания (м), inf — если глаз выше основания или луч вниз."""
    e = np.array(meta['eye']); f = np.array(meta['fwd']); f /= np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0]); r /= np.linalg.norm(r); u = np.cross(r, f)
    th = np.tan(np.radians(meta['fov_v_deg']) / 2)
    ys, xs = np.mgrid[0:H, 0:W]
    nx = ((xs + .5) / W * 2 - 1) * th * W / H; ny = (1 - (ys + .5) / H * 2) * th
    d = f[None, None] + nx[..., None] * r + ny[..., None] * u
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    dh = meta['base_msl'] - e[1]
    with np.errstate(divide='ignore', invalid='ignore'):
        rg = np.where((d[..., 1] > 1e-3) & (dh > 0), dh / d[..., 1], np.inf)
    return rg

def measure(on, off, meta, max_range=None):
    Yon, Yoff = on @ Yw, off @ Yw
    H, W = Yon.shape
    cloud = np.abs(Yon - Yoff) > 0.08 * np.maximum(Yoff, 0.05)
    rg = ranges(meta, H, W)
    cloud_all = cloud
    if max_range:
        cloud = cloud & (rg < max_range)
    skyish = (off[..., 2] / np.maximum(off[..., 0], 1e-6)) > 1.8
    base_px, sky_px = [], []
    for x in range(W):
        col = cloud[:, x]
        y = 0
        while y < H:
            if not col[y]:
                y += 1; continue
            y0 = y
            while y < H and col[y]: y += 1
            y1 = y  # серия [y0,y1)
            if y1 - y0 < 24: continue
            n = max(int((y1 - y0) * 0.2), 4)
            base_px.append(Yon[y1 - n:y1, x])
            lo, hi = y1 + 12, min(y1 + 70, H)
            if lo < hi:
                m = (~cloud_all[lo:hi, x]) & skyish[lo:hi, x]
                if m.any(): sky_px.append(Yon[lo:hi, x][m])
    cl = Yon[cloud]
    cat = lambda l: np.concatenate(l) if l else np.array([np.nan])
    b, s = cat(base_px), cat(sky_px)
    return dict(L_base=float(np.nanmean(b)), L_base_p10=float(np.nanpercentile(b, 10)), L_sky=float(np.nanmean(s)),
                L_top=float(np.percentile(cl, 95)) if cl.size else float('nan'),
                cloud_frac=float(cloud.mean()), range_km=float(np.median(rg[cloud]) / 1000) if cloud.any() and np.isfinite(np.median(rg[cloud])) else float('nan'), n_base=int(b.size), n_sky=int(s.size) if not np.isnan(s[0]) else 0)

HOURS = {'ong13': 13, 'ong9': 9, 'cb14': 14, 'ong13so150': 13, 'ong13so700': 13, 'ong13so100000': 13}
CASES = {  # тип → (tau_lo, tau_hi) для эталона; источник — README
    'cu_thin': (10, 25), 'cu_med': (25, 60), 'cb': (100, 300)}

def main(d, outcsv, kinds):
    rows = []
    for lf in sorted(glob.glob(os.path.join(d, '*.log'))):
        txt = open(lf, errors='ignore').read()
        mm_ = re.search(r'мощность макс (\d+)', txt)
        dmax = float(mm_.group(1)) if mm_ else None
        for line in open(lf, errors='ignore'):
            if not line.startswith('META '): continue
            m = json.loads(line[5:])
            if dmax and not m.get('depth_max'): m['depth_max'] = dmax
            p = os.path.join(d, '%s_%s.png' % (m['tag'], m['view'].split('_r')[0])) if not m['tag'].startswith('cb') else os.path.join(d, '%s.png' % m['view'])
            if not os.path.exists(p): continue
            off = p.replace('.png', '_off.png')
            if not os.path.exists(off): continue
            on_, off_ = load(p, m['exposure']), load(off, m['exposure'])
            ctype = kinds.get(m['tag'], 'cu_med')
            rows.append((m, ctype, measure(on_, off_, m)))
            if m['eye'][1] < m['base_msl'] - 500:   # глаз заметно ниже основания: срез по дальности
                for mr in (6000, 12000):
                    mm = dict(m); mm['view'] = '%s_r%dkm' % (m['view'], mr // 1000)
                    rows.append((mm, ctype, measure(on_, off_, m, mr)))
    with open(outcsv, 'w') as f:
        f.write('case,cloud_type,depth_m,view,hour,L_base,L_sky,L_top,ratio_base_sky,ratio_base_top,lit_ratio_lo,lit_ratio_hi,source,L_base_p10,ratio_p10_top,range_km\n')
        for m, ct, r in rows:
            t0, t1 = CASES[ct]
            lo, hi = lit_ratio(t1, 0.1, 0.7), lit_ratio(t0, 0.3, 1.0)
            dep = m.get('depth_max') or ''
            f.write('%s_%s,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%s,%.4f,%.3f,%.2f\n' % (
                m['tag'], m['view'], ct, ('%.0f' % dep) if dep else '', m['view'], HOURS.get(m['tag'], ''),
                r['L_base'], r['L_sky'], r['L_top'], r['L_base'] / r['L_sky'], r['L_base'] / r['L_top'], lo, hi,
                'frames:game; physical:two-stream T=1/(1+0.75(1-g)tau) g=0.85 tau %g-%g A 0.1-0.3 f 0.7-1' % (t0, t1), r['L_base_p10'], r['L_base_p10'] / r['L_top'], r['range_km']))
            print(m['tag'], m['view'], ct, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()})

if __name__ == '__main__':
    kinds = {'ong13': 'cu_med', 'ong9': 'cu_thin', 'cb14': 'cb', 'ong13so150': 'cu_med', 'ong13so700': 'cu_med', 'ong13so100000': 'cu_med'}
    main(sys.argv[1], sys.argv[2], kinds)
