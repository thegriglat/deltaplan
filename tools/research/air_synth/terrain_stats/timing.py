"""Цена одного рельефа на одном ядре: запускать как  taskset -c 7 env OMP_NUM_THREADS=1 .venv/bin/python timing.py
n=384 (без запаса по краям) и n=512 (рабочая сетка, обрезка до 384²); 80 шагов dt=5e4 лет, тип «Онгудай»."""
import time
import run_fastscape as R, fastscape_gen as g
g.gen(dict(R.TYPES["ongudai"], n=384, T=5e4), 0)          # прогрев numba
for n in (384, 512):
    t = time.time(); g.gen(dict(R.TYPES["ongudai"], n=n), 1); print(n, f"{time.time() - t:.1f} s", flush=True)
