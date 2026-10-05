/* =====================================================================
   London Crime project - Step 1b: load the reference CSVs into staging
   ---------------------------------------------------------------------
   Same pattern as the crime data: all-text staging tables, BULK INSERT,
   then checks. The CSVs were produced by prepare_reference.py.
   Run one numbered section at a time.
   ===================================================================== */
USE LondonCrime;
GO

/* ---------------------------------------------------------------------
   1. Staging tables - columns in the same order as the CSVs, all text
   ------------------------------------------------------------------- */
DROP TABLE IF EXISTS stg.lsoa_lookup;
CREATE TABLE stg.lsoa_lookup (
    lsoa_code  NVARCHAR(20),
    lsoa_name  NVARCHAR(200),
    ward_code  NVARCHAR(20),
    ward_name  NVARCHAR(200),
    lad_code   NVARCHAR(20),
    lad_name   NVARCHAR(200)
);

DROP TABLE IF EXISTS stg.imd_2025;
CREATE TABLE stg.imd_2025 (
    lsoa_code          NVARCHAR(20),
    lsoa_name          NVARCHAR(200),
    lad_code           NVARCHAR(20),
    lad_name           NVARCHAR(200),
    imd_rank           NVARCHAR(20),
    imd_decile         NVARCHAR(20),
    income_rank        NVARCHAR(20),
    income_decile      NVARCHAR(20),
    employment_rank    NVARCHAR(20),
    employment_decile  NVARCHAR(20),
    crime_rank         NVARCHAR(20),
    crime_decile       NVARCHAR(20)
);

DROP TABLE IF EXISTS stg.population_lsoa;
CREATE TABLE stg.population_lsoa (
    lsoa_code   NVARCHAR(20),
    mid_year    NVARCHAR(10),
    population  NVARCHAR(20)
);
GO

/* ---------------------------------------------------------------------
   2. Load the three CSVs (same options as the crime load)
   ------------------------------------------------------------------- */
BULK INSERT stg.lsoa_lookup
FROM 'C:\Users\rccha\Data Projects\London Crime\reference\clean\lsoa_lookup.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001',
      FIELDTERMINATOR = ',', ROWTERMINATOR = '\n', TABLOCK);


--       SELECT 'lsoa_lookup' AS tbl, COUNT(*) AS row_count FROM stg.lsoa_lookup
-- UNION ALL SELECT 'imd_2025', COUNT(*) FROM stg.imd_2025
-- UNION ALL SELECT 'population_lsoa', COUNT(*) FROM stg.population_lsoa;

BULK INSERT stg.imd_2025
FROM 'C:\Users\rccha\Data Projects\London Crime\reference\clean\imd_2025.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001',
      FIELDTERMINATOR = ',', ROWTERMINATOR = '\n', TABLOCK);

BULK INSERT stg.population_lsoa
FROM 'C:\Users\rccha\Data Projects\London Crime\reference\clean\population_lsoa.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001',
      FIELDTERMINATOR = ',', ROWTERMINATOR = '\n', TABLOCK);
GO

/* ---------------------------------------------------------------------
   3. Row counts - expect 35,672 / 33,755 / 107,016
   ------------------------------------------------------------------- */
SELECT 'lsoa_lookup' AS tbl, COUNT(*) AS row_count FROM stg.lsoa_lookup
UNION ALL SELECT 'imd_2025', COUNT(*) FROM stg.imd_2025
UNION ALL SELECT 'population_lsoa', COUNT(*) FROM stg.population_lsoa;

/* ---------------------------------------------------------------------
   4. Line-ending check - should return 0 for every table.
   A hidden carriage return (CHAR(13)) stuck on the last column means
   the ROWTERMINATOR needs changing.
   ------------------------------------------------------------------- */
SELECT 'lsoa_lookup' AS tbl, COUNT(*) AS rows_with_cr
FROM stg.lsoa_lookup WHERE lad_name LIKE '%' + CHAR(13)
UNION ALL
SELECT 'imd_2025', COUNT(*) FROM stg.imd_2025 WHERE crime_decile LIKE '%' + CHAR(13)
UNION ALL
SELECT 'population_lsoa', COUNT(*) FROM stg.population_lsoa WHERE population LIKE '%' + CHAR(13);

/* ---------------------------------------------------------------------
   5. Do the crime data's neighbourhood codes match the lookup?
   LEFT JOIN keeps every crime; l.lsoa_code IS NULL means "no match".
   London boroughs all have codes starting E09.
   Expect: in_london about 3,415,182, outside_london about 13,030,
           no_location 12,550, not_in_lookup 0.
   ------------------------------------------------------------------- */
SELECT
    SUM(CASE WHEN l.lad_code LIKE 'E09%' THEN 1 ELSE 0 END)              AS in_london,
    SUM(CASE WHEN l.lad_code NOT LIKE 'E09%' THEN 1 ELSE 0 END)          AS outside_london,
    SUM(CASE WHEN NULLIF(c.lsoa_code, '') IS NULL THEN 1 ELSE 0 END)     AS no_location,
    SUM(CASE WHEN NULLIF(c.lsoa_code, '') IS NOT NULL
              AND l.lsoa_code IS NULL THEN 1 ELSE 0 END)                 AS not_in_lookup
FROM stg.crimes AS c
LEFT JOIN stg.lsoa_lookup AS l
       ON l.lsoa_code = c.lsoa_code;
