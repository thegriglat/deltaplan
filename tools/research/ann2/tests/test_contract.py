"""AN-2: контрактный тест A2 (формы и dtype батча и выхода, карты 64² и 96², поворот ×4, R∘R = тождество, обратное
преобразование выхода против `prep.to_physical` П2, конечность). Запуск: `python tests/test_contract.py`, код выхода 0/≠0.
Нужны данные пилота (кеш подготовки П2, только чтение); GPU не нужен."""
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import data as D  # noqa: E402
import model as M  # noqa: E402
import phys  # noqa: E402
from phys import P  # noqa: E402

fails = []


def check(name, ok, info=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  {info}" if info else ""))
    if not ok:
        fails.append(name)


def main():
    cpu = torch.device("cpu")
    split = D.p2_split()
    ids = split["train_ids"][:3] + split["holdout_sys_ids"][:1]
    st = D.Store(ids)
    rng = np.random.default_rng(0)
    # --- батч загрузчика
    for crop in (64, 96):
        b = D.sample_batch(st, np.arange(4), rng, cpu, crop=crop, K=3, Kd=2)
        B = 4
        shp = dict(maps=(B, phys.N_MAPS, crop, crop), scal=(B, phys.N_SCAL), prof=(B, phys.N_PROF_CH, 13), par=(B, 4),
                   eta=(B, 3, crop, crop), eta_div=(B, 2, 2), y=(B, 3, 4, crop, crop), mask=(B, 4))
        for k, s in shp.items():
            check(f"batch[{k}] {crop}² форма", tuple(b[k].shape) == s, f"{tuple(b[k].shape)} ожидалось {s}")
            check(f"batch[{k}] {crop}² float32 конечный", b[k].dtype == torch.float32 and bool(torch.isfinite(b[k]).all()))
        check("η в [25, 2000]", float(b["eta"].min()) >= 25 - 1e-3 and float(b["eta"].max()) <= 2000 + 1e-3)
    # --- выход сети, карты 64² и 96² без смены кода
    m = M.Ann2().eval()
    for H in (64, 96):
        b = D.sample_batch(st, np.arange(2), rng, cpu, crop=H, K=2, Kd=1)
        with torch.no_grad():
            o = m(b["maps"], b["scal"], b["prof"], b["par"], b["eta"])
        check(f"выход сети {H}²", tuple(o.shape) == (2, 2, 8, H, H) and o.dtype == torch.float32 and bool(torch.isfinite(o).all()),
              str(tuple(o.shape)))
    # --- поворот ×4 и R∘R
    X = st.X[:2]; F = st.F[:2]; Y = st.Y[:2]
    a = X[:, :1].copy()
    for _ in range(4):
        a = P.rot_scalar(a, 1)
    check("поворот на 90° ×4 карты = тождество", np.array_equal(a, X[:, :1]))
    u, v = Y[0, 0].astype(np.float32), Y[0, 1].astype(np.float32)
    u2, v2 = u, v
    for _ in range(4):
        u2, v2 = P.rot_vec(u2, v2, 1)
    check("поворот векторного поля ×4 = тождество", np.array_equal(u2, u) and np.array_equal(v2, v))
    X2, F2, Y2 = P.reflect(*P.reflect(X, F, Y))
    check("R∘R = тождество (карты, числа, цель)", np.array_equal(X2, X) and np.array_equal(F2, F) and np.array_equal(Y2, Y))
    Xr, Fr, Yr = P.reflect(X, F, Y)
    check("отражение меняет sin r и карту slope_cross", np.allclose(Fr[:, 2], -F[:, 2]) and not np.array_equal(Xr, X))
    # --- обратное преобразование выхода == prep.to_physical П2 на уровнях П1
    ok_h = ok_m = True; err = 0.0
    for i in range(len(st)):
        meta, y = st.metas[i], st.Y[i].astype(np.float64)
        ref = P.to_physical(y, meta)
        mu = phys.from_p2_target(y, meta, phys.AGL)                  # (2: m,h; 4; 13; ny; nx)
        for j, key in ((0, "m"), (1, "h")):
            ph = phys.to_physical(mu[j], meta, phys.AGL)             # (4,13,ny,nx)
            n = ref[key].shape[0]
            e = float(np.abs(ph[:n] - ref[key]).max()); err = max(err, e)
    check("to_physical(from_p2_target) = prep.to_physical П2 (м/с, К)", err < 1e-3, f"макс. разность {err:.2e}")
    # --- загрузчик на уровнях П1 (η = AGL, без отражения, вся область 96²) = from_p2_target
    b = D.sample_batch(st, np.array([0]), np.random.default_rng(1), cpu, crop=96, K=13, Kd=1, reflect=False, p_heat=1.0,
                       fixed_eta=phys.AGL)
    ref = phys.from_p2_target(st.Y[0].astype(np.float64), st.metas[0], phys.AGL)[1]           # (4,13,96,96) h
    got = b["y"][0].permute(1, 0, 2, 3).numpy()
    check("загрузчик: цель на уровнях П1 = пересчёт цели П2 в доли max(U(η), 1)", np.abs(got - ref).max() < 1e-4,
          f"{np.abs(got - ref).max():.2e}")
    b = D.sample_batch(st, np.array([0]), np.random.default_rng(1), cpu, crop=96, K=13, Kd=1, reflect=False, p_heat=0.0,
                       fixed_eta=phys.AGL)
    refm = phys.from_p2_target(st.Y[0].astype(np.float64), st.metas[0], phys.AGL)[0]
    check("загрузчик: решение m — цель m, θ′ маскирована, карта тепла = 0",
          np.abs(b["y"][0, :, :3].permute(1, 0, 2, 3).numpy() - refm[:3]).max() < 1e-4 and float(b["mask"][0, 3]) == 0.0
          and float(b["maps"][0, 1].abs().max()) == 0.0)
    # --- поворот в to_physical: нулевое отклонение даёт профиль притока в исходной системе
    meta = dict(st.metas[0]); z = np.zeros((4, 2, 8, 8))
    ph = phys.to_physical(z, meta, [25.0, 100.0])
    U = phys.u_profile(np.array([25.0, 100.0]), meta["alpha"], meta["mp"], meta["U10"])
    check("нулевой выход → приток U(η) в исходной системе", np.allclose(np.hypot(ph[0], ph[1]), U[:, None, None], atol=1e-6)
          and np.allclose(ph[2], 0))
    check("карты ann2 без абсолютных координат", "x" not in phys.MAP_NAMES and "y" not in phys.MAP_NAMES)
    if fails:
        print("ПРОВАЛЕНО:", fails)
        sys.exit(1)
    print("все проверки пройдены")


if __name__ == "__main__":
    main()
