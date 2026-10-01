#!/usr/bin/env python3
"""Скачать PDF спецификации производителей из сохранённых HTML-страниц."""

import re
import json
import subprocess
from pathlib import Path
from urllib.parse import urljoin
from datetime import datetime
from common import RAW, get, UA

ROOT = Path(__file__).parent
OUT_TEXT = ROOT / "out" / "text"
PDF_DIR = RAW / "pdf"
PDF_DIR.mkdir(parents=True, exist_ok=True)
OUT_TEXT.mkdir(parents=True, exist_ok=True)

# Загрузить индекс URL-ов HTML страниц
makers_index = json.load(open(RAW / "makers_index.json"))

# Обратное отображение: имя файла → URL
html_files_to_urls = {v["url"]: k for k, v in makers_index.items()}
# Выстроить абсолютный путь для каждого HTML файла
html_base_urls = {}
for html_file, url_info in makers_index.items():
    html_base_urls[RAW / html_file] = url_info["url"]

# Найти все PDF ссылки в HTML файлах
pdf_links = {}  # url -> (html_file_used, description)

for manufacturer in ["aeros", "airborne", "bautek", "icaro", "moyes", "ww"]:
    mfg_dir = RAW / manufacturer
    if not mfg_dir.exists():
        continue

    for html_file in mfg_dir.glob("*.html"):
        # Найти базовый URL для этого HTML файла
        base_url = None
        for path, url in html_base_urls.items():
            if path == html_file:
                base_url = url
                break

        if not base_url:
            # Попробовать найти из makers_index.json по относительному пути
            rel_path = f"{manufacturer}/{html_file.name}"
            if rel_path in makers_index:
                base_url = makers_index[rel_path]["url"]

        if not base_url:
            print(f"WARN: No base URL found for {html_file}")
            continue

        try:
            content = html_file.read_text(errors="ignore")
        except Exception as e:
            print(f"ERR: Cannot read {html_file}: {e}")
            continue

        # Найти все PDF ссылки
        for href in re.findall(r'href="([^"]+\.pdf[^"]*)"', content, re.IGNORECASE):
            # Конвертировать относительный путь в абсолютный URL
            pdf_url = urljoin(base_url, href)

            # Избежать дубликатов, сохранить первый источник
            if pdf_url not in pdf_links:
                pdf_links[pdf_url] = (html_file.name, href)

print(f"Found {len(pdf_links)} PDF links")

# Скачать каждый PDF
results = {}
new_pdfs = []
failed_pdfs = []

# Уже существующие PDFs
existing_pdfs = {}
for pdf_file in PDF_DIR.glob("*.pdf"):
    existing_pdfs[pdf_file.name] = pdf_file

