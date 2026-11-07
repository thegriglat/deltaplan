"""Проверка сходимости шага 2: сетка частиц 3 м вместо 4 м (σ = 4,5 м)."""
import json
from step2 import run
o = run(dx=3.0, dz=3.0, zspan=51.0)
o['sigma_theory'] = 0.1897 * (o['dU'] / 2) / o['delta']
for k in ('spec_k', 'spec_w'): o.pop(k)
json.dump(o, open('out/step2b_raw.json', 'w'))
