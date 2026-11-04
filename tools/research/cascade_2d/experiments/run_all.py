#!/usr/bin/env python3
"""CSD-4: вся пачка одним скриптом. Запуск (под замком cpu: время спуска и опроса измеряется внутри):
    .dpcli/dpcli lock cpu csd4-run -- tools/research/cascade_2d/py tools/research/cascade_2d/experiments/run_all.py [--skip-run]
Шаги: P200 без верхней строки; спуски C0..C4 x старт 400/200 x V0,V1,V2,V3,V3h (сид 1); V3h сиды 2..8 (старт 400);
опрос 10000 точек (V0..V3h, старт 400); 8 потоков (побитное сравнение); 10 повторов времени V3; метрики M1; E_u по уровням;
вердикт K0-K5; таблицы; разбор механизма; картинки. `--skip-run` - только пересчёт после спусков.
Переменная CASCADE_WALL_ZERO=1 включает прежнее правило наклона у стенки (серия «до исправления»)."""
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.abspath(os.path.join(HERE, ".."))
R = os.path.abspath(os.path.join(CD, "..", "..", ".."))
B = os.path.join(CD, "cascade_rs/target/release/cascade")
PY = os.path.join(CD, "py")
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d"))
OUT = os.path.join(CD, "out"); SCR = os.environ.get("CSD4_SCRATCH", "/tmp/csd4_scratch")
CASES = ["C0", "C1", "C2", "C3", "C4"]; VARS = ["V0", "V1", "V2", "V3", "V3h"]; SEEDS = range(2, 9)

def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, **kw)

def py(script, *a):
    sh([PY, os.path.join(HERE, script), *a])

def run_cascade():
    py("trim_p200.py")
    os.makedirs(f"{OUT}/timing", exist_ok=True)
    for C in CASES:
        F = f"{DATA}/fields/{C}"
        for P in (400, 200):
            pf = f"{F}/picard_none_d{P}.json" if P == 400 else f"{DATA}/fields_p200t/{C}/picard_none_d200.json"
            for V in VARS:
                sh([B, "descend", "--parent", pf, "--case", C, "--variant", V, "--seed", "1", "--threads", "1", "--out-dir", F])
        for V in VARS:
            sh([B, "query", "--parent", f"{F}/picard_none_d400.json", "--case", C, "--variant", V, "--seed", "1",
                "--points", "10000", "--out-dir", F, "--runs-dir", f"{OUT}/runs"])
        for S in SEEDS:
            d = f"{DATA}/fields_seeds/s{S}/{C}"; os.makedirs(d, exist_ok=True)
            sh([B, "descend", "--parent", f"{F}/picard_none_d400.json", "--case", C, "--variant", "V3h", "--seed", str(S),
                "--threads", "1", "--out-dir", d, "--runs-dir", f"{SCR}/runs_s{S}"])
        d = f"{DATA}/fields_t8/{C}"; os.makedirs(d, exist_ok=True)
        for V in VARS:
            sh([B, "descend", "--parent", f"{F}/picard_none_d400.json", "--case", C, "--variant", V, "--seed", "1",
                "--threads", "8", "--out-dir", d, "--runs-dir", f"{SCR}/runs_t8"])
        with open(f"{OUT}/timing/{C}_V3_from400.txt", "w") as f:
            for _ in range(10):
                sh([B, "descend", "--parent", f"{F}/picard_none_d400.json", "--case", C, "--variant", "V3", "--threads", "1",
                    "--out-dir", f"{SCR}/t_{C}", "--runs-dir", f"{SCR}/runs_t"], stdout=f)

def post():
    for C in CASES:
        dirs = [f"{DATA}/fields/{C}"] + [f"{DATA}/fields_seeds/s{S}/{C}" for S in SEEDS]
        sh([PY, os.path.join(CD, "metrics/metrics.py"), "--case", C, "--fields", *dirs])
    for s in ("levels.py", "analyze.py", "tables.py", "diag_bands.py", "diag_profile.py", "diag_hash.py", "diag_wall.py", "figures.py"):
        if os.path.exists(os.path.join(HERE, s)):
            py(s)
    for C in CASES:
        sh([PY, os.path.join(CD, "metrics/plots.py"), "--case", C, "--field", f"{DATA}/fields/{C}/cascade_V3_d25_from400.json", "--vs", "B400"])

if __name__ == "__main__":
    if "--skip-run" not in sys.argv:
        run_cascade()
    post()
