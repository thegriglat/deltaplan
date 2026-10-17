---
type: "research"
status: "active"
module: "vegetation"
updated: "2026-10-17"
summary: "Сравнение срезов, прямоугольников и дерева решений по (lat, lon) с картой Кёппена; команды воспроизведения"
---

# regional_veg — выбор набора деревьев по (lat, lon)

Исследование T-83, документ — `docs/research/regional-vegetation.md`. `compare.py` сравнивает срезы по широте,
список прямоугольников и дерево решений на (lat, lon) с картой Кёппена–Гейгера.

Данные: Beck и др. 2018, Sci. Data, https://figshare.com/articles/dataset/6396959 (файл `Beck_KG_V1.zip`, 71 МБ,
md5 69594689d3cdd8323a0f74ce658125a1), лицензия CC BY 4.0. В репозиторий не кладутся.

Воспроизведение:

    curl -L -o kg.zip https://ndownloader.figshare.com/files/12407516
    unzip kg.zip 'Beck_KG_V1_present_*.tif' -d kg
    uv venv v && uv pip install --python v/bin/python numpy scikit-learn tifffile imagecodecs
    v/bin/python -I compare.py kg ../../../data/places/hg_takeoffs.json results.json

`results.json` — числа (точность по способам, размер JSON, контрольные места). Высота не используется.
