"""Синтетические F1/F2/M1 для самопроверки и тестов."""
import numpy as np
from cascade2d_io import X_LEN, write_f1


def make_f1(dx=400, case="C1", source="picard", variant=None, parent_dx=None, seed=None, nz=6, U=5.0):
    nx = int(X_LEN // dx)
    dz = dx / 4
    cell = np.ones((nz, nx), np.float32)
    h = np.zeros(nx, np.float32)
    mid = nx // 2
    cell[0, mid - 1:mid + 1] = 0  # холмик в нижнем слое
    h[mid - 1:mid + 1] = dz
    tu = np.ones((nz, nx + 1), np.float32)
    tw = np.ones((nz + 1, nx), np.float32)
    tw[0, :] = 0  # дно — стенка
    tu[:, 0] = 0
    tu[:, -1] = 0
    tu[:, 1:-1][(cell[:, :-1] == 0) | (cell[:, 1:] == 0)] = 0
    tw[1:-1, :][(cell[:-1, :] == 0) | (cell[1:, :] == 0)] = 0
    # однородный поток; на стенках 0
    u = np.full((nz, nx + 1), U, np.float32) * (tu > 0)
    w = np.zeros((nz + 1, nx), np.float32)
    th = np.zeros((nz, nx), np.float32)
    meta = dict(case=case, source=source, variant=variant, dx=dx, dz=dz, nx=nx, nz=nz, x0=-6400.0,
                z0=-dz, parent_dx=parent_dx, seed=seed, git="synthetic")
    arrays = dict(u=u, w=w, th=th, cell=cell, tu=tu, tw=tw, h=h)
    return meta, arrays


def write_synth_f1(path, **kw):
    meta, arrays = make_f1(**kw)
    write_f1(path, meta, arrays)
    return meta, arrays


def make_f2(**over):
    r = dict(format="cascade2d-run", version=1, case="C1", source="picard", variant=None, dx=400,
             parent_dx=None, seed=None, threads=4, ny=4, status="ok", iters=12,
             time=dict(total_s=1.0, setup_s=0.2, work_s=0.8, per_row_s=0.2),
             memory=dict(peak_rss_mb=100.0, arrays_mb=10.0),
             balance=dict(max_rel_div=1e-3, rms_rel_div=1e-4, levels=[dict(dx=400, max_rel_div=1e-3)]),
             y_uniform=1e-6, query=None, field="x.json", cmd="synthetic",
             host=dict(cpu="cpu", rustc="1.0"), git="synthetic", notes=None)
    r.update(over)
    return r


def make_m1(**over):
    row = dict(field="x.json", source="baseline", variant="B400", dx=400, parent_dx=None, seed=None,
               E_u=0.1, E_w=0.2, E_u_lee=0.3, dS=dict(zip(("25", "50", "100", "mean"), (0.1, 0.2, 0.3, 0.2))),
               r_w=0.9, L_rec=None, L_rec_ref=None, w_max=1.0, w_max_ref=1.1, F_up=None, F_up_ref=None,
               max_rel_div=0.01, max_speed=6.0, sigma_u=None, sigma_w=None)
    m = dict(format="cascade2d-metrics", version=1, case="C1", ref="p25.json", U_ref=5.0,
             E_ref=dict(E_u=0.05), rows=[row])
    m.update(over)
    return m
