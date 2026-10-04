"""Формы плана air-synth §2 (гребень «гаусс поперёк × плашка вдоль», эллиптический пупырь) и жадное
разложение рельефа на сумму форм (matching pursuit с подгонкой параметров)."""
import numpy as np
from scipy.optimize import least_squares
from scipy.ndimage import gaussian_filter

# параметры, км и радианы. ridge: x0,y0,th,H,ls,lL,lw,a    blob: x0,y0,th,H,ls1,ls2
NP = {"ridge": 8, "blob": 6}


def ridge(p, X, Y):
    x0, y0, th, H, ls, lL, lw, a = p
    c, s = np.cos(th), np.sin(th)
    u = (X - x0) * c + (Y - y0) * s
    v = -(X - x0) * s + (Y - y0) * c
    sg = np.exp(ls) * np.where(v > 0, np.exp(a), np.exp(-a))
    L, w = np.exp(lL), np.exp(lw)
    S = 0.5 * (np.tanh((u + L) / w) - np.tanh((u - L) / w))
    return H * np.exp(-0.5 * (v / sg) ** 2) * S


def blob(p, X, Y):
    x0, y0, th, H, l1, l2 = p
    c, s = np.cos(th), np.sin(th)
    u = (X - x0) * c + (Y - y0) * s
    v = -(X - x0) * s + (Y - y0) * c
    return H * np.exp(-0.5 * ((u / np.exp(l1)) ** 2 + (v / np.exp(l2)) ** 2))


FN = {"ridge": ridge, "blob": blob}


def lo_hi(kind, ext, Hmax, signed):
    Hlo = -Hmax if signed else 0.0
    if kind == "ridge":
        lo = [-0.1, -0.1, -10, Hlo, np.log(0.15), np.log(0.2), np.log(0.1), -1.0]
        hi = [ext + 0.1, ext + 0.1, 10, Hmax, np.log(ext / 2), np.log(ext), np.log(ext / 2), 1.0]
    else:
        lo = [-0.1, -0.1, -10, Hlo, np.log(0.15), np.log(0.15), 0, 0][:6]
        hi = [ext + 0.1, ext + 0.1, 10, Hmax, np.log(ext / 2), np.log(ext / 2)]
    return np.array(lo), np.array(hi)


def render(forms, X, Y):
    z = np.zeros_like(X)
    for f in forms:
        z += FN[f["kind"]](f["p"], X, Y)
    return z


def plane_fit(r, X, Y):
    A = np.stack([np.ones(r.size), X.ravel(), Y.ravel()], 1)
    c, *_ = np.linalg.lstsq(A, r.ravel(), rcond=None)
    return (A @ c).reshape(r.shape), c


def _starts(res, X, Y, dx_km, signed):
    """Стартовые формы: по локальным экстремумам сглаженного остатка."""
    out = []
    for sgn in ((1, -1) if signed else (1,)):
        sm = sgn * gaussian_filter(res, 2)
        flat = np.argsort(-sm.ravel())[:2000]
        picked = []
        for idx in flat:
            i, j = divmod(idx, res.shape[1])
            if all((i - a) ** 2 + (j - b) ** 2 > 36 for a, b in picked):
                picked.append((i, j))
            if len(picked) >= 5:
                break
        for i, j in picked:
            H = sgn * max(sm[i, j], 1.0)
            x0, y0 = X[i, j], Y[i, j]
            for s_km in (1.0, 2.5, 6.0):
                out.append(("blob", np.array([x0, y0, 0.0, H, np.log(s_km), np.log(s_km)])))
            for th in np.radians([0, 45, 90, 135]):
                for s_km, L_km in ((1.2, 4.0), (3.0, 10.0)):
                    out.append(("ridge", np.array([x0, y0, th, H, np.log(s_km), np.log(L_km), np.log(1.0), 0.0])))
    return out


