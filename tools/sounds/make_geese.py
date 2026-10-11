#!/usr/bin/env python3
"""Луп гогота летящей стаи для пасхалки «Клин гусей» (К14).

  python3 -I tools/sounds/make_geese.py <preview.ogg>
Источник: freesound 568803 (TRP, CC0), HQ-превью. Фрагмент 106–124 с (стая над головой, ровная громкость),
ФВЧ 150 Гц, моно, равномощный кроссфейд 2 с (audiolib.make_loop), пик −1 dBFS, Ogg Vorbis q6.
Исходник после упаковки не хранится. После — `godot --headless --path . --import` и loop=true в .import.
"""
import os, subprocess, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from audiolib import SR, load, save_ogg, make_loop, norm_peak, loop_seam_report, peak_db

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "sounds", "geese", "geese_flock_loop.ogg")
T0, LOOP_S, XF_S = 106.0, 16.0, 2.0



def highpass(x, hz):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ac", "1", "-ar", str(SR), "-i", "-",
                          "-af", "highpass=f=%d:poles=2" % hz, "-f", "f32le", "-"],
                         input=np.ascontiguousarray(x, dtype=np.float32).tobytes(), check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 1).copy()


x = load(sys.argv[1], mono=True)
seg = x[int(T0 * SR): int((T0 + LOOP_S + XF_S) * SR)]
assert len(seg) == int((LOOP_S + XF_S) * SR), len(x) / SR
y = norm_peak(make_loop(highpass(seg, 150), XF_S), -1.0)
save_ogg(OUT, y, q=6)
print("geese loop: %.1f с, пик %.1f dBFS" % (len(y) / SR, peak_db(y)), loop_seam_report(y))
