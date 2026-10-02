# Данные пилота air-nn (`$AIR_NN_DATA/pilot/`)

Пишется генератором набора `tools/research/air_nn_pilot/dataset.py` (NN-P1); правила — `docs/plan/air_nn.md` §4.4–4.6,
формат случая — `docs/air_nn_contracts.md`, контракт П1. Руками здесь ничего не правится: всё делают скрипты.

```
pilot/
  README.md                         — этот файл (перезаписывается генератором)
  datasets/                         — наборы, по версии решателя
    s0-<хеш>/                       — версия эталона AM-01: 7 знаков sha1 от tools/research/air3d/*.py
      main/                         — основной набор: 690 случаев air-lite + процедурные рельефы p_*
      smoke/                        — мини-набор для run_pilot.sh --smoke (не пересекается с main по файлам)
        manifest.json               — что это, чем сделано, план (зёрна, хеш), счётчики, размер, complete
        plan.json                   — план: agl, centers (окна), cases (условия), seed, proc (параметры рельефов), order
        state.sqlite                — статусы и метаданные случаев (таблицы cases, events, batches, meta), WAL
        cases/<id>.npz              — решения случая, float16 (ключи и оси — контракт П1)
  reports/                          — отчёты пилота (NN-P2)
  tmp/                              — временное: недописанные файлы (*.part), замки run; можно удалить, когда run не идёт
```

Команды (из `tools/research/air_nn_pilot/`): `.venv/bin/python dataset.py status --dataset main` — сводка;
`... run --dataset main` — продолжить счёт с места (после любого обрыва — та же команда);
`... export --dataset main --out cases.jsonl` — метаданные случаев одной строкой на случай.