for pdf_url in sorted(pdf_links.keys()):
    html_source, href_text = pdf_links[pdf_url]

    # Составить имя файла: manufacturer__name.pdf
    # Извлечь производителя из html_source И из URL
    manufacturer = None
    for mfg in ["aeros", "airborne", "bautek", "icaro", "moyes", "ww"]:
        if mfg in html_source:
            manufacturer = mfg
            break

    # Если не найдено в имени файла, проверить в URL
    if not manufacturer:
        if "icaro2000.com" in pdf_url.lower():
            manufacturer = "icaro"
        elif "airborne.com.au" in pdf_url.lower():
            manufacturer = "airborne"
        elif "aeros.com" in pdf_url.lower():
            manufacturer = "aeros"
        elif "moyes.com" in pdf_url.lower():
            manufacturer = "moyes"
        elif "willswing.com" in pdf_url.lower() or "ww" in html_source.lower():
            manufacturer = "ww"
        elif "bautek.com" in pdf_url.lower():
            manufacturer = "bautek"

    if not manufacturer:
        manufacturer = "unknown"

    # Составить имя файла из последней части URL или href
    filename_part = re.sub(r'[%\s/\\]+', '_',
                          pdf_url.split("/")[-1].split("?")[0].strip())
    if not filename_part.lower().endswith('.pdf'):
        filename_part += '.pdf'

    # Очистить имя файла от проблемных символов
    filename_part = re.sub(r'[^\w._-]', '', filename_part, flags=re.UNICODE)
    filename_part = filename_part.replace('_pdf', '').replace('.pdf', '') + '.pdf'

    filename = f"{manufacturer}__{filename_part}"
    filepath = PDF_DIR / filename

    # Проверить, уже ли скачан
    if filepath.exists() and filepath.stat().st_size > 100:
        status = "ok"
        results[filename] = {
            "url": pdf_url,
            "status": "ok",
            "size": filepath.stat().st_size,
            "date": datetime.fromtimestamp(filepath.stat().st_mtime).isoformat(),
        }
        continue

    # Скачать
    print(f"Fetching {pdf_url} -> {filename}")
    st, p = get(pdf_url, f"pdf/{filename}")

    if st == 200:
        file_size = p.stat().st_size
        file_date = datetime.fromtimestamp(p.stat().st_mtime).isoformat()
        results[filename] = {
            "url": pdf_url,
            "status": "ok",
            "size": file_size,
            "date": file_date,
        }
        new_pdfs.append(filename)

        # Запустить pdftotext для нового PDF
        text_file = OUT_TEXT / f"pdf__{filename_part.replace('.pdf', '.pdf.txt')}"
        try:
            subprocess.run(
                ["pdftotext", "-layout", str(p), str(text_file)],
                capture_output=True,
                timeout=30
            )
            print(f"  -> {text_file.name}")
        except Exception as e:
            print(f"  ERR pdftotext: {e}")
    elif st in [404, 403]:
        results[filename] = {
            "url": pdf_url,
            "status": f"{st}",
            "size": 0,
            "date": None,
        }
        failed_pdfs.append((filename, st))
        print(f"  {st} (skipped)")
    else:
        results[filename] = {
            "url": pdf_url,
            "status": f"error_{st}",
            "size": 0,
            "date": None,
        }
        failed_pdfs.append((filename, st))
        print(f"  Error {st}")

# Сохранить уже существующие PDFs в results
for pdf_file in PDF_DIR.glob("*.pdf"):
    filename = pdf_file.name
    if filename not in results:
        results[filename] = {
            "url": "existing",
            "status": "ok",
            "size": pdf_file.stat().st_size,
            "date": datetime.fromtimestamp(pdf_file.stat().st_mtime).isoformat(),
        }

# Создать INDEX.md
index_md = ROOT / "raw" / "pdf" / "INDEX.md"
index_content = "# PDF Index\n\n"
index_content += f"Generated: {datetime.now().isoformat()}\n\n"
index_content += "| File | URL | Size | Date | Status |\n"
index_content += "|------|-----|------|------|--------|\n"

for filename in sorted(results.keys()):
    info = results[filename]
    url = info.get("url", "")
    size = info.get("size", 0)
    date = info.get("date", "")
    status = info.get("status", "")

    # Сокращённый URL для таблицы
    url_display = url if url == "existing" else url[-60:] if len(url) > 60 else url

    index_content += f"| {filename} | `{url_display}` | {size} | {date} | {status} |\n"

index_md.write_text(index_content)
print(f"\nSaved index to {index_md}")

# Отчет
print(f"\n=== Summary ===")
print(f"Total PDFs: {len(results)}")
print(f"New PDFs: {len(new_pdfs)}")
print(f"Failed: {len(failed_pdfs)}")
if failed_pdfs:
    print("Failed downloads:")
    for fn, code in failed_pdfs:
        print(f"  {fn} ({code})")

# Определить какие PDFs содержат технические характеристики (по имени)
characteristic_pdfs = [
    f for f in results.keys()
    if any(keyword in f.lower() for keyword in ["spec", "data", "metric", "imperial", "manual", "datasheet", "technical"])
]
print(f"\nPDFs with characteristic data (by name): {len(characteristic_pdfs)}")
for pdf in sorted(characteristic_pdfs):
    print(f"  {pdf}")
