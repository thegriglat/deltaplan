"""TB-18: почему в игре нет притока у земли — разбор по причинам (стадия, рельеф, радиус колец, таблицы).

Счёт — Rust-тест `rust/dp-air/tests/thermal_bubble_ground.rs` (то же состояние набора и `sample_bubble`, что в игре); этот файл
запускает его, собирает строки `GRJSON`, пишет `out/round3_ground_inflow.json` и `round3/ground_inflow_*.png`.
Запуск: tools/research/thermal_bubble/py tools/research/thermal_bubble/round3/ground_inflow.py            (≈ 3–5 мин, cargo + сборка)
        tools/research/thermal_bubble/py tools/research/thermal_bubble/round3/ground_inflow.py --log ЛОГ  (из готового лога теста)
Сетка высот Алтая строится сама (--dem): ~/.cache/thermal_bubble/ground_dem_altai.f32 из кеша тайлов Terrarium игры; нет файла — тест пропускает случай altai.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
TB = HERE.parent
ROOT = TB.parents[2]
OUT = TB / "out" / "round3_ground_inflow.json"
ZERO = 0.01
DEM_PATH = Path.home() / ".cache" / "thermal_bubble" / "ground_dem_altai.f32"   # читает тест (env HOME)
GAME = {"zero_frac_cores": 0.77, "median_ur": 0.0008, "source": "TB-16 (flight_probe, ongudai, seed 1, 1200 с)"}


def make_dem() -> None:
    """Сетка высот Алтая 401×401, шаг 30 м → DEM_PATH (тайлы Terrarium кеша игры, центр тайла 12/3028/1376, ~10 км к югу от Онгудая;
    тайлов Онгудая в кеше нет — он на Copernicus). x на восток, z на юг, [j][i] = (z, x), центр (200, 200). Данные: AWS Terrain Tiles."""
    import math
    from PIL import Image
    LAT, LON, Z = 50.7086, 86.1768, 12  # центр тайла 12/3028/1376: Алтай в ~10 км к югу от Онгудая (тайлов Онгудая в кеше нет — Copernicus)
    N, STEP = 401, 30.0
    cache = Path.home() / ".local/share/Deltaplan/terrain_cache/terrarium" / str(Z)
    n = 2 ** Z
    mpp = 156543.03392 * math.cos(math.radians(LAT)) / (2 ** Z)  # при тайле 256 px: м/px = C*cos/2^z (C для 256 px на z=0)
    px0 = (LON + 180) / 360 * n * 256
    py0 = (1 - math.asinh(math.tan(math.radians(LAT))) / math.pi) / 2 * n * 256
    tiles = {}
    def tile(tx, ty):
        if (tx, ty) not in tiles:
            p = cache / str(tx) / f"{ty}.png"
            if not p.exists():
                sys.exit(f"нет тайла {p}")
            a = np.asarray(Image.open(p).convert("RGB"), float)
            tiles[(tx, ty)] = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
        return tiles[(tx, ty)]
    H = np.zeros((N, N), np.float32)
    for j in range(N):
        for i in range(N):
            x, z = (i - 200) * STEP, (j - 200) * STEP
            px, py = px0 + x / mpp, py0 + z / mpp
            tx, ty = int(px // 256), int(py // 256)
            fx, fy = px - tx * 256, py - ty * 256
            t = tile(tx, ty)
            ix, iy = min(int(fx), 255), min(int(fy), 255)
            H[j, i] = t[iy, ix]
    DEM_PATH.parent.mkdir(parents=True, exist_ok=True)
    H.tofile(DEM_PATH)
    dx = np.gradient(H, STEP, axis=1); dz = np.gradient(H, STEP, axis=0)
    sl = np.degrees(np.arctan(np.hypot(dx, dz)))
    print("h min/med/max", H.min(), np.median(H), H.max(), "slope pct 25/50/75/90", np.percentile(sl, [25, 50, 75, 90]).round(1), "центр", H[200, 200])


def run_test() -> str:
    cmd = ["cargo", "test", "--manifest-path", str(ROOT / "rust/Cargo.toml"), "-p", "dp-air", "--release",
           "--test", "thermal_bubble_ground", "--", "--nocapture"]
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=True).stdout


def parse(text: str) -> dict[str, dict]:
    res = {}
    for line in text.splitlines():
        i = line.find("GRJSON ")
        if i >= 0:
            d = json.loads(line[i + 7:])
            res[d["terrain"]] = d
    return res


def summarize(res: dict[str, dict]) -> dict:
    terr = {}
    for k, d in res.items():
        cr = d["core_rows"]
        m = np.array([c["ur_mean"] for c in cr])
        mf = np.array([c["ur_mean_flat"] for c in cr])
        terr[k] = {
            "slope_deg": float(np.degrees(np.arctan(d["slope"]))), "n_obs": d["n"], "n_cores": d["cores"]["n"],
            "zero_frac_obs": d["zero_frac"], "zero_frac_cores": d["cores"]["zero_frac"],
            "causes_cores": d["cores"]["causes"], "causes_obs": d["causes"],
            "median_ur_cores": float(np.median(m)), "median_ur_cores_flat": float(np.median(mf)),
            "zero_frac_cores_flat": float((abs(mf) < ZERO).mean()),
            "by_stage": d["by_stage_signed"],
        }
    return terr


def figure(terr: dict) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    names = ["flat", "slope10", "slope20", "slope30", "slope40", "hills60", "hills150", "mountain", "altai"]
    fig, ax = plt.subplots(1, 2, figsize=(11, 4), constrained_layout=True)
    x = np.arange(len(names))
    ax[0].bar(x - 0.2, [terr[n]["zero_frac_obs"] for n in names], 0.4, label="замеры (ядро, момент)")
    ax[0].bar(x + 0.2, [terr[n]["zero_frac_cores"] for n in names], 0.4, label="ядра (среднее по жизни)")
    ax[0].plot(x + 0.2, [terr[n]["zero_frac_cores_flat"] for n in names], "k_", ms=14, label="ядра, без рельефа")
    ax[0].axhline(GAME["zero_frac_cores"], color="r", ls="--", label="игра, TB-16 (0,77)")
    ax[0].set_xticks(x, names, rotation=45, ha="right")
    ax[0].set_ylabel("доля с |ur| < 0,01 м/с")
    ax[0].legend(fontsize=7)
    a = terr["altai"]["by_stage"]
    st = list(a)
    ax[1].bar(np.arange(len(st)) - 0.25, [a[s]["frac_in"] for s in st], 0.25, label="приток")
    ax[1].bar(np.arange(len(st)), [a[s]["frac_zero"] for s in st], 0.25, label="нуль")
    ax[1].bar(np.arange(len(st)) + 0.25, [a[s]["frac_out"] for s in st], 0.25, label="отток")
    ax[1].set_xticks(np.arange(len(st)), st, rotation=30, ha="right")
    ax[1].set_title("Алтай: замеры по стадии жизни")
    ax[1].legend(fontsize=7)
    fig.savefig(HERE / "ground_inflow_summary.png", dpi=130)


def main() -> None:
    if not DEM_PATH.exists():
        make_dem()
    if "--dem" in sys.argv:
        return
    if "--log" in sys.argv:
        text = Path(sys.argv[sys.argv.index("--log") + 1]).read_text()
    else:
        text = run_test()
    res = parse(text)
    terr = summarize(res)
    alt = terr["altai"]
    n_c = alt["n_cores"]
    cc = alt["causes_cores"]
    causes = [
        {"name": "terrain", "share_of_zero_cores": cc.get("terrain", 0) / max(alt["zero_frac_cores"] * n_c, 1),
         "what": "рельеф: в sample_bubble high = y − y_src (плоскость источника); на склоне точка в 10 м над землёй на кольце 1–2 R "
                 "оказывается ниже плоскости (high < 0 → вклад 0) или высоко над ней (приток там слаб)"},
        {"name": "cancel", "share_of_zero_cores": cc.get("cancel", 0) / max(alt["zero_frac_cores"] * n_c, 1),
         "what": "знак: у ядра за жизнь приток и отток (на плоскости тоже) гасят среднее"},
        {"name": "ring", "share_of_zero_obs": alt["causes_obs"].get("ring", 0) / max(alt["n_obs"] * alt["zero_frac_obs"], 1),
         "what": "кольца 1–2 R_ядра мимо притока (на плоскости он есть при другом ρ)"},
        {"name": "head_high", "share_of_zero_obs": alt["causes_obs"].get("head_high", 0) / max(alt["n_obs"] * alt["zero_frac_obs"], 1),
         "what": "голова высоко, у земли притока нет (не наблюдалось)"},
        {"name": "no_field", "share_of_zero_obs": alt["causes_obs"].get("no_field", 0) / max(alt["n_obs"] * alt["zero_frac_obs"], 1),
         "what": "таблицы/огибающей нет (не наблюдалось)"},
    ]
    out = {
        "task": "TB-18", "game_tb16": GAME, "zero_frac": alt["zero_frac_cores"], "zero_frac_obs": alt["zero_frac_obs"],
        "zero_frac_flat_ground": terr["flat"]["zero_frac_cores"], "zero_frac_cores_after_fix": alt["zero_frac_cores_flat"],
        "median_ur_altai": alt["median_ur_cores"], "median_ur_altai_after_fix": alt["median_ur_cores_flat"],
        "causes": causes, "terrains": terr,
        "recommendation": ("Приток гасит рельеф, а не стадия, радиус колец или таблицы: в sample_bubble высота таблицы high = y − y_src "
                           "(плоскость источника). Правка модели (не метрики): у земли брать высоту таблицы над ЛОКАЛЬНОЙ землёй "
                           "(high_eff = agl при agl ≲ 60 м, плавно к y − y_src к 120 м), число после — ur_flat; метрику (кольца, 10 м) не менять."),
    }
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    figure(terr)
    print("zero_frac(altai, ядра)=%.3f, после правки %.3f; медиана ur %.4f -> %.4f" % (
        out["zero_frac"], out["zero_frac_cores_after_fix"], out["median_ur_altai"], out["median_ur_altai_after_fix"]))


if __name__ == "__main__":
    main()
