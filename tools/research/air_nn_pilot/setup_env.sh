#!/usr/bin/env bash
# Окружение пилота: .venv рядом со скриптом (Python 3.12 через uv), версии — requirements.lock.
# Системный python не трогает. Повторный запуск — досинхронизирует (uv pip sync).
#   ./setup_env.sh           — создать/обновить .venv и проверить CUDA (torch, cupy), ONNX Runtime
#   ./setup_env.sh --relock  — пересобрать requirements.lock из requirements.in (новые версии)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
IDX=(--index-url https://download.pytorch.org/whl/cu126 --extra-index-url https://pypi.org/simple --index-strategy unsafe-best-match)
if [[ "${1:-}" == "--relock" ]]; then
  uv pip compile requirements.in --python-version 3.12 "${IDX[@]}" -o requirements.lock
fi
[[ -x .venv/bin/python ]] || uv venv --python 3.12 .venv
uv pip sync --python .venv/bin/python "${IDX[@]}" requirements.lock
.venv/bin/python - <<'PY'
import torch, cupy, onnx, onnxruntime as ort, numpy as np
assert torch.cuda.is_available(), "torch: CUDA недоступна"
x = torch.randn(64, 8, 96, 96, device="cuda")
y = torch.nn.Conv2d(8, 16, 3, padding=1).cuda()(x).sum().item()
a = cupy.arange(10, dtype=cupy.float32); s = float((a * a).sum())
print(f"ok: torch {torch.__version__} ({torch.cuda.get_device_name(0)}), cupy {cupy.__version__} (sum {s}), "
      f"onnx {onnx.__version__}, onnxruntime {ort.__version__} {ort.get_available_providers()}, numpy {np.__version__}")
PY
