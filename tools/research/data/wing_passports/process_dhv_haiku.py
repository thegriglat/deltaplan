#!/usr/bin/env python3
"""Process DHV test reports to extract hang glider specifications."""

import json
import pathlib
import sys
import re

ROOT = pathlib.Path(__file__).parent
OUT = ROOT / "out"
TXT = OUT / "text"
HAIKU_OUT = OUT / "haiku_dhv"
HAIKU_OUT.mkdir(parents=True, exist_ok=True)

def read_batch_files(batch_name):
    """Read list of files from batch directory."""
    batch_file = OUT / "batches" / batch_name
    if not batch_file.exists():
        print(f"Error: batch file not found: {batch_file}")
        sys.exit(1)

    with open(batch_file, 'r') as f:
        return [line.strip() for line in f if line.strip()]

def read_text_file(filename):
    """Read text file from out/text/ directory."""
    path = TXT / filename
    if not path.exists():
        print(f"Warning: file not found: {path}")
        return None
    return path.read_text()

def parse_dhv_report(text):
    """Parse DHV test report format."""
    lines = text.split('\n')

    wing_data = {
        "manufacturer": "",
        "model": "",
        "size": "",
        "cert_class": "",
        "cert_standard": "",
        "facts": [],
        "geometry": []
    }

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        # Extract model (Musterbezeichnung)
        if line == "Musterbezeichnung" and i + 1 < len(lines):
            wing_data["model"] = lines[i + 1].strip()
            # Try to split model into model and size
            match = re.match(r'(.+?)\s+(\d+(?:[.,]\d+)?)\s*([A-Z]?)$', wing_data["model"])
            if match:
                model_part = match.group(1)
                size_part = match.group(2)
                class_part = match.group(3)
                wing_data["model"] = model_part + (f" {class_part}" if class_part else "")
                wing_data["size"] = size_part
            i += 2
            continue

        # Extract manufacturer (after finding Musterbezeichnung context)
        if line == "Hersteller" and wing_data["model"] and i + 1 < len(lines):
            next_val = lines[i + 1].strip()
            if next_val and not next_val.startswith("Inhaber"):
                wing_data["manufacturer"] = next_val
                i += 2
                continue

        # Extract classification
        if line == "Klassifizierung" and i + 1 < len(lines):
            class_val = lines[i + 1].strip()
            if class_val:
                wing_data["cert_class"] = f"DHV {class_val}"
            i += 2
            continue

        # Extract certification number
        if line == "Musterpräfnummer" and i + 1 < len(lines):
            cert_val = lines[i + 1].strip()
            if cert_val and not cert_val.startswith("Inhaber") and cert_val.startswith("DHV"):
                wing_data["cert_standard"] = cert_val
            i += 2
            continue

        # Extract takeoff weight
        if line == "Startgewicht" and i + 1 < len(lines):
            weight_str = lines[i + 1].strip()
            match = re.search(r'(\d+)\s*kg?\s*[-–]\s*(\d+)\s*kg?', weight_str, re.IGNORECASE)
            if match:
                wing_data["facts"].append({
                    "field": "takeoff_mass_min",
                    "value": float(match.group(1)),
                    "unit": "kg",
                    "quote": weight_str[:120]
                })
                wing_data["facts"].append({
                    "field": "takeoff_mass_max",
                    "value": float(match.group(2)),
                    "unit": "kg",
                    "quote": weight_str[:120]
                })
            i += 2
            continue

        # Extract VNE
        if "Höchstzulässige Fluggeschwindigkeit" in line and i + 1 < len(lines):
            vne_str = lines[i + 1].strip()
            match = re.search(r'(\d+(?:[.,]\d+)?)\s*km/h', vne_str, re.IGNORECASE)
            if match:
                wing_data["facts"].append({
                    "field": "vne",
                    "value": float(match.group(1).replace(',', '.')),
                    "unit": "km/h",
                    "quote": vne_str[:120]
                })
            i += 2
            continue

        i += 1

    # Now extract V min/V max from the GERADEAUSFLUG section
    geradeaus_match = re.search(r'GERADEAUSFLUG\s*\n(.+?)(?=KURVENHANDLING|VERHALTEN|LANDUNG|$)', text, re.IGNORECASE | re.DOTALL)
    if geradeaus_match:
        geradeaus_section = geradeaus_match.group(1)
        geradeaus_lines = geradeaus_section.split('\n')

        # Check if VG 100% exists
        has_vg100 = any('VG 100%' in line for line in geradeaus_lines)

        # Find indices of VG markers
        vg_start = -1
        for idx, line in enumerate(geradeaus_lines):
            if 'VG' in line:
                vg_start = idx
                break

        if vg_start >= 0:
            # Find V min/V max data lines
            for idx in range(vg_start, len(geradeaus_lines)):
                line = geradeaus_lines[idx].strip()

                if 'V min' in line and 'km/h' in line:
                    # Extract V min values
                    if idx + 1 < len(geradeaus_lines):
                        vmin_vg0 = geradeaus_lines[idx + 1].strip()
                        if vmin_vg0.isdigit():
                            wing_data["facts"].append({
                                "field": "vmin_vg0",
                                "value": float(vmin_vg0),
                                "unit": "km/h",
                                "quote": f"V min VG 0%: {vmin_vg0} km/h"
                            })

                    if has_vg100 and idx + 2 < len(geradeaus_lines):
                        vmin_vg100 = geradeaus_lines[idx + 2].strip()
                        if vmin_vg100.isdigit():
                            wing_data["facts"].append({
                                "field": "vmin_vg100",
                                "value": float(vmin_vg100),
                                "unit": "km/h",
                                "quote": f"V min VG 100%: {vmin_vg100} km/h"
                            })

                elif 'V max' in line and 'km/h' in line:
                    # Extract V max values
                    if idx + 1 < len(geradeaus_lines):
                        vmax_vg0 = geradeaus_lines[idx + 1].strip()
                        if vmax_vg0.isdigit():
                            wing_data["facts"].append({
                                "field": "vmax_vg0",
                                "value": float(vmax_vg0),
                                "unit": "km/h",
                                "quote": f"V max VG 0%: {vmax_vg0} km/h"
                            })

                    if has_vg100 and idx + 2 < len(geradeaus_lines):
                        vmax_vg100 = geradeaus_lines[idx + 2].strip()
                        if vmax_vg100.isdigit():
                            wing_data["facts"].append({
                                "field": "vmax_vg100",
                                "value": float(vmax_vg100),
                                "unit": "km/h",
                                "quote": f"V max VG 100%: {vmax_vg100} km/h"
                            })

    # Remove duplicate facts
    seen = set()
    unique_facts = []
    for fact in wing_data["facts"]:
        key = (fact["field"], fact["value"], fact["unit"])
        if key not in seen:
            seen.add(key)
            unique_facts.append(fact)
    wing_data["facts"] = unique_facts

    return wing_data

