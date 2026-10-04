#!/bin/bash
cd "$(dirname "$0")"
exec /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python train.py --run an3_pilot --steps 40000 --batch 32 --lr 2e-3 --ema 0.999 --amp 1 --val_every 1000 --save_every 2000
