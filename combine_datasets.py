from pathlib import Path
import csv

root = Path(
    r"C:\Users\rccha\Data Projects\London Crime\Data Sept2023 to Aug2026")
output_folder = root / "combined"
output_folder.mkdir(exist_ok=True)

datasets = {
    "street": "crimes_combined.csv",
    "outcomes": "outcomes_combined.csv",
}

for dataset, output_name in datasets.items():
    files = sorted(
    file
    for force in ("metropolitan", "city-of-london")
    for file in root.rglob(f"*-{force}-{dataset}.csv")
)

    if not files:
        raise FileNotFoundError(f"No {dataset} files found in {root}")

    # Catch accidental copies of the same monthly file.
    names = [file.name for file in files]
    if len(names) != len(set(names)):
        raise ValueError(f"Duplicate monthly filenames found for {dataset}")

    output_path = output_folder / output_name
    expected_header = None
    total_rows = 0

    with output_path.open("w", newline="", encoding="utf-8-sig") as target:
        writer = csv.writer(target)

        for file in files:
            with file.open("r", newline="", encoding="utf-8-sig") as source:
                reader = csv.reader(source)
                header = next(reader)

                if expected_header is None:
                    expected_header = header
                    writer.writerow(header + ["SourceFile"])
                elif header != expected_header:
                    raise ValueError(f"Different columns found in {file}")

                for row in reader:
                    writer.writerow(row + [file.name])
                    total_rows += 1

    print(
        f"{output_name}: "
        f"{len(files)} files combined, {total_rows:,} rows"
    )