def fit_greedy(h, dx_m, nforms=30, signed=False, ncand=4, fit_step=1, verbose=False):
    """h — массив (n,n) в м, шаг dx_m. Возвращает (список форм, кривая [(N, RMS_м, доля_дисперсии)], модель).
    Остаток = h − (сумма форм + плоскость). fit_step>1 — подгонка на прореженной сетке (оценка остатка — на полной)."""
    n = h.shape[0]
    ext = n * dx_m / 1000.0
    y, x = np.mgrid[0:n, 0:n] * dx_m / 1000.0
    X, Y = x, y
    Xs, Ys, hs = X[::fit_step, ::fit_step], Y[::fit_step, ::fit_step], h[::fit_step, ::fit_step]
    var = h.var()
    forms = []
    curve = []
    Hmax = float(h.max() - h.min()) * 1.2

    def total(fs, XX, YY, hh):
        z = render(fs, XX, YY)
        pl, _ = plane_fit(hh - z, XX, YY)
        return z + pl

    for k in range(nforms):
        model_s = total(forms, Xs, Ys, hs)
        res = hs - model_s
        cands = _starts(res, Xs, Ys, dx_m * fit_step / 1000.0, signed)
        # быстрая оценка: оптимальная амплитуда H при фиксированных остальных параметрах
        scored = []
        for kind, p in cands:
            p1 = p.copy(); p1[3] = 1.0
            g = FN[kind](p1, Xs, Ys)
            Hopt = float((res * g).sum() / max((g * g).sum(), 1e-9))
            if not signed:
                Hopt = max(Hopt, 0.0)
            gain = Hopt * float((res * g).sum()) - 0.5 * Hopt ** 2 * float((g * g).sum()) * 2 / 2
            p[3] = Hopt
            scored.append((gain, kind, p))
        scored.sort(key=lambda t: -t[0])
        best = None
        used = {"ridge": 0, "blob": 0}
        for gain, kind, p in scored:
            if used[kind] >= max(1, ncand // 2):
                continue
            used[kind] += 1
            lo, hi = lo_hi(kind, ext, Hmax, signed)
            p = np.clip(p, lo + 1e-6, hi - 1e-6)
            fun = lambda q, kind=kind: (FN[kind](q, Xs, Ys) - res).ravel()
            try:
                sol = least_squares(fun, p, bounds=(lo, hi), max_nfev=60, x_scale=np.maximum(np.abs(hi - lo) / 20, 1e-3))
            except Exception:
                continue
            if best is None or sol.cost < best[0]:
                best = (sol.cost, kind, sol.x)
            if sum(used.values()) >= ncand:
                break
        if best is None:
            break
        forms.append({"kind": best[1], "p": best[2]})
        # совместная подстройка параметров каждые 5 форм (немного итераций)
        if (k + 1) % 5 == 0 and len(forms) > 1:
            q0 = np.concatenate([f["p"] for f in forms])
            kinds = [f["kind"] for f in forms]
            los, his = zip(*[lo_hi(kd, ext, Hmax, signed) for kd in kinds])
            lo, hi = np.concatenate(los), np.concatenate(his)

            def unpack(q):
                out, o = [], 0
                for kd in kinds:
                    out.append({"kind": kd, "p": q[o:o + NP[kd]]}); o += NP[kd]
                return out
            fun = lambda q: (total(unpack(q), Xs, Ys, hs) - hs).ravel()
            try:
                sol = least_squares(fun, np.clip(q0, lo + 1e-6, hi - 1e-6), bounds=(lo, hi), max_nfev=8)
                forms = unpack(sol.x)
                forms = [{"kind": f["kind"], "p": f["p"].copy()} for f in forms]
            except Exception:
                pass
        model = total(forms, X, Y, h)
        rms = float(np.sqrt(np.mean((h - model) ** 2)))
        curve.append((len(forms), rms, 1 - rms ** 2 / var))
        if verbose:
            print(k + 1, best[1], f"rms={rms:.1f} R2={1 - rms ** 2 / var:.3f}", flush=True)
    model = total(forms, X, Y, h)
    return forms, curve, model


def describe(f):
    p = f["p"]
    if f["kind"] == "ridge":
        return dict(kind="ridge", x_km=p[0], y_km=p[1], theta_deg=float(np.degrees(p[2]) % 180), H_m=p[3],
                    sigma_km=float(np.exp(p[4])), L_half_km=float(np.exp(p[5])), w_km=float(np.exp(p[6])), asym=float(p[7]))
    s1, s2 = np.exp(p[4]), np.exp(p[5])
    return dict(kind="blob", x_km=p[0], y_km=p[1], theta_deg=float(np.degrees(p[2]) % 180), H_m=p[3],
                sigma1_km=float(s1), sigma2_km=float(s2))
