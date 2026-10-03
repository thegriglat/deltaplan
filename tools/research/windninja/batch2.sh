# вторая пачка прогонов WindNinja (под замком cpu): растительность, высоты, flat, мелкий DEM 50 м на подмножестве
set -e
cd "$(dirname "$0")"
SUB=askarovo_002,ongudai_007,t_0321_000,t_0336_000,t_0353_003,t_0313_006
python3 run.py --dems d400 --tag trees --veg trees
python3 run.py --dems d400 --tag brush --veg brush
python3 run.py --dems d400 --tag mass --heights 10,20,30,100,150,200 --only $SUB
python3 run.py --dems d400 --tag flat --flat --heights 10,20,30,60,100,150,200 --only $SUB
python3 run.py --dems d50 --tag mass --only $SUB
