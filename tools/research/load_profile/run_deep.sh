#!/bin/bash
cd "$(dirname "$0")"
./run_warm.sh ong --location=ongudai deep
./run_warm.sh pt --latlon=-27.7176,-48.7799 deep
