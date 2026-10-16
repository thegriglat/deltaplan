"""Перезапуск скрипта в .venv рядом (numpy, Pillow…), если системный python3 без них; .venv создаёт setup_env.sh."""
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def ensure(*mods):
    try:
        for m in mods:
            __import__(m)
        return
    except ImportError:
        pass
    py = HERE / ".venv/bin/python"
    if Path(sys.executable).resolve() == py.resolve():
        raise SystemExit("нет модулей в .venv: " + ", ".join(mods))
    if not py.exists():
        subprocess.run(["sh", str(HERE / "setup_env.sh")], check=True)
    os.execv(str(py), [str(py)] + sys.argv)
