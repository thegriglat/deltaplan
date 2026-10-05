# air_onnx — GDExtension AirOnnx (ONNX Runtime, CPU)

Расширение для запуска нейросети ветра (файл `.onnx`, контракт O1) из GDScript. API — контракт **O2**
(`docs/contracts/air-onnx.md`); потребитель — O5 (поле ветра из сети). Выросло из пробника
`native/air_nn_probe` (NN-7а, П5), пробник удалён.

## Состав

| Файл | Что |
|---|---|
| `src/air_onnx.{h,cpp}`, `src/register_types.cpp` | класс `AirOnnx` (RefCounted) |
| `CMakeLists.txt`, `cmake/llvm-mingw.cmake`, `exports.map` | сборка (CMake), тулчейн Windows из Linux, экспорт только `air_onnx_init` |
| `build.sh` | скачивает зависимости и собирает: `./build.sh` (Linux), `windows`, `all`, `clean` |
| `air_onnx.gdextension.in` | шаблон; `build.sh` копирует его в `addons/air_onnx/air_onnx.gdextension` |
| `test/make_dummy_model.py` | модель-пустышка с двумя входами и эталон ORT Python |
| `test/dummy_two_inputs.onnx` (5 КБ), `test/dummy_two_inputs_ref.bin` (1 КБ) | в git |
| `../../tests/air_onnx/test_air_onnx.gd` | headless-тест |

Не в git: `addons/air_onnx/bin/` и `addons/air_onnx/air_onnx.gdextension` (результат сборки), здесь
`build/`, зависимости — `$DEPS_DIR` (по умолчанию `~/.cache/deltaplan-air-onnx-deps`, общий для всех
рабочих копий; ~1.3 ГБ с распакованным llvm-mingw и ORT win). Каталог `native/air_onnx/` скрыт от
редактора (`.gdignore`); файлы теста читаются через `FileAccess` и в экспорт не попадают.

## API (O2 v1)

```gdscript
if ClassDB.class_exists("AirOnnx"):          # нет класса — расширение не собрано (instantiate без проверки даёт ошибку в лог)
	var nn: Object = ClassDB.instantiate("AirOnnx")
	nn.set_intra_op_threads(4)               # по умолчанию 4; действует на следующий load()
	var rc: int = nn.load("res://…/model.onnx")   # 0 ок; 1 файл; 2 ORT не создал сессию; 3 нет входов/выходов; 4 нет библиотеки ORT
	nn.input_names()                         # ["maps", "nums"]; output_names() — ["out"]
	nn.input_shape("maps")                   # [1, C, 96, 96] из модели; неизвестное имя — []
	nn.metadata()                            # custom metadata_map (строка → строка); у сырого файла пилота — {}
	var y: Dictionary = nn.run({"maps": maps, "nums": nums})   # {"out": PackedFloat32Array}; ошибка — {} и nn.last_error()
```

- Модель читается через `FileAccess` (`res://`, `user://`, абсолютный путь) и передаётся в ORT из памяти.
- Входы — без копии (тензор ORT поверх `PackedFloat32Array`), выходы — по одной копии `memcpy`.
- Ошибки `run`: нет входа, лишний ключ, не `PackedFloat32Array`, длина ≠ произведению формы, ошибка ORT.
  Одно динамическое измерение формы (−1) выводится из длины (O1 — формы статические).
- `run` можно звать из рабочего потока (`WorkerThreadPool`); одну сессию — не из двух потоков сразу.

Замер (Xeon E5-2666 v3, 20 потоков ЦП; сеть первого пилота `2026-10-02_pilot/main/model.onnx`,
maps [1, 4, 96, 96] → out [1, 91, 96, 96]): `load` 132 / 86 мс, `run` 46.2 / 18.1 мс (1 / 4 потока ORT,
среднее из 10).

## Сборка и тест

```bash
native/air_onnx/build.sh all              # Linux + Windows (тяжёлые прогоны агентов — под dp lock cpu)
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import   # регистрирует расширение (.godot/extension_list.cfg)
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tests/run_tests.tscn -- --filter=air_onnx
native/air_onnx/build.sh clean            # убрать собранное (и запись в .godot/extension_list.cfg)
```

Без сборки тест пишет `skip air_onnx::…: расширение не собрано` и проходит. Если сборка свежее импорта
(расширение ещё не в `extension_list.cfg`), тест грузит его сам (`GDExtensionManager.load_extension`).
Пересоздать модель и эталон:
`CUDA_VISIBLE_DEVICES= /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python -B native/air_onnx/test/make_dummy_model.py`
(torch, onnx, onnxruntime 1.30.0). Совпадение с эталоном — max|Δ| = 0 при 1 и 4 потоках (допуск 1e-5).

Версии (закреплены в `build.sh`): ONNX Runtime **1.30.0** (готовые бинарники GitHub, та же версия, что
в venv пилота), godot-cpp **10.0.0-stable** (`GODOTCPP_API_VERSION=4.7`), llvm-mingw **20260922** (UCRT),
VC++ runtime **14.44.35211** (официальный Visual Studio 2022 `VC\Redist`, sha256 каждой DLL в `build.sh`).

