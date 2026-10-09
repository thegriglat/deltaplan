DELTAPLAN - COMMAND-LINE OPTIONS / ПАРАМЕТРЫ КОМАНДНОЙ СТРОКИ
==============================================================

------------------------------------------------------------------
РУССКИЙ
------------------------------------------------------------------

Обычному пилоту параметры не нужны: игра запускается двойным щелчком.
Параметры пригодятся, чтобы заранее подготовить место, проверить сборку
или сразу открыть нужный полёт.

Как писать. Параметры игры идут после двух дефисов "--". Всё, что до них
("--headless" и т.п.), относится к самому движку Godot.

  Linux:    ./deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595
  Windows:  deltaplan.exe --headless -- --prefetch=53.23797,58.51595
            (в командной строке cmd или PowerShell, в папке с игрой)
  macOS:    Deltaplan.app/Contents/MacOS/Deltaplan --headless -- --prefetch=...

"--headless" - без окна (для подготовки места и проверок). Чтобы лететь,
"--headless" не пишите.

Основные параметры
------------------
--prefetch=ШИРОТА,ДОЛГОТА
    Не лететь, а подготовить данные места (рельеф, покров, реки, объекты
    OpenStreetMap) и сохранить в кеш на этом компьютере. Потом полёт с этой
    точки начинается без ожидания и без интернета. Печатает ход по стадиям,
    путь к кешу и итог: complete (всё есть) или incomplete (чего не хватает).
    Код выхода 0 - место готово, 1 - не готово, 2 - не указаны точки.
    Несколько точек: "--prefetch=53.2,58.5;47.05,11.0" (в кавычках для
    Linux/macOS, иначе ";" понимает оболочка) или повторить параметр.
    Если точка внутри встроенного места, игра возьмёт встроенное; об этом
    будет сказано, кеш всё равно соберётся. Повторный запуск для того же
    места ничего не качает.
    Linux:   ./deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595
    Windows: deltaplan.exe --headless -- --prefetch=53.23797,58.51595

--offline
    Вместе с --prefetch: не ходить в интернет, только проверить, что есть в
    кеше. Недостающее останется недостающим (итог incomplete).
    Linux:   ./deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595 --offline
    Windows: deltaplan.exe --headless -- --prefetch=53.23797,58.51595 --offline

--smoke
    Проверка сборки: игра сама взлетает на автопилоте, делает 300 шагов
    физики и выходит. Код выхода 0 - всё в порядке, 1 - ошибка.
    Linux:   ./deltaplan.x86_64 --headless -- --smoke
    Windows: deltaplan.exe --headless -- --smoke

Параметры полёта (сразу в полёт, без меню)
------------------------------------------
--autostart              сразу в полёт, без меню
--latlon=ШИРОТА,ДОЛГОТА  старт с точки на карте (место соберётся или
                         возьмётся из кеша)
--location=ID --site=ID  встроенное место и старт (например altai, askarovo)
--wing=ID --mass=КГ      крыло и масса пилота
--wind=М/С --from=ГРАДУСЫ|launch   ветер у земли и откуда (launch - встречный)
--temp=ГРАДУСЫ --sky=clear|partly|overcast --hour=ЧАС   погода и время старта
--seed=N                 тот же день воздуха при тех же условиях
--bots=N                 сколько ботов в небе
--air-start[=М[,ВЫСОТА]] старт в воздухе (проверка полёта вдали от склона)
--helmet=none|open|visor|visor_dark   каска в кабине
    Linux:   ./deltaplan.x86_64 -- --autostart --latlon=47.05,11.0 --wind=5
    Windows: deltaplan.exe -- --autostart --latlon=47.05,11.0 --wind=5

Для разработчиков и снимков экрана (пилоту не нужны)
----------------------------------------------------
--screenshot=ПУТЬ --time=С --camera=cockpit|chase|free --perf=С
--pause --settings --about --controls --setup --no-overlay --debug=...
--net-host --net-create --net-join=КОД --net-server=IP:ПОРТ --net-name=ИМЯ
Полный список с пояснениями - в начале файла scripts/game/launch_options.gd
в репозитории игры.

Где что лежит
-------------
Настройки, сохранения, кеш мест (папка locations) и лог (папка logs,
файл godot.log - присылайте его, если что-то не так):
  Linux:    ~/.local/share/Deltaplan/
  Windows:  %APPDATA%\Deltaplan\   (C:\Users\<имя>\AppData\Roaming\Deltaplan)
  macOS:    ~/Library/Application Support/Deltaplan/
