---
type: "reference"
status: "active"
module: "osm-tiles"
updated: "2026-10-10"
summary: "Код тайлов OSM 20 км: упаковщик osmtiles (Rust), оркестратор world.py, regions.py, сверка, оценка планеты, тесты; сборка, команды, раскладка каталогов."
related: ["docs/guide/osm-tiles.md", "docs/contracts/osm-tiles.md"]
---
# tools/osm_tiles

Сборка тайлов OSM 20 км для всей планеты. Как запустить тест и мировой прогон — `docs/guide/osm-tiles.md`; форматы и интерфейсы — `docs/contracts/osm-tiles.md` (O1–O9).

| Файл | Что |
|---|---|
| `packer/` | Rust-крейт `osmtiles` (сетка O1, файл O2, кодек O3, `pack`/`finalize` O4/O5, `cover`, `stats` O6, `dump`, `manifest` O7) |
| `proto/osm_tiles.proto` | схема protobuf (`OsmTile`, `Stream`, `Kind`) |
| `world.py` | оркестратор мировой сборки (O8): скачать → pack → finalize → манифест; `run`, `status`, `plan` |
| `regions.py` | набор регионов Geofabrik и покрытие (`plan`, `check`) |
| `pack_region.sh` | один регион целиком: cover → pack → finalize → stats → summary |
| `compare_ref.py`, `ref_to_stats.py`, `estimate_planet.py` | сверка с эталоном (допуски плана), эталон → сводка O6, оценка размера планеты |
| `read_tile.py` | независимый декодер O2/O3 (проверка кодека) |
| `tests/` | Python-тесты `test_*.py` (запуск каждого файла `python3 tools/osm_tiles/tests/<файл>.py`), Rust — `cargo test` в `packer/` |

## Сборка
```bash
cd tools/osm_tiles/packer
systemd-run --user --scope -p MemoryMax=12G -q cargo build --release
./target/release/osmtiles --help
```
Подкоманды: `pack`, `finalize`, `cover` (тайлы, пересекающие `.poly`), `stats`, `dump` (файл O2 или манифест → JSON), `manifest`.

## Оркестратор
`python3 tools/osm_tiles/world.py --help`; `run --work <dir> --out <корень> [--regions id,… | --all] [--max-region-gb 2.0] [--extract-batch 2] [--keep-free-gb 20] [--threads N] [--osmtiles <бинарь>] [--osmium osmium] [--seed-from <каталог OT-5>] [--log <файл>]`; `status --work <dir>`; `plan --work <dir>`. Повторный `run` с тем же `--work` продолжает. Запускать под `systemd-run --user --scope -p MemoryMax=12G -q`.

Раскладка `--work`: `regions.json`, `cover/`, `poly/` (план), `state.json`, `finalized.jsonl`, `sources.json`, `log.jsonl`, `run.lock`, `dl/` (выгрузки), `frags/<j>/<i>/<регион>.frag`, `tmp/`, `reports/<регион>.pack.json`. Итог — `<out>/v1/<j>/<i>.dpt` и `<out>/v1/manifest.pb`.

## Память и скорость
- `pack` Казахстана (224 МБ .pbf): 2,8 с, пик RSS 1155 МБ; пик в общем виде до 5,2× размера .pbf, поэтому регионы больше 2 ГБ режутся `osmium extract` (≈ 3,7 ГБ на выход).
- Тесты используют `tests/_env.py`: при отсутствии `zstandard` перезапускаются через venv эталона.
