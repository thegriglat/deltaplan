"""А1.3 (ревью): перепрогон проб приёмки А1 на нынешнем air.py (режим «after» probe.py), выход — сюда
(review/out/<проба>_after.json), чтобы не трогать числа исполнителя в a1/out/.

  PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
  flock /tmp/heat_ca_gpu.lock $PY run_probes.py prt saddle const ongudai
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import probe as P  # noqa: E402

P.OUT = HERE / "out"
P.OUT.mkdir(exist_ok=True)
P.AFTER = True

for what in sys.argv[1:]:
    print(f"==== {what}", flush=True)
    dict(saddle=P.probe_saddle, const=P.probe_const, heat=P.probe_heat, prt=P.probe_prt, ongudai=P.probe_ongudai)[what]()