При установке через itch рядом с игрой есть ещё папка logs/ с тем же логом.
Кеш мест можно удалять целиком (папка locations) - игра соберёт заново.
Папка configs/ рядом с игрой - настройки физики и мира в JSON; их можно
править без пересборки. (В сборке для macOS настройки встроены в игру.)
Игра ходит в интернет только за данными места: рельеф (Copernicus DEM,
AWS Terrain Tiles), покров (ESA WorldCover), объекты (OpenStreetMap через
Overpass), подложка карты выбора старта. Каждый запрос записывается в лог
строками "HTTP > ..." и "HTTP < ...".

------------------------------------------------------------------
ENGLISH
------------------------------------------------------------------

You do not need any options to play: just start the game. Options help to
prepare a place in advance, check a build, or jump straight into a flight.

Syntax. Game options go after a double dash "--". Anything before it
("--headless" etc.) belongs to the Godot engine itself.

  Linux:    ./deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595
  Windows:  deltaplan.exe --headless -- --prefetch=53.23797,58.51595
            (in cmd or PowerShell, in the game folder)
  macOS:    Deltaplan.app/Contents/MacOS/Deltaplan --headless -- --prefetch=...

"--headless" means no window (for preparing places and checks). Do not use
it when you want to fly.

Main options
------------
--prefetch=LAT,LON
    Do not fly: build the place data (terrain, land cover, rivers,
    OpenStreetMap objects) and keep it in the cache on this computer. A
    flight from that point then starts without waiting or internet. Prints
    the stages, the cache path and the result: complete or incomplete.
    Exit code 0 - place ready, 1 - not ready, 2 - no points given.
    Several points: "--prefetch=53.2,58.5;47.05,11.0" (quote it on
    Linux/macOS, the shell treats ";" specially) or repeat the option.
    A point inside a built-in place is reported (the game uses the built-in
    one) but the cache is still built. A repeat run downloads nothing.
    Linux:   ./deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595
    Windows: deltaplan.exe --headless -- --prefetch=53.23797,58.51595

--offline
    With --prefetch: no network, only report what the cache holds.
    Linux:   ./deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595 --offline
    Windows: deltaplan.exe --headless -- --prefetch=53.23797,58.51595 --offline

--smoke
    Build check: the game takes off on autopilot, runs 300 physics steps
    and exits. Exit code 0 - fine, 1 - failure.
    Linux:   ./deltaplan.x86_64 --headless -- --smoke
    Windows: deltaplan.exe --headless -- --smoke

Flight options (straight into a flight, no menu)
------------------------------------------------
--autostart  --latlon=LAT,LON  --location=ID --site=ID  --wing=ID --mass=KG
--wind=M/S --from=DEG|launch  --temp=C --sky=clear|partly|overcast --hour=H
--seed=N  --bots=N  --air-start[=M[,HEIGHT]]  --helmet=none|open|visor|visor_dark
    Linux:   ./deltaplan.x86_64 -- --autostart --latlon=47.05,11.0 --wind=5
    Windows: deltaplan.exe -- --autostart --latlon=47.05,11.0 --wind=5

For developers and screenshots (not needed to fly)
--------------------------------------------------
--screenshot=PATH --time=S --camera=... --perf=S --pause --settings --about
--controls --setup --no-overlay --debug=... --net-host --net-create
--net-join=CODE --net-server=IP:PORT --net-name=NAME
Full list: top of scripts/game/launch_options.gd in the game repository.

Where things are
----------------
Settings, saves, the place cache (folder locations) and the log (folder
logs, file godot.log - send it if something is wrong):
  Linux:    ~/.local/share/Deltaplan/
  Windows:  %APPDATA%\Deltaplan\   (C:\Users\<name>\AppData\Roaming\Deltaplan)
  macOS:    ~/Library/Application Support/Deltaplan/
An itch install also has a logs/ folder next to the game with the same log.
The place cache (folder locations) can be deleted; the game rebuilds it.
The configs/ folder next to the game holds physics and world settings as
JSON; edit it without rebuilding. (The macOS build has them built in.)
The game uses the internet only for place data: terrain (Copernicus DEM,
AWS Terrain Tiles), land cover (ESA WorldCover), objects (OpenStreetMap via
Overpass) and the start-picker map background. Every request is written to
the log as "HTTP > ..." and "HTTP < ..." lines.
