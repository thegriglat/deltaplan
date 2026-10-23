---
type: "research"
status: "active"
module: "crash-reports"
area: "release"
updated: "2026-10-23"
summary: "Скрипты CR-11: классификатор строк потери устройства GPU и проба нативного дескриптора устройства."
related: ["docs/research/crash-reports/cr-11.md", "docs/contracts/crash-reports.md"]
contracts: ["CR-К1"]
conclusion: "см. docs/research/crash-reports/cr-11.md"
data: "tools/research/crash-reports/cr-11/results.json"
applied_in: "не применено"
---
# CR-11: причина потери устройства GPU

Файлы:
- `device_loss_classifier.gd` — прототип классификатора строк журнала движка (HRESULT DXGI, `VK_ERROR_DEVICE_LOST`, отчёт `VK_EXT_device_fault`); основа для `GpuLossLogger` (CR-К2 v2). В игру не подключён.
- `test_classify.gd` — проверки (13 случаев, строки — тексты ошибок движка из отчётов #4–#10, #18 и исходников 4.7.2).
- `probe_driver_resource.gd` — проба: отдаёт ли `RenderingDevice.get_driver_resource` ненулевой дескриптор устройства и есть ли класс `Logger`.
- `results.json` — числа запусков.

Воспроизведение (Godot на машине — только под замком cpu):
```
.dpcli/dpcli lock cpu cr11 --no-tmux -- godot --headless --path tools/research/crash-reports/cr-11 -s test_classify.gd
.dpcli/dpcli lock cpu cr11p --no-tmux -- godot --path tools/research/crash-reports/cr-11 --rendering-driver vulkan --resolution 64x64 -s probe_driver_resource.gd
```
Код выхода первой команды 0 — проверки прошли. Вторая нужна окно/GPU (на Windows с `--rendering-driver d3d12` то же значение — указатель `ID3D12Device`; не запускалось).

Источники (исходники — тег `4.7.2-stable`, `master` на 2026-10-23; Godot — MIT; в репозиторий не копировались, сохранены вне его в `~/.cache/dp-crash-reports/godot-src/`):
- https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/d3d12/rendering_device_driver_d3d12.cpp
- https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/d3d12/rendering_context_driver_d3d12.cpp
- https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/vulkan/rendering_device_driver_vulkan.cpp
- https://github.com/godotengine/godot/blob/4.7.2-stable/main/main.cpp
- Microsoft Learn: DXGI_ERROR (коды), ID3D12Device::GetDeviceRemovedReason, Device Removed Extended Data (DRED), Timeout Detection and Recovery (TDR) — только ссылки, текст не копировался.
- Khronos: VK_EXT_device_fault.
Данных пилотов в каталоге нет; данные отчётов — `gh issue view -R thegriglat/deltaplan-reports`, сырые — `~/.cache/dp-crash-reports/`.
