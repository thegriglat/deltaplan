#!/bin/bash
# Упаковка одного региона целиком (OT-2): cover → pack → finalize → stats → summary.json.
#   tools/osm_tiles/pack_region.sh <pbf> <poly> <region> <out> [--threads N]
# <out> пересоздаётся с нуля: cover.txt, frag/ (фрагменты O4 и <region>.pack.json), list.txt,
# tiles/v1/<j>/<i>.dpt, finalize.jsonl, stats.json (O6, --zstd-per-stream), summary.json, *.log.
# Загрузка ядер finalize — (user+sys)/real по bash time (у pack — из его pack.json).
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <pbf> <poly> <region> <out> [--threads N]" >&2; exit 2; }
PBF=$(readlink -f "$1"); POLY=$(readlink -f "$2"); REGION=$3; OUT=$4; shift 4
THREADS=()
[ "${1:-}" = "--threads" ] && THREADS=(--threads "$2")
HERE=$(dirname "$(readlink -f "$0")")
CRATE=$HERE/packer
(cd "$CRATE" && cargo build --release --quiet)
B=$CRATE/target/release/osmtiles

rm -rf "$OUT"
mkdir -p "$OUT"
OUT=$(readlink -f "$OUT")
TIMEFORMAT='%R %U %S'
T0=$(date +%s.%N)

{ time "$B" cover --poly "$POLY" > "$OUT/cover.txt"; } 2> "$OUT/cover.time"
{ time "$B" pack --input "$PBF" --region "$REGION" --poly "$POLY" --frag-dir "$OUT/frag" "${THREADS[@]}" \
    2> "$OUT/pack.log"; } 2> "$OUT/pack.time"
python3 - "$OUT/frag/$REGION.pack.json" "$REGION" > "$OUT/list.txt" <<'EOF'
import json, sys
for j, i, _ in json.load(open(sys.argv[1]))["tiles"]:
    print(j, i, sys.argv[2])
EOF
{ time "$B" finalize --frag-dir "$OUT/frag" --out "$OUT/tiles" --list "$OUT/list.txt" \
    --report "$OUT/finalize.jsonl" "${THREADS[@]}" 2> "$OUT/finalize.log"; } 2> "$OUT/finalize.time"
{ time "$B" stats --tiles "$OUT/tiles" --zstd-per-stream "${THREADS[@]}" > "$OUT/stats.json"; } 2> "$OUT/stats.time"
T1=$(date +%s.%N)

python3 - "$OUT" "$REGION" "$T0" "$T1" <<'EOF'
import json, re, sys
from pathlib import Path
out, region, t0, t1 = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3]), float(sys.argv[4])

def tm(name):
    real, user, sys_ = (float(x) for x in (out / f"{name}.time").read_text().split()[-3:])
    return {"s": round(real, 3), "cores_avg": round((user + sys_) / real, 2) if real > 0 else 0.0}

pk = json.loads((out / "frag" / f"{region}.pack.json").read_text())
fin_rss = re.findall(r"пик RSS (\d+) МБ", (out / "finalize.log").read_text())
st = json.loads((out / "stats.json").read_text())
sizes = [r["bytes"] for r in map(json.loads, (out / "finalize.jsonl").read_text().splitlines()) if r["bytes"]]
stages = {"cover": tm("cover"), "pack": {**tm("pack"), "stages": {
    k: {"s": pk["seconds"][k], "cores_avg": pk["cpu_cores_avg"][k]} for k in pk["seconds"]}},
          "finalize": tm("finalize"), "stats": tm("stats")}
s = {
    "region": region,
    "seconds_total": round(t1 - t0, 3),
    "pack_s": stages["pack"]["s"],
    "finalize_s": stages["finalize"]["s"],
    "pack_encode_cores_avg": pk["cpu_cores_avg"].get("encode", 0.0),
    "finalize_cores_avg": stages["finalize"]["cores_avg"],
    "peak_rss_mb": max([pk["peak_rss_mb"]] + [float(x) for x in fin_rss]),
    "pack_peak_rss_mb": pk["peak_rss_mb"],
    "input_bytes": pk["input_bytes"],
    "osm_timestamp": pk["osm_timestamp"],
    "cover_tiles": len((out / "cover.txt").read_text().split("\n")) - 1,
    "frag_tiles": len(pk["tiles"]),
    "tiles": st["n_tiles"],
    "bytes_total": st["file_bytes_total"],
    "max_tile_bytes": max(sizes) if sizes else 0,
    "stages": stages,
}
(out / "summary.json").write_text(json.dumps(s, ensure_ascii=False, indent=1))
print(json.dumps({k: v for k, v in s.items() if k != "stages"}, ensure_ascii=False))
EOF
