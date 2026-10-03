---
type: "research"
status: "active"
module: "air-onnx"
updated: "2026-10-03"
summary: "ON-1: экспорт/осмотр .onnx сети области по контракту O1 (export_onnx.py), малая тестовая сеть tiny_p2v4 с эталоном ORT, замер ORT CPU сети первого пилота"
---
# tools/air_onnx — экспорт .onnx по O1

Контракт — `docs/contracts/air-onnx.md` (O1). Все команды — только CPU, venv пилота (только читать):
`PY="env CUDA_VISIBLE_DEVICES= /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python -B"`.
Код пилота (`tools/research/air_nn_pilot/pilotnn`) импортируется, не меняется; экспорт — `evaluate.export_onnx`
(opset 17, `maps`/`nums`/`out`, `dynamo=False`), затем дописываются `metadata_props`.

## Команды
```
$PY tools/air_onnx/export_onnx.py --ckpt <прогон>/main --out m.onnx      # из ckpt/best.pt + task.json
$PY tools/air_onnx/export_onnx.py --random --channels 8,16 --maps 9 --seed 0 --out m.onnx
$PY tools/air_onnx/export_onnx.py --info m.onnx                           # входы, выходы, метаданные
$PY tools/air_onnx/export_onnx.py --make-ref m.onnx                       # записать m_ref.json
$PY tools/air_onnx/export_onnx.py --verify m.onnx                         # O1 + сверка с m_ref.json (если рядом)
$PY tools/air_onnx/test_contract_o1.py --model m.onnx                     # контрактный тест координатора
```
`p2_version` в метаданных — по числу карт: 4 → "2", 9 → "4". Работает и с сетью П-2 (9 карт,
`runs/2026-10-03_p2/main`), `deltaplan.domain` берётся из `task.json["domain"]`, если там есть.

## Фикстура tiny_p2v4
`tests/air_onnx/fixtures/tiny_p2v4.onnx` (113 КБ): 9 карт, 18 чисел, 91 выход, каналы (8, 16), emb 16, зерно 0;
веса случайные (FiLM и `out_scale` — ненулевые, чтобы вход `nums` влиял на выход). Воспроизводится побайтно:
`--random --channels 8,16 --maps 9 --seed 0` (torch 2.14, opset 17).

### Эталон `tiny_p2v4_ref.json` (ORT Python 1.30, CPU)
Детерминированный вход (считать в float64, затем привести к float32):
- `maps[0,c,i,j] = sin(0.07·i + 0.11·j + 0.5·c)`, c = 0..8, i — строка (ось высоты 2), j — столбец (ось 3), i,j = 0..95;
- `nums[0,k] = cos(0.3·k + 0.2)`, k = 0..17.

В JSON: `points` — 64 значения `out[0,c,i,j]` (k = 0..63: c = (7k+3) mod 91, i = (13k+5) mod 96, j = (29k+11) mod 96),
`channel_mean` и `channel_absmax` — по 91 каналу. Допуск сверки `tol_abs` = 1e-4 (расхождение ORT-версий и
потоков — ~1e-6). Полное поле (3,3 МБ) не хранится.

## Замер ORT CPU, сеть первого пилота (maps [1,4,96,96], 12,4 МБ)
Ryzen/20 логических ядер, ORT 1.30.0, CPUExecutionProvider, intra_op = N, inter_op = 1, 3 прогрева + 20 прогонов;
идёт обучение П-2 (нагрузка ~3,8 — числа слегка завышены).

| потоков | медиана, мс | минимум, мс |
|---|---|---|
| 1 | 45 | 45 |
| 4 | 17 | 17 |
