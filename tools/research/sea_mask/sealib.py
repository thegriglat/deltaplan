"""Примитивы признака: связные компоненты (по сериям), расстояние до суши (Meijster). Только numpy."""
import numpy as np


def label_runs(mask):
    """Компоненты 8-связности булевой маски. Возвращает (labels int32, число). 0 — фон."""
    H, W = mask.shape
    parent = [0]

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    runs = []  # по строкам: (start, end_exclusive, id)
    prev = []
    row_runs = []
    for y in range(H):
        r = mask[y]
        d = np.diff(np.concatenate(([0], r.view(np.uint8), [0])).astype(np.int8))
        st = np.flatnonzero(d == 1)
        en = np.flatnonzero(d == -1)
        cur = []
        j = 0
        for s, e in zip(st.tolist(), en.tolist()):
            parent.append(len(parent))
            i = len(parent) - 1
            # 8-связность: серии предыдущей строки, пересекающие [s-1, e]
            while j < len(prev) and prev[j][1] < s:  # prev.end (excl) <= s-1  -> prev[j][1] < s
                j += 1
            k = j
            while k < len(prev) and prev[k][0] <= e:
                a, b = find(i), find(prev[k][2])
                if a != b:
                    parent[max(a, b)] = min(a, b)
                k += 1
            cur.append((s, e, i))
        row_runs.append(cur)
        prev = cur
    # окончательные метки
    roots = {}
    lab = np.zeros((H, W), np.int32)
    n = 0
    for y, cur in enumerate(row_runs):
        for s, e, i in cur:
            r = find(i)
            if r not in roots:
                n += 1
                roots[r] = n
            lab[y, s:e] = roots[r]
    return lab, n


def edt(feature):
    """Евклидово расстояние (в клетках) от каждой клетки до ближайшей True в feature (Meijster).
    Если feature пуст — большое число."""
    H, W = feature.shape
    INF = H + W + 10
    g = np.full((H, W), INF, np.int64)
    g[feature] = 0
    for y in range(1, H):  # сверху вниз
        np.minimum(g[y], g[y - 1] + 1, out=g[y])
    for y in range(H - 2, -1, -1):
        np.minimum(g[y], g[y + 1] + 1, out=g[y])
    out = np.empty((H, W), np.float64)
    xs = np.arange(W)
    for y in range(H):
        gy = g[y]
        if gy.min() >= INF:
            out[y] = INF
            continue
        # нижняя огибающая парабол f(x)=(x-q)^2+g[q]^2
        s = [0] * W
        t = [0] * W
        q = 0
        s[0] = 0
        t[0] = 0
        gl = gy.tolist()
        for u in range(1, W):
            while q >= 0 and (t[q] - s[q]) ** 2 + gl[s[q]] ** 2 > (t[q] - u) ** 2 + gl[u] ** 2:
                q -= 1
            if q < 0:
                q = 0
                s[0] = u
            else:
                w = 1 + ((u * u - s[q] * s[q] + gl[u] ** 2 - gl[s[q]] ** 2) // (2 * (u - s[q])))
                if w < W:
                    q += 1
                    s[q] = u
                    t[q] = w
        row = np.empty(W)
        for u in range(W - 1, -1, -1):
            row[u] = (u - s[q]) ** 2 + gl[s[q]] ** 2
            if u == t[q]:
                q -= 1
        out[y] = np.sqrt(row)
    return out
