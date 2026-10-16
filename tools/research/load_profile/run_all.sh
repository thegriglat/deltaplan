#!/bin/bash
# Все замеры: Онгудай и точка −27.7176,−48.7799 (холодно/тёпло/тёпло-2). Под замком GPU.
cd "$(dirname "$0")"
./run_pair.sh ong --location=ongudai
./run_pair.sh pt --latlon=-27.7176,-48.7799
