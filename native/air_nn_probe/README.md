# air_nn_probe — пробный стык ONNX Runtime ↔ Godot (NN-7а)

**Пробник, не финальный API N5.** Задача — снять риск рантайма до NN-T5/NN-7: GDExtension на
godot-cpp, который грузит ONNX-модель и гоняет её через ONNX Runtime (CPU) из GDScript.
Контракт — `docs/contracts/air-nn.md`, П5 v1.

## Состав

| Файл | Что |
|---|---|
| `src/air_nn_probe.{h,cpp}`, `src/register_types.cpp` | класс `AirNnProbe` (RefCounted) |
| `CMakeLists.txt`, `cmake/llvm-mingw.cmake` | сборка (CMake, без scons), тулчейн Windows из Linux |
| `build.sh` | скачивает зависимости и собирает: `./build.sh` (Linux), `./build.sh windows`, `./build.sh all` |
| `air_nn_probe.gdextension.in` | копируется в `bin/air_nn_probe.gdextension` |
| `make_dummy_model.py` | модель-пустышка `dummy_conv.onnx` и эталон `dummy_ref.bin` (ORT Python) |
| `dummy_conv.onnx` (13 КБ), `dummy_ref.bin` (72 КБ) | модель и эталонный выход — в git |
| `../../tests/air_nn/test_air_nn_probe.gd` | headless-тест |

Не в git (`.gitignore` здесь): `third_party/` — зависимости (~1.3 ГБ с распакованным llvm-mingw и
ORT win с .pdb), `build/` — сборка, `bin/` — результат. Каталог скрыт от редактора Godot (`.gdignore`):
расширение не регистрируется автоматически, тест грузит его сам через `GDExtensionManager.load_extension`.

## API (П5 v1)

```gdscript
var p: Object = ClassDB.instantiate("AirNnProbe")
p.set_intra_op_threads(4)                 # сверх П5 v1: потоки ORT, действует на следующий load(); по умолчанию 1
var rc: int = p.load("res://…/model.onnx") # 0 — успех; 1 файл, 2 ORT не создал сессию, 3 нет входа/выхода, 4 нет библиотеки ORT
var y: PackedFloat32Array = p.run(x, PackedInt64Array([1, C, H, W]))  # пусто — ошибка, см. p.last_error()
var shape: PackedInt64Array = p.output_shape()
```

Модель читается через `FileAccess` (работают `res://`, `user://`) и передаётся в ORT из памяти.
Вход — без копии (тензор ORT поверх `PackedFloat32Array`), выход — одна копия `memcpy`.

## Сборка и тест

```bash
cd native/air_nn_probe
./build.sh all            # Linux + Windows; зависимости в third_party/ (DEPS_DIR=… — другой каталог)
cd ../..
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import   # один раз в свежей копии
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tests/run_tests.tscn -- --filter=air_nn_probe
```

Без собранного `bin/` тест пишет `skip air_nn_probe: расширение не собрано` и проходит.
Пересоздать модель и эталон: `/home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python make_dummy_model.py`
(нужны torch, onnx, onnxruntime 1.30.0).

Версии (закреплены в `build.sh`): ONNX Runtime **1.30.0** (готовые бинарники GitHub, та же версия, что
в venv пилота), godot-cpp **10.0.0-stable** (v10 версируется отдельно от Godot; `GODOTCPP_API_VERSION=4.7` —
встроенный `extension_api-4-7.json`, у старой ветки godot-cpp 4.5 генератор не переваривает API 4.7),
llvm-mingw **20260922** (UCRT).

## Как ORT подключён и почему так

С ORT **не компонуемся**: `libonnxruntime.so.1` / `onnxruntime.dll` лежит рядом с расширением и грузится
в рантайме, из неё берётся только C-символ `OrtGetApiBase`; C++-обёртка `onnxruntime_cxx_api.h` —
заголовочная (`ORT_API_MANUAL_INIT` + `Ort::InitApi`).

- **Linux — `dlmopen(LM_ID_NEWLM)`** (отдельное пространство имён компоновщика). Причина найдена в gdb:
  `addons/debug_draw_3d` (libdd3d) содержит статическую libstdc++ и экспортирует её символы как
  `STB_GNU_UNIQUE` (`std::collate<char>::id` и др.). Такие символы глобальны на процесс; обычный
  `dlopen` (и даже `RTLD_DEEPBIND`) связывает `libonnxruntime.so` с копиями `locale::id` из libdd3d —
  SIGSEGV при первом `Ort::Session` (виртуальный вызов попадает в чужую грань `codecvt`). В отдельном
  пространстве имён у ORT своя libstdc++/libc — конфликта нет. Цена: вторая копия libc/libstdc++ в
  памяти, отдельная куча (данные через границу только копируем — так и сделано).
- Само расширение собрано с `-static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL` — не зависит от
  libstdc++ системы и не экспортирует её символы (чтобы не стать вторым libdd3d).
- **Windows — `LoadLibraryExW(<каталог расширения>\onnxruntime.dll, LOAD_WITH_ALTERED_SEARCH_PATH)`**.
  У DLL свои таблицы импорта, проблемы libdd3d там нет. Поскольку ORT зовём только через C ABI,
  MSVC-сборка ORT работает с расширением, собранным mingw (llvm-mingw), — импорт-библиотека не нужна.

## Размеры (Linux x86_64, Windows x86_64)

| Файл | Размер |
|---|---|
| `bin/linux/libair_nn_probe.so` | 0.64 МБ |
| `bin/linux/libonnxruntime.so.1` (ORT 1.30.0 CPU) | 28.9 МБ |
| `bin/windows/air_nn_probe.dll` | 0.72 МБ |
| `bin/windows/onnxruntime.dll` (ORT 1.30.0 CPU) | 16.5 МБ |

## Windows

Собирается из Linux (`./build.sh windows`, llvm-mingw качается сам, ~80 МБ архив). Проверено: компоновка,
экспорт `air_nn_probe_init`, импорты расширения — только `KERNEL32` и UCRT (`api-ms-win-crt-*`, есть в Win10+).
**Не проверено**: запуск — wine нет (без sudo не ставится). `onnxruntime.dll` (MSVC) импортирует
`MSVCP140.dll`, `MSVCP140_1.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll` — нужен VC++ Redistributable
2015–2022 либо эти 4 DLL рядом (app-local; Microsoft разрешает распространение redist-DLL).
Проверка запуска — на Windows-машине или в CI (GitHub Actions `windows-latest`: godot headless + тест).

## macOS (только способ, не собиралось)

ORT даёт готовый `onnxruntime-osx-arm64-<ver>.tgz` (x86_64 в релизах 1.30 нет — Intel-Mac: собирать ORT
из исходников или не поддерживать). Сборка — на macOS runner GitHub Actions (`macos-14`, arm64): тот же
CMake, `-DCMAKE_OSX_ARCHITECTURES=arm64`, загрузка `dlopen` (двухуровневое пространство имён macOS —
конфликта libdd3d не ожидается). Расширение — `.framework` или `.dylib` + `libonnxruntime.dylib` рядом,
`install_name_tool -id @rpath/…`, подпись `codesign` (ad-hoc `-s -` для своих; для раздачи без
предупреждений Gatekeeper — Developer ID + notarization, платно).