## Как расширение попадает в игру

**Автоматическая регистрация `.gdextension`, но файл `.gdextension` создаёт только сборка.**

- `addons/air_onnx/air_onnx.gdextension` не хранится в git, его пишет `build.sh` рядом с `bin/`. Есть
  файл — импорт редактора вносит его в `.godot/extension_list.cfg`, Godot грузит расширение при старте,
  а экспорт кладёт библиотеку расширения и всё из `[dependencies]` (`""` — рядом с исполняемым файлом).
  Нет файла (свежая копия без сборки) — Godot о расширении не знает: ни ошибок при старте, ни в тестах;
  `ClassDB.class_exists("AirOnnx") == false`, O5 работает на упрощённой модели.
- Почему не `.gdextension` в git: без собранных библиотек Godot печатал бы 3 ошибки
  («GDExtension dynamic library not found…») при каждом запуске игры и каждого headless-теста.
- Почему не ручная `load_extension` из игры: экспорт тогда не знает о библиотеках — их пришлось бы
  копировать скриптом сборки, а путь к `.gdextension` в экспорте подбирать вручную. Штатный путь Godot
  (как у `addons/debug_draw_3d`) проверен на экспорте (ниже).
- Подвох: импорт сам **не убирает** устаревшую запись из `extension_list.cfg`, если `.gdextension`
  удалили (3 ошибки на каждом старте). Поэтому — `build.sh clean`, а не `rm -rf bin`.
- Первый импорт проекта, в котором появился новый `.gdextension`, у Godot 4.7.2 завершается
  SIGSEGV на выходе (так же и с одним `debug_draw_3d` в пустом проекте — не наше); список расширений
  при этом уже записан, повторный импорт и запуски — без ошибок.
- `tools/build.sh linux|windows|all`: нет собранного расширения для платформы — собирает
  (`native/air_onnx/build.sh <платформа>`), затем импорт и экспорт, затем проверяет, что файлы
  расширения лежат рядом с исполняемым файлом. `AIR_ONNX=0 tools/build.sh …` — не собирать и не проверять.

Проверено (03.10): `tools/build.sh linux` и `windows` (экспорт `--headless`) кладут рядом с exe
`libair_onnx.so` + `libonnxruntime.so.1` / `air_onnx.dll` + `onnxruntime.dll` + 4 DLL VC++ runtime;
smoke-запуск Linux-сборки — OK. Отдельный мини-проект, экспортированный тем же путём: в экспортированной
Linux-сборке `AirOnnx` есть, `load` = 0, `run` отдаёт оба выхода.

## Как ORT подключён и почему так

С ORT **не компонуемся**: `libonnxruntime.so.1` / `onnxruntime.dll` лежит рядом с расширением и грузится
в рантайме из каталога самой библиотеки расширения (в экспорте — каталог exe), из неё берётся только
C-символ `OrtGetApiBase`; C++-обёртка `onnxruntime_cxx_api.h` — заголовочная (`ORT_API_MANUAL_INIT`).
Нет библиотеки ORT или её зависимостей — само расширение грузится, `load()` возвращает 4 с причиной.

- **Linux — `dlmopen(LM_ID_NEWLM)`** (отдельное пространство имён компоновщика). Причина (найдена в gdb
  на пробнике): `addons/debug_draw_3d` (libdd3d) содержит статическую libstdc++ и экспортирует её символы
  как `STB_GNU_UNIQUE` (`std::collate<char>::id` и др.). Такие символы глобальны на процесс; обычный
  `dlopen` (и даже `RTLD_DEEPBIND`) связывает `libonnxruntime.so` с копиями `locale::id` из libdd3d —
  SIGSEGV при первом `Ort::Session`. В отдельном пространстве имён у ORT своя libstdc++/libc. Цена: вторая
  копия libc/libstdc++ в памяти, отдельная куча (данные через границу только копируем).
- Расширение собрано с `-static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL` и `exports.map`:
  зависит только от libc/libm и экспортирует один символ `air_onnx_init` (чтобы не стать вторым libdd3d).
- Глобальных `godot::String` в коде нет: их конструктор зовёт API Godot до инициализации godot-cpp —
  SIGSEGV при загрузке библиотеки (наступили при переносе). Состояние ORT создаётся при первом `load`.
- **Windows — `LoadLibraryExW(<каталог расширения>\onnxruntime.dll, LOAD_WITH_ALTERED_SEARCH_PATH)`**:
  зависимости DLL ищутся сначала в её каталоге. ORT зовём только через C ABI, поэтому MSVC-сборка ORT
  работает с расширением, собранным llvm-mingw, — импорт-библиотека не нужна.

## Windows

Собирается из Linux (`build.sh windows`). Импорты (objdump, 03.10):

