#!/usr/bin/env bash
# CPU по потокам процесса Godot во время xc_prof (perf в песочнице недоступен: perf_event_paranoid=3).
# tools/profile/threads.sh <имя> <аргументы xc_prof...>  ->  build/rw15b/<имя>.threads.json {comm: cpu_s}
set -euo pipefail
cd "$(dirname "$0")/../.."
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
name="$1"; shift
mkdir -p build/rw15b
godot --headless --path . res://tools/profile/xc_prof.tscn -- --synthetic --seed=1 --km=30 --out=build/rw15b/$name.json "$@" > build/rw15b/$name.log 2>&1 &
gpid=$!
python3 - "$gpid" "build/rw15b/$name.threads.json" <<'PY' &
import os, sys, time, json
pid = sys.argv[1]; out = sys.argv[2]
tick = os.sysconf('SC_CLK_TCK')
last = {}
while os.path.exists(f'/proc/{pid}'):
    cur = {}
    try:
        for t in os.listdir(f'/proc/{pid}/task'):
            try:
                s = open(f'/proc/{pid}/task/{t}/stat').read()
            except OSError:
                continue
            comm = s[s.index('(') + 1:s.rindex(')')]
            f = s[s.rindex(')') + 2:].split()
            cur[t] = (comm, (int(f[11]) + int(f[12])) / tick)
    except OSError:
        pass
    last.update(cur)
    time.sleep(0.5)
agg = {}
for comm, c in last.values():
    agg[comm] = round(agg.get(comm, 0.0) + c, 2)
json.dump({'by_comm': dict(sorted(agg.items(), key=lambda kv: -kv[1])),
           'n_threads': len(last),
           'top_tids': sorted(([c, round(v, 2), t] for t, (c, v) in last.items()), key=lambda r: -r[1])[:12]},
          open(out, 'w'), indent=1)
PY
wait
