#!/usr/bin/env python3
"""Таблица K̄ шаблона для «между» (TB-8, TB4 v2): bubble.kbar на сетке z_l × w* → rust/dp-air/src/terms/thermal/bubble_kbar.rs.

K̄(z_l, w*) = средний по жизни и по столбу поток вверх пузыря from_strength(w0 = K_ALLEN·w*), делённый на w0, м²
(bubble.kbar; в игре сила термика w0 = K_ALLEN·w*, K_ALLEN = e·0,4575 — thermal_air/mod.rs). tau = среднее
grow_s + mature_s ThermalCfg::default (середины [120; 240] и [300; 720] = 180 + 510 = 690 с). Env(zi = z_l, ветра нет).

Счёт долгий (≈ 420 узлов × 10…40 с): запускать под замком, фоном:  .dpcli/dpcli lock cpu tb8k -- python3 tools/research/thermal_bubble/kbar_table.py
Промежуточные значения — out/kbar_table.partial* (не коммитятся); перезапуск продолжает с места остановки.
Параллельно: `--part k/n` (k = 0…n-1) в n запусках, затем `--assemble`.
Процессов: KBAR_PROCS (по умолчанию 1: замок cpu даёт 100 % ядра).
"""
from __future__ import annotations

import json
import math
import os
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import bubble as bb  # noqa: E402

ZL = [300.0 + 100.0 * i for i in range(28)]          # 300 … 3000 м
WS = [0.5 + 0.25 * i for i in range(15)]             # 0,5 … 4 м/с
TAU = 0.5 * (120.0 + 240.0) + 0.5 * (300.0 + 720.0)  # 690 с
K_ALLEN = 2.718281828 * 0.4575                       # w0 = K_ALLEN·w* (thermal_air/mod.rs)
DEST = here.parents[2] / "rust" / "dp-air" / "src" / "terms" / "thermal" / "bubble_kbar.rs"
PARTIAL = here / "out" / "kbar_table.partial"


def one(args: tuple[int, int]) -> tuple[int, int, float]:
    i, j = args
    zl, ws = ZL[i], WS[j]
    return i, j, float(bb.kbar(zl, TAU, bb.Env(zi=zl), K_ALLEN * ws))


def write_rust(tab: list[list[float]]) -> None:
    rows = []
    for row in tab:
        rows.append("    [" + ", ".join(f"{v:.2f}" for v in row) + "],")
    txt = f"""// сгенерировано tools/research/thermal_bubble/kbar_table.py, не править.
//! K̄ шаблона пузыря для «между» (TB4 v2): средний по жизни и по столбу поток вверх пузыря
//! `bubble.from_strength(w0 = K_ALLEN·w*)`, делённый на `w0`, м², по сетке `z_l` {ZL[0]:.0f}…{ZL[-1]:.0f} м (шаг
//! {ZL[1] - ZL[0]:.0f} м) × `w*` {WS[0]}…{WS[-1]} м/с (шаг {WS[1] - WS[0]}); `tau` = {TAU:.0f} с (середины grow_s + mature_s
//! `ThermalCfg::default`). Вне сетки — край; между узлами — билинейно.

pub const ZL_MIN: f64 = {ZL[0]:.1f};
pub const ZL_STEP: f64 = {ZL[1] - ZL[0]:.1f};
pub const WS_MIN: f64 = {WS[0]:.2f};
pub const WS_STEP: f64 = {WS[1] - WS[0]:.2f};
pub const TAU_S: f64 = {TAU:.1f};
const NZ: usize = {len(ZL)};
const NW: usize = {len(WS)};

/// `TABLE[i][j]` — K̄ при `z_l = ZL_MIN + i·ZL_STEP`, `w* = WS_MIN + j·WS_STEP`.
#[rustfmt::skip]
const TABLE: [[f32; NW]; NZ] = [
{chr(10).join(rows)}
];

/// K̄ шаблона, м², для столба `zl` (м) и `w*` (м/с): билинейно по таблице, вне сетки — значение на краю.
pub fn kbar(zl: f64, wstar: f64) -> f64 {{
    let fz = ((zl - ZL_MIN) / ZL_STEP).clamp(0.0, (NZ - 1) as f64);
    let fw = ((wstar - WS_MIN) / WS_STEP).clamp(0.0, (NW - 1) as f64);
    let (i, j) = ((fz as usize).min(NZ - 2), (fw as usize).min(NW - 2));
    let (tz, tw) = (fz - i as f64, fw - j as f64);
    let t = |a: usize, b: usize| f64::from(TABLE[a][b]);
    t(i, j) * (1.0 - tz) * (1.0 - tw)
        + t(i + 1, j) * tz * (1.0 - tw)
        + t(i, j + 1) * (1.0 - tz) * tw
        + t(i + 1, j + 1) * tz * tw
}}
"""
    tmp = DEST.with_suffix(".rs.tmp")
    tmp.write_text(txt)
    os.replace(tmp, DEST)


def load_done() -> dict[str, float]:
    done: dict[str, float] = {}
    for p in sorted(PARTIAL.parent.glob(PARTIAL.name + "*")):
        done.update(json.loads(p.read_text()))
    return done


def main() -> int:
    """Без аргументов — счёт и сборка файла; `--part k/n` — только счёт доли k из n (параллельные запуски, у каждой
    доли свой файл out/kbar_table.partial.k); `--assemble` — только сборка bubble_kbar.rs из готовых долей."""
    args = sys.argv[1:]
    part = (0, 1)
    if "--part" in args:
        k, n = args[args.index("--part") + 1].split("/")
        part = (int(k), int(n))
    done = load_done()
    todo = [(i, j) for i in range(len(ZL)) for j in range(len(WS)) if f"{i},{j}" not in done]
    # дорогие (большой z_l) первыми — лучше балансировка процессов
    todo.sort(key=lambda p: -p[0])
    todo = todo[part[0] :: part[1]]
    mine = PARTIAL.with_name(PARTIAL.name + (f".{part[0]}" if part[1] > 1 else ""))
    mine_done: dict[str, float] = json.loads(mine.read_text()) if mine.is_file() else {}
    procs = int(os.environ.get("KBAR_PROCS", "1"))
    t0 = time.time()
    if "--assemble" not in args:
        print(f"узлов {len(ZL) * len(WS)}, осталось {len(todo)} (доля {part[0]}/{part[1]}), процессов {procs}", flush=True)
        with Pool(procs) as pool:
            for n, (i, j, v) in enumerate(pool.imap_unordered(one, todo), 1):
                done[f"{i},{j}"] = mine_done[f"{i},{j}"] = v
                if n % 5 == 0 or n == len(todo):
                    mine.write_text(json.dumps(mine_done))
                    print(f"{n}/{len(todo)}  {time.time() - t0:.0f} с  z_l={ZL[i]:.0f} w*={WS[j]}: K̄={v:.1f}", flush=True)
        if part[1] > 1:
            return 0
    done = load_done() | done
    missing = [k for k in (f"{i},{j}" for i in range(len(ZL)) for j in range(len(WS))) if k not in done]
    if missing:
        print(f"не хватает {len(missing)} узлов, файл не пишу", flush=True)
        return 1
    tab = [[done[f"{i},{j}"] for j in range(len(WS))] for i in range(len(ZL))]
    assert all(math.isfinite(v) and v > 0 for r in tab for v in r), "K̄ не положителен"
    write_rust(tab)
    print(f"{DEST}: {len(ZL)}×{len(WS)} узлов", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
