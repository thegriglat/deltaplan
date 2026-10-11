#!/usr/bin/env bash
# Петля MR-2: headless Godot летит ≈3 с горизонтально и шлёт UDP (generic, затем srs) → recv.py пишет jsonl →
# проверка. Успех — строка «loop OK» и код 0.   bash tools/motion_rig/loop_check.sh [секунд на формат]
set -uo pipefail
cd "$(dirname "$0")/../.."
secs="${1:-3}"
tmp=$(mktemp -d)
trap 'kill "${rp1:-}" "${rp2:-}" 2>/dev/null; rm -rf "$tmp"' EXIT

free_port() { python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',0));print(s.getsockname()[1])"; }
pg=$(free_port); ps=$(free_port)

python3 tools/motion_rig/recv.py --port "$pg" --format generic --jsonl "$tmp/generic.jsonl" --quiet --timeout 120 &
rp1=$!
python3 tools/motion_rig/recv.py --port "$ps" --format srs --jsonl "$tmp/srs.jsonl" --quiet --timeout 120 &
rp2=$!
sleep 0.5

XDG_DATA_HOME=$(mktemp -d) timeout 90 godot --headless --path . res://tools/motion_rig/loop_run.tscn -- "$pg" "$ps" "$secs" 2>&1 | grep -E "loop_run|SCRIPT ERROR|ERROR" 
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then echo "loop FAIL: godot завершился с ошибкой"; exit 1; fi
sleep 0.5
kill "$rp1" "$rp2" 2>/dev/null

python3 - "$tmp" "$secs" <<'PY'
import json, sys
tmp, secs = sys.argv[1], float(sys.argv[2])
G = 9.80665
def load(n):
    try:
        return [json.loads(l) for l in open(f"{tmp}/{n}.jsonl")]
    except FileNotFoundError:
        return []
errs = []
GROUND = 1.5  # loop_run.gd GROUND_S
exp = (secs + GROUND) * 60 * 0.8
g, s = load("generic"), load("srs")
if len(g) < exp: errs.append(f"generic: пакетов {len(g)} < {exp:.0f}")
if len(s) < exp: errs.append(f"srs: пакетов {len(s)} < {exp:.0f}")
if g:
    if any(p["format"] != "generic" or p["version"] != 1 for p in g): errs.append("generic: magic/версия")
    seqs = [p["seq"] for p in g]
    if seqs != sorted(seqs) or len(set(seqs)) != len(seqs): errs.append("generic: seq не растёт")
    gnd = [p for p in g if p["on_ground"]]
    air = [p for p in g if not p["on_ground"]]
    if len(gnd) < GROUND * 60 * 0.8: errs.append(f"generic: пакетов на земле {len(gnd)}")
    if len(air) < secs * 60 * 0.8: errs.append(f"generic: пакетов в полёте {len(air)}")
    heave = sum(p["heave"] for p in air) / max(1, len(air))
    if abs(heave - G) > 0.5: errs.append(f"generic: heave среднее в полёте {heave:.3f}")
    hg = sum(p["heave"] for p in gnd) / max(1, len(gnd))
    if abs(hg - G) > 2.0: errs.append(f"generic: heave среднее на земле {hg:.3f}")
    # valid=false — только первый пакет после каждого reset() (два reset: земля, воздух)
    if sum(not p["valid"] for p in g) > 2: errs.append("generic: valid=false в потоке")
    print(f"generic: пакетов {len(g)} (на земле {len(gnd)}), heave среднее: полёт {heave:.3f}, земля {hg:.3f}")
if s:
    if any(p["format"] != "srs" or p["version"] != 102 or p["game"] != "Deltaplan" for p in s): errs.append("srs: заголовок/версия")
    vert = sum(p["vertical_acceleration"] for p in s) / len(s)
    if abs(vert) > 0.5: errs.append(f"srs: vertical среднее {vert:.4f} м/с²")
    print(f"srs: пакетов {len(s)}, vertical среднее {vert:.4f} м/с²")
if errs:
    print("loop FAIL: " + "; ".join(errs)); sys.exit(1)
print("loop OK")
PY
