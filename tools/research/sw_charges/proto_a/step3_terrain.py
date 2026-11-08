"""Рельефы шага 3: Agnesi и разрез Perdigão (линия как в sections/run_perd.py, NE-случай; поток вдоль +x)."""
import os, sys, math
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(HERE, '..'))
import panels2d as P2


def agnesi(H=200.0, L=500.0, half=6000.0, dx=10.0):
    x = np.arange(-half, half + dx, dx)
    return P2.Terrain(x, H / (1 + (x / L) ** 2))


def perdigao(L_LINE=8000.0, dx=10.0):
    sys.path.insert(0, os.path.join(REPO, 'tools', 'research', 'cases'))
    import perdigao as PD
    from scipy.ndimage import map_coordinates
    ci = PD.case_inputs('ne'); wdir = ci['wdir']
    ms = PD.masts()
    x0g, y0g, n, hc = PD.terrain(10.0, 9000.0)
    ex, ny_ = math.sin(math.radians(wdir)), math.cos(math.radians(wdir))
    s_of = lambda k: ms[k]['x'] * ex + ms[k]['y'] * ny_
    s_mid = 0.5 * (s_of('tse13') + s_of('tse04'))
    p0 = ms['tse13']['x'] * ny_ - ms['tse13']['y'] * ex
    sk = np.arange(-L_LINE / 2, L_LINE / 2, dx) + dx / 2
    s_abs = s_mid - sk
    px = s_abs * ex + p0 * ny_; py = s_abs * ny_ - p0 * ex
    z = map_coordinates(hc, [(py - y0g) / 10.0 - 0.5, (px - x0g) / 10.0 - 0.5], order=1, mode='nearest')
    z = z - z.min()
    x = -(s_abs - s_mid)          # вдоль потока; возрастает (sk убывает по s... проверяем знак ниже)
    if x[1] < x[0]:
        x, z = x[::-1], z[::-1]
    pos = {k: float(-(s_of(k) - s_mid)) for k in ('tse13', 'tse04', 'tse09')}
    return P2.Terrain(x, z), pos, dict(wdir=wdir, u100=ci['u100'])
