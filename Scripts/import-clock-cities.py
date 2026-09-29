#!/usr/bin/env python3
"""Build the bundled offline catalog from locally downloaded GeoNames source files.

Usage: python3 Scripts/import-clock-cities.py cities15000.zip admin1CodesASCII.txt
Sources: https://download.geonames.org/export/dump/ (CC BY 4.0)
The inputs' SHA-256 hashes are recorded beside the generated catalog.
"""
import hashlib
from pathlib import Path
import sys
import zipfile


def main():
    cities, regions = map(Path, sys.argv[1:])
    destination = Path(__file__).resolve().parents[1] / "Sources/lineup/Resources/WorldClock"
    region_names = {}
    for line in regions.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        region_names[fields[0]] = fields[1]
    with zipfile.ZipFile(cities) as archive:
        source = archive.read("cities15000.txt").decode("utf-8")
    rows = []
    for line in source.splitlines():
        fields = line.split("\t")
        if len(fields) != 19 or not fields[17]:
            raise ValueError("Unexpected GeoNames row")
        aliases = sorted(set([fields[2]] + fields[3].split(",")) - {"", fields[1]})
        rows.append("\t".join([
            fields[0], fields[1], fields[8], region_names.get(fields[8] + "." + fields[10], ""),
            fields[4], fields[5], fields[17], fields[14], "|".join(aliases),
        ]))
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "cities.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")
    attribution = """City data © GeoNames contributors, licensed under CC BY 4.0.
https://www.geonames.org/
https://creativecommons.org/licenses/by/4.0/

Source: https://download.geonames.org/export/dump/cities15000.zip
Regions: https://download.geonames.org/export/dump/admin1CodesASCII.txt
Coverage: cities with population > 15,000 and capitals.
Changes: selected fields, joined region names, sorted/deduplicated alternate names.
Rebuild: python3 Scripts/import-clock-cities.py <cities15000.zip> <admin1CodesASCII.txt>

"""
    for name, path in [("cities15000.zip", cities), ("admin1CodesASCII.txt", regions)]:
        attribution += f"{name} SHA-256: {hashlib.sha256(path.read_bytes()).hexdigest()}\n"
    (destination / "GeoNames-NOTICE.txt").write_text(attribution, encoding="utf-8")
    print(f"Wrote {len(rows)} cities to {destination}")


if __name__ == "__main__":
    main()
