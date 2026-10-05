"""
London Crime project - prepare the three reference files for loading into SQL Server.

SQL Server's BULK INSERT reads CSV, not Excel, so this script pulls just the
columns we need out of each download and saves them as tidy CSVs.

Input  (reference/raw):   the files exactly as downloaded
Output (reference/clean): one simple CSV per file
"""
from pathlib import Path
import os
import pandas as pd

ROOT = Path(os.environ.get("LONDON_CRIME_ROOT",
                           r"C:\Users\rccha\Data Projects\London Crime"))
RAW = ROOT / "reference" / "raw"
CLEAN = ROOT / "reference" / "clean"
CLEAN.mkdir(parents=True, exist_ok=True)

# 1. LSOA -> ward -> borough lookup (already a CSV; keep the useful columns
#    and drop the empty Welsh-language name columns)
lookup = pd.read_csv(
    RAW / "LSOA_2021_to_Electoral_Ward_2024_to_LAD_2024_Best_Fit_Lookup_in_EW.csv",
    encoding="utf-8-sig", dtype=str)
lookup = lookup[["LSOA21CD", "LSOA21NM", "WD24CD", "WD24NM", "LAD24CD", "LAD24NM"]]
lookup.columns = ["lsoa_code", "lsoa_name", "ward_code", "ward_name", "lad_code", "lad_name"]
lookup.to_csv(CLEAN / "lsoa_lookup.csv", index=False, encoding="utf-8")

# 2. Indices of Deprivation 2025, File 2 (England only) - overall index plus domains.
#    We keep income and employment (no crime in them) and the crime domain
#    (to show how much of the overall index is crime).
imd = pd.read_excel(RAW / "File_2_IoD2025_Domains_of_Deprivation.xlsx",
                    sheet_name="IoD2025 Domains")
imd = imd.iloc[:, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 14, 15]]
imd.columns = ["lsoa_code", "lsoa_name", "lad_code", "lad_name",
               "imd_rank", "imd_decile",
               "income_rank", "income_decile",
               "employment_rank", "employment_decile",
               "crime_rank", "crime_decile"]
imd.to_csv(CLEAN / "imd_2025.csv", index=False, encoding="utf-8")

# 3. Population: three sheets (mid-2022, mid-2023, mid-2024), each one row per
#    LSOA with ~180 age/sex columns. We only want the Total column, and we stack
#    the three years into "long" format: one row per LSOA per year.
frames = []
for year in (2022, 2023, 2024):
    df = pd.read_excel(RAW / "sapelsoasyoa20222024.xlsx",
                       sheet_name=f"Mid-{year} LSOA 2021",
                       header=3,  # the real column headings are on row 4
                       usecols=["LSOA 2021 Code", "Total"])
    df.columns = ["lsoa_code", "population"]
    df.insert(1, "mid_year", year)
    frames.append(df)
pop = pd.concat(frames, ignore_index=True)
pop.to_csv(CLEAN / "population_lsoa.csv", index=False, encoding="utf-8")

# Quick checks
london = lookup["lad_code"].str.startswith("E09")
print(f"lookup:     {len(lookup):,} LSOAs ({london.sum():,} in London)")
print(f"imd:        {len(imd):,} LSOAs ({imd['lad_code'].str.startswith('E09').sum():,} in London)")
print(f"population: {len(pop):,} rows "
      f"({pop['lsoa_code'].isin(lookup.loc[london, 'lsoa_code']).sum():,} London rows)")
