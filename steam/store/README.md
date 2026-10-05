# Графика страницы и библиотеки Steam

Каталог не входит в сборку игры (`.gdignore`). Все файлы генерирует
`tools/store/make_store_assets.py` (контракт SA-К4, `docs/contracts/steam-assets.md`):

    uv run -q --no-project --with pillow python tools/store/make_store_assets.py
    bash tools/store/check_sizes.sh        # проверка размеров, ждём «STORE SIZES OK»

Исходники: кадры 3840×2160 в `src/` (пока там копия `assets/ui/menu_background.jpg`; берётся
первый по имени), логотип `assets/logo.png`, иконка `assets/icon.png`. Чтобы сменить фон —
положить новый кадр в `src/` (убрать старый) и запустить генератор заново. Повторный запуск
даёт побайтно те же файлы.

## Какой файл в какое поле Steamworks

| Файл | Размер | Поле (Store Admin → Graphical Assets) |
|---|---|---|
| `capsule_header.jpg` | 920×430 | Header Capsule |
| `capsule_small.jpg` | 462×174 | Small Capsule |
| `capsule_main.jpg` | 1232×706 | Main Capsule |
| `capsule_vertical.jpg` | 748×896 | Vertical Capsule |
| `page_background.jpg` | 1438×810 | Page Background (необязательно) |
| `library_capsule.jpg` | 600×900 | Library Capsule |
| `library_header.jpg` | 920×430 | Library Header Capsule |
| `library_hero.png` | 3840×1240 | Library Hero (без текста и логотипа) |
| `library_logo.png` | 1280×324, прозрачный фон | Library Logo |
| `shortcut_icon.png`, `shortcut_icon.ico` | 256×256 | Shortcut Icon (иконка клиента; ICO — несколько размеров внутри) |
| `app_icon.jpg` | 184×184 | Community Icon (App Icon) |
| `event_cover.jpg` | 800×450 | Event Cover |
| `event_header.jpg` | 1920×622 | Event Header (необязательно) |

Название игры на капсулах — логотип `assets/logo.png` (белый, с мягкой тенью); других надписей нет
(правила Steam: без наград, цитат, скидок).

## Позже

- Скриншоты (`screenshots/NN_<имя>.jpg`, 1920×1080, не меньше 5) — после появления кадров игры, вне этого модуля.
- Иконки ачивок (`achievements/<API_NAME>.jpg` и `<API_NAME>_locked.jpg`, 256×256) — задача SA-7.
