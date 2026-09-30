#!/usr/bin/env python3
"""Extract wing characteristics from DHV test reports."""

import json
import re
from pathlib import Path

# Configuration
SCRIPT_DIR = Path(__file__).parent
OUT_DIR = SCRIPT_DIR / "out"
TEXT_DIR = OUT_DIR / "text"
BATCH_FILE = OUT_DIR / "batches" / "dhv_08"
OUTPUT_FILE = OUT_DIR / "haiku_dhv" / "dhv_08.json"

# Ensure output directory exists
OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

def extract_from_text(text: str, filename: str) -> list:
    """Extract wing data from DHV test report text."""
    wings = []

    # Split by lines for parsing structure
    lines = text.split('\n')

    # Find key information by parsing line structure
    manufacturer = ""
    model = ""
    cert_class = ""
    cert_standard = ""

    for i, line in enumerate(lines):
        line_stripped = line.strip()

        if line_stripped == "Musterbezeichnung" and i + 1 < len(lines):
            model = lines[i + 1].strip()
        elif line_stripped == "Hersteller" and i + 1 < len(lines):
            # Get next non-empty line that's not a section header
            j = i + 1
            while j < len(lines):
                candidate = lines[j].strip()
                if candidate and not candidate.startswith("Inhaber") and "DHV" not in candidate:
                    manufacturer = candidate
                    break
                j += 1
        elif line_stripped.startswith("Klassifizierung"):
            if i + 1 < len(lines):
                cert_class = lines[i + 1].strip()
        elif "Muster" in line_stripped and "fnummer" in line_stripped:
            if i + 1 < len(lines):
                cert_standard = lines[i + 1].strip()

    # Fallback: use regex to extract cert_standard
    if not cert_standard:
        cs_match = re.search(r'DHV\s+\d+-\d+-\d+', text)
        if cs_match:
            cert_standard = cs_match.group(0)

    # If no manufacturer/model, skip this file (not a hang glider)
    if not manufacturer or not model:
        return []

    # Create wing record
    wing = {
        "manufacturer": manufacturer,
        "model": model,
        "size": "",  # Not specified in DHV reports
        "cert_class": cert_class,
        "cert_standard": cert_standard,
        "facts": [],
        "src": filename
    }

    # Extract facts
    facts = []

    # Startgewicht (takeoff mass) - pattern: "Startgewicht\n 121 Kg - 158 Kg"
    takeoff_match = re.search(r'Startgewicht\s+(\d+)\s+Kg\s*-\s*(\d+)\s+Kg', text)
    if takeoff_match:
        min_mass = takeoff_match.group(1)
        max_mass = takeoff_match.group(2)
        quote = takeoff_match.group(0).replace('\n', ' ')
        facts.append({
            "field": "takeoff_mass_min",
            "value": float(min_mass),
            "unit": "kg",
            "quote": quote[:120]
        })
        facts.append({
            "field": "takeoff_mass_max",
            "value": float(max_mass),
            "unit": "kg",
            "quote": quote[:120]
        })

    # Höchstzulässige Fluggeschwindigkeit (Vne)
    vne_match = re.search(r'Höchstzulässige.*?Fluggeschwindigkeit\s+(\d+)\s+km/h', text, re.DOTALL)
    if vne_match:
        vne_val = vne_match.group(1)
        quote = vne_match.group(0).replace('\n', ' ')
        facts.append({
            "field": "vne",
            "value": float(vne_val),
            "unit": "km/h",
            "quote": quote[:120]
        })

    # V min and V max - these appear in a table with VG 0% and VG 100% columns
    # Pattern: "V min (km/h)\n 31\n 30" (VG0% = 31, VG100% = 30)
    vmin_match = re.search(r'V\s+min\s+\(km/h\)\s+(\d+)\s+(\d+)', text)
    if vmin_match:
        vmin_vg0 = vmin_match.group(1)
        vmin_vg100 = vmin_match.group(2)
        quote = vmin_match.group(0).replace('\n', ' ')
        facts.append({
            "field": "vmin_vg0",
            "value": float(vmin_vg0),
            "unit": "km/h",
            "quote": quote[:120]
        })
        facts.append({
            "field": "vmin_vg100",
            "value": float(vmin_vg100),
            "unit": "km/h",
            "quote": quote[:120]
        })

    # V max - handle cases with ">90" (extract just the number)
    vmax_match = re.search(r'V\s+max\s+\(km/h\)\s+(\d+)\s+>?(\d+)', text)
    if vmax_match:
        vmax_vg0 = vmax_match.group(1)
        vmax_vg100 = vmax_match.group(2)
        quote = vmax_match.group(0).replace('\n', ' ')
        facts.append({
            "field": "vmax_vg0",
            "value": float(vmax_vg0),
            "unit": "km/h",
            "quote": quote[:120]
        })
        facts.append({
            "field": "vmax_vg100",
            "value": float(vmax_vg100),
            "unit": "km/h",
            "quote": quote[:120]
        })

    wing["facts"] = facts
    wings.append(wing)

    return wings

def main():
    # Read batch file list
    if not BATCH_FILE.exists():
        print(f"Batch file not found: {BATCH_FILE}")
        return

    batch_files = [line.strip() for line in BATCH_FILE.read_text().split('\n') if line.strip()]

    all_wings = []
    src_files = []

    # Process each file
    for batch_filename in batch_files:
        text_path = TEXT_DIR / batch_filename

        if not text_path.exists():
            print(f"Warning: File not found: {text_path}")
            continue

        print(f"Processing: {batch_filename}")
        text = text_path.read_text(encoding='utf-8', errors='replace')
        wings = extract_from_text(text, batch_filename)

        if wings:
            all_wings.extend(wings)
            src_files.append(batch_filename)

    # Save result
    result = {
        "src_files": src_files,
        "wings": all_wings
    }

    OUTPUT_FILE.write_text(json.dumps(result, ensure_ascii=False, indent=2))

    # Summary
    total_facts = sum(len(wing.get("facts", [])) for wing in all_wings)
    total_geometry = sum(len(wing.get("geometry", [])) for wing in all_wings)
    print(f"\nResult: {len(all_wings)} records, {total_facts} facts, {total_geometry} geometry")
    print(f"Saved to: {OUTPUT_FILE}")

if __name__ == "__main__":
    main()
