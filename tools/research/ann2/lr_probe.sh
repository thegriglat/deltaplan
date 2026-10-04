#!/bin/bash
# AN-3: пробы lr, 3000 шагов, батч 32, весь набор; итог — out/an3/lr_probe.md
V=/home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python
cd "$(dirname "$0")"
for lr in 5e-4 1e-3 2e-3; do
  $V train.py --run an3_lr_$lr --steps 3000 --batch 32 --lr $lr --val_every 500 --save_every 1000 --fresh || exit 1
done
mkdir -p out/an3
$V - <<'P'
import csv
R="/home/greg/air_nn_data/ann2/runs"
out=["| lr | потеря проверки: шаг 2000 | 2500 | 3000 | обучающая потеря (среднее последних 100 шагов) |","|---|---|---|---|---|"]
for lr in ("5e-4","1e-3","2e-3"):
    r=list(csv.DictReader(open(f"{R}/an3_lr_{lr}/train_log.csv")))
    v={int(x["step"]):float(x["val_loss"]) for x in r if x["val_loss"]}
    tr=[float(x["train_loss"]) for x in r if int(x["step"])>2900]
    out.append(f"| {lr} | {v.get(2000,float('nan')):.4f} | {v.get(2500,float('nan')):.4f} | {v.get(3000,float('nan')):.4f} | {sum(tr)/len(tr):.4f} |")
open("out/an3/lr_probe.md","w").write("\n".join(out)+"\n"); print("\n".join(out))
P
