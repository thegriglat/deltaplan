"""Общее: пути, окружение WindNinja, список мест и случаев."""
import os, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PILOT = HERE.parent / "air_nn_pilot"
sys.path.insert(0, str(PILOT))
OPT = Path.home() / "opt" / "windninja"
ENV = OPT / "mamba" / "envs" / "wn"
WORK = Path.home() / "windninja_work"          # крупное: DEM, выходы WindNinja (вне git)
DATA = Path.home() / "air_nn_data" / "pilot"
DS_MAIN = DATA / "datasets" / "s0-3acd749" / "main"
DS_TERR = DATA / "datasets" / "s0-1c8c322" / "terrain"
P6_INDEX = DATA / "tiles" / "v3" / "index.csv"
OUT = HERE / "out"

PLACES = ["askarovo", "ongudai", "t_0321", "t_0336", "t_0353", "t_0313"]
N_PER_PLACE = 4
EDGE = 5          # клеток у края вне оценки (как у пилота)
RIDGE_PCT = 90


ENV4 = OPT / "mamba" / "envs" / "wnbuild"       # библиотеки сборки 4.0.0
INST4 = OPT / "inst400"                         # установленный WindNinja 4.0.0 (собран из исходников)


def wn_env(ver="3.13"):
    e = dict(os.environ)
    if ver == "4.0":
        e.update(PROJ_DATA=str(ENV4 / "share/proj"), PROJ_LIB=str(ENV4 / "share/proj"), GDAL_DATA=str(ENV4 / "share/gdal"),
                 LD_LIBRARY_PATH=str(ENV4 / "lib"), WINDNINJA_DATA=str(INST4 / "share/windninja"))
    else:
        e.update(PROJ_DATA=str(ENV / "share/proj"), PROJ_LIB=str(ENV / "share/proj"), GDAL_DATA=str(ENV / "share/gdal"),
                 LD_LIBRARY_PATH=str(ENV / "lib"), WINDNINJA_DATA=str(ENV / "share/windninja"))
    return e


def wn_bin(ver="3.13"):
    return str((INST4 if ver == "4.0" else ENV) / "bin/WindNinja_cli")
