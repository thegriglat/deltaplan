#!/bin/bash
# PT-11: умеренные гряды (подъём 80-400 м) - тот же ветер, те же варианты. Под lock cpu.
cd "$(dirname "$0")"
export PT11_SET=mod
for c in ongudai_strong synth_strong ongudai_storm; do
  python3 presence.py plan $c && python3 presence.py run $c && python3 presence.py analyze $c
  echo "presence_mod $c rc=$?"
done
echo MODDONE