def process_file(filename):
    """Process a single DHV text file."""
    text_content = read_text_file(filename)
    if text_content is None:
        return None

    wing_data = parse_dhv_report(text_content)

    # Only return if we have at least a model name
    if wing_data["model"]:
        wing_data["src"] = filename
        return wing_data

    return None

def main():
    batch_name = sys.argv[1] if len(sys.argv) > 1 else "dhv_10"

    print(f"Processing batch: {batch_name}")

    files = read_batch_files(batch_name)
    print(f"Found {len(files)} files to process")

    all_wings = []
    src_files = []
    total_facts = 0
    total_geometry = 0

    for i, filename in enumerate(files, 1):
        print(f"[{i}/{len(files)}] Processing {filename}...")

        wing = process_file(filename)
        if wing:
            all_wings.append(wing)
            total_facts += len(wing.get("facts", []))
            total_geometry += len(wing.get("geometry", []))
            src_files.append(filename)

    # Create output JSON
    output = {
        "src_files": src_files,
        "wings": all_wings
    }

    # Save to file
    output_file = HAIKU_OUT / f"{batch_name}.json"
    output_file.write_text(json.dumps(output, ensure_ascii=False, indent=2))

    print(f"\nResults saved to: {output_file}")
    print(f"Summary: {len(all_wings)} wings, {total_facts} facts, {total_geometry} geometry")

    return f"{len(all_wings)} записей, {total_facts} фактов, {total_geometry} геометрии"

if __name__ == "__main__":
    result = main()
    print(result)
