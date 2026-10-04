#!/bin/bash
# AN-4: основной прогон — разложенная голова, N/Fr случая, только механические случаи; параметры AN-3, ранняя остановка.
cd "$(dirname "$0")"
exec /home/greg/deltaplan-ann2-AN-4/tools/research/air_nn_pilot/.venv/bin/python train.py --run an4 --steps 40000 --batch 32 --lr 2e-3 --ema 0.999 --amp 1 --val_every 1000 --save_every 2000 --patience 15