| Файл | Импорты |
|---|---|
| `air_onnx.dll` (0.74 МБ) | `KERNEL32` + UCRT `api-ms-win-crt-*` (есть в Win10+); экспорт `air_onnx_init` |
| `onnxruntime.dll` (16.5 МБ, 1.30.0) | `KERNEL32`, `ADVAPI32`, `SETUPAPI`, `dbghelp`, `dxgi`, UCRT + **`MSVCP140`, `MSVCP140_1`, `VCRUNTIME140`, `VCRUNTIME140_1`** |
| `msvcp140*.dll`, `vcruntime140*.dll` | `KERNEL32`, UCRT и друг друга |

**VC++ runtime — app-local** (решение ON-2): 4 DLL (`msvcp140.dll`, `msvcp140_1.dll`, `vcruntime140.dll`,
`vcruntime140_1.dll`, 14.44.35211, ~0.8 МБ) лежат рядом с `onnxruntime.dll` и в экспорте — рядом с
`deltaplan.exe` (они в `[dependencies]` `.gdextension`). Почему не требование «поставьте VC++ Redistributable»:
пилоту не нужно ничего ставить; и известная ловушка — ORT, собранный свежим MSVC, падает в `std::mutex`
со **старым** `msvcp140.dll` из системы (VS 17.10+, constexpr-конструктор mutex), а app-local DLL свежие.
Microsoft разрешает распространять эти DLL вместе с программой (redist-список Visual Studio).
Источник — **официальный распространяемый пакет Visual Studio 2022**: `VC\Redist\MSVC\<версия>\x64\Microsoft.VC143.CRT`
(колесо PyPI больше не используется). Автор принимает лицензию бесплатной Visual Studio Community / Build Tools
(Microsoft Software License Terms, раздел Distributable Code — `licenses/msvc-runtime.txt`) и раздаёт эти DLL с игрой.
Сборка Windows требует явного согласия и каталога-источника:

```
# Linux: Redist из пакетов VS Build Tools 2022 через msvc-wine (скачивает только Redist, ~3 МБ, вне репозитория):
export MSVC_ACCEPT_LICENSE=yes
MSVC_REDIST_DIR=$(tools/release/fetch_msvc_redist.sh | tail -1) native/air_onnx/build.sh windows
# или с машины с VS 2022: скопировать …\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT и указать MSVC_REDIST_DIR
```

Без `MSVC_ACCEPT_LICENSE=yes` или `MSVC_REDIST_DIR` `build.sh windows` останавливается с пояснением до компиляции.
Версия 14.44.35211 и sha256 каждой из 4 DLL закреплены в `build.sh`; другая версия Redist — отказ с показом фактического
хэша (обновление — осознанное: версия и хэши в `build.sh` и строка в `ASSETS.md`). Уже собранные `bin/windows/*.dll`
побайтно те же (хэши сняты с них). Ни `deltaplan.exe`, ни `libdd3d` msvcp/vcruntime не импортируют — в процессе это будут именно наши DLL. Если DLL всё же не загрузятся — `load()` = 4, текст ошибки подсказывает про VC++ runtime, игра идёт на упрощённой модели.

**Не проверено**: запуск на Windows — wine нет. Проверка — на Windows-машине (тест `--filter=air_onnx`
из проекта или запуск сборки) или в CI (GitHub Actions `windows-latest`).

## macOS (только способ, не собиралось)

В `.gdextension` библиотек macOS нет: экспорт macOS проходит с предупреждением «библиотека не найдена»,
а `extension_list.cfg` в pck его перечисляет — на Mac при старте ожидается ошибка загрузки расширения в логе (без падения, не проверено; игра на упрощённой модели).
Чтобы собрать: ORT даёт готовый `onnxruntime-osx-arm64-<ver>.tgz` (x86_64 в релизах 1.30 нет —
Intel-Mac: собирать ORT из исходников или не поддерживать). Сборка — на macOS runner (`macos-14`, arm64):
тот же CMake, `-DCMAKE_OSX_ARCHITECTURES=arm64`, загрузка `dlopen` (двухуровневое пространство имён
macOS — конфликта libdd3d не ожидается); `libair_onnx.dylib` + `libonnxruntime.dylib` рядом,
`install_name_tool -id @rpath/…`, строки `macos.arm64` в `[libraries]`/`[dependencies]`, подпись
`codesign` (ad-hoc `-s -` для своих; для раздачи без предупреждений Gatekeeper — Developer ID + нотаризация).

## Размеры

| Файл | Размер |
|---|---|
| `bin/linux/libair_onnx.so` | 0.67 МБ |
| `bin/linux/libonnxruntime.so.1` (ORT 1.30.0 CPU) | 29.0 МБ |
| `bin/windows/air_onnx.dll` | 0.74 МБ |
| `bin/windows/onnxruntime.dll` (ORT 1.30.0 CPU) | 16.5 МБ |
| `bin/windows/` VC++ runtime, 4 DLL | 0.77 МБ |
