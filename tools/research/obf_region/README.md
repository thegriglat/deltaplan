---
type: "research"
status: "closed"
module: ""
updated: "2026-09-30"
summary: "Эксперимент: состав OsmAnd OBF региона — К документу docs/plan/offline_world_data.md (раздел «Почему не OsmAnd OBF»)."
related: []
conclusion: ""
data: "tools/research/obf_region/"
applied_in: ""
---
# Эксперимент: состав OsmAnd OBF региона

К документу `docs/plan/offline_world_data.md (раздел «Почему не OsmAnd OBF»)`.

- `obf_inspect.py` — минимальный читатель OBF на чистом Python (без protoc): разделы файла, таблица
  правил тегов карты, уровни зума, подсчёт объектов по тегам на подробнейшем уровне (z15–22) в
  квадрате вокруг точки (считаются блоки, пересекающие квадрат, без точной обрезки).
  Схема — `OBF.proto` из https://github.com/osmandapp/OsmAnd-resources/blob/master/protos/OBF.proto.
  Особенность формата: нестандартный тип провода 6 (fixed32 big-endian — длина раздела или
  смещение `shiftToMapData`), штатным protobuf-парсером файл целиком не читается.
- `ongudai_20km.txt` — вывод для квадрата 40×40 км вокруг Онгудая (50.79, 86.13).

Воспроизведение (файл региона в git не кладём, ~84 МБ zip / 122 МБ):

```
curl -L -o altay.obf.zip "https://download.osmand.net/download?standard=yes&file=Russia_altay_asia_2.obf.zip"
unzip altay.obf.zip
python3 tools/research/obf_region/obf_inspect.py Russia_altay_asia_2.obf 50.79 86.13 20
```

Лицензии: данные — © OpenStreetMap contributors, ODbL 1.0; файл собран OsmAnd B.V., условия
сервиса https://osmand.net/help-online/terms-of-use/ (п. 9.2 запрещает автоматическое/массовое
скачивание и распространение без письменного согласия). Скрипт — наш.
