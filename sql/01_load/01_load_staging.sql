/* =====================================================================
   London Crime project - Step 1: load raw CSVs into staging tables
   ---------------------------------------------------------------------
   Staging = a rough first copy of the raw files. Every column is text,
   so the import can't fail on a badly formatted value. Cleaning and
   proper data types come later (02_clean).
   ===================================================================== */

-- 0. Check your version: FORMAT = 'CSV' below needs SQL Server 2017 or later
SELECT @@VERSION;
GO

-- 1. Create the database
CREATE DATABASE LondonCrime;
GO

-- SIMPLE recovery = SQL Server doesn't keep a full history of every change.
-- Without this, loading ~1.7 GB can bloat the log file to many GB.
ALTER DATABASE LondonCrime SET RECOVERY SIMPLE;
GO

USE LondonCrime;
GO

-- 2. A schema is like a folder inside the database.
--    'stg' holds raw staging tables; the clean tables will go in 'dbo' later.
CREATE SCHEMA stg;
GO

-- 3. Staging tables: same columns as the CSVs, in the same order, all text.
--    Lengths are generous on purpose; if a value is too long, the load will
--    say so and the bad rows will land in the error file.
DROP TABLE IF EXISTS stg.crimes;
CREATE TABLE stg.crimes (
    crime_id              NVARCHAR(100),
    [month]               NVARCHAR(20),
    reported_by           NVARCHAR(100),
    falls_within          NVARCHAR(100),
    longitude             NVARCHAR(50),
    latitude              NVARCHAR(50),
    location              NVARCHAR(400),
    lsoa_code             NVARCHAR(20),
    lsoa_name             NVARCHAR(200),
    crime_type            NVARCHAR(200),
    last_outcome_category NVARCHAR(400),
    context               NVARCHAR(4000),
    source_file           NVARCHAR(200)
);

DROP TABLE IF EXISTS stg.outcomes;
CREATE TABLE stg.outcomes (
    crime_id       NVARCHAR(100),
    [month]        NVARCHAR(20),
    reported_by    NVARCHAR(100),
    falls_within   NVARCHAR(100),
    longitude      NVARCHAR(50),
    latitude       NVARCHAR(50),
    location       NVARCHAR(400),
    lsoa_code      NVARCHAR(20),
    lsoa_name      NVARCHAR(200),
    outcome_type   NVARCHAR(400),
    source_file    NVARCHAR(200)
);
GO

-- 4. Load the files.
--    FORMAT = 'CSV'     understands quoted values containing commas
--    FIRSTROW = 2       skip the header row
--    CODEPAGE = '65001' the files are UTF-8
--    ROWTERMINATOR      '\n' here means Windows line endings (\r\n)
--    TABLOCK            locks the whole table while loading = much faster
--    MAXERRORS/ERRORFILE  log up to 100 bad rows to a file instead of stopping at the first
--                       (the error file must NOT already exist - delete it before re-running)
--
--    IMPORTANT: the paths are read by the SQL Server service, not by you.
--    If you get "Operating system error code 5 (Access is denied)", see the note in chat.

BULK INSERT stg.crimes
FROM 'C:\Users\rccha\Data Projects\London Crime\combined\crimes_combined.csv'
WITH (
    FORMAT = 'CSV',
    FIRSTROW = 2,
    CODEPAGE = '65001',
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    TABLOCK,
    MAXERRORS = 100,
    ERRORFILE = 'C:\Users\rccha\Data Projects\London Crime\combined\crimes_errors.log'
);

BULK INSERT stg.outcomes
FROM 'C:\Users\rccha\Data Projects\London Crime\combined\outcomes_combined.csv'
WITH (
    FORMAT = 'CSV',
    FIRSTROW = 2,
    CODEPAGE = '65001',
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    TABLOCK,
    MAXERRORS = 100,
    ERRORFILE = 'C:\Users\rccha\Data Projects\London Crime\combined\outcomes_errors.log'
);
GO

-- 5. Sanity checks
-- Row counts: compare with what combine_datasets.py printed
SELECT 'crimes' AS tbl, COUNT(*) AS row_count FROM stg.crimes
UNION ALL
SELECT 'outcomes', COUNT(*) FROM stg.outcomes;

-- Rows per source file: expect 72 files each (36 months x 2 forces)
-- for crimes; outcomes may be 72 too
SELECT source_file, COUNT(*) AS row_count
FROM stg.crimes
GROUP BY source_file
ORDER BY source_file;

-- Eyeball a few rows: do the columns line up?
SELECT TOP 20 * FROM stg.crimes;
SELECT TOP 20 * FROM stg.outcomes;

-- Line-ending check: if this returns rows, a hidden carriage return (\r)
-- got stuck on the end of the last column and the ROWTERMINATOR needs changing
SELECT TOP 5 source_file
FROM stg.crimes
WHERE source_file LIKE '%' + CHAR(13);



-- One row per police force for each table: how many files, plus the smallest and largest month
WITH per_file AS (
    SELECT 'crimes' AS tbl, falls_within, source_file, COUNT(*) AS row_count
    FROM stg.crimes
    GROUP BY falls_within, source_file
    UNION ALL
    SELECT 'outcomes', falls_within, source_file, COUNT(*)
    FROM stg.outcomes
    GROUP BY falls_within, source_file
)
SELECT tbl,
       falls_within,
       COUNT(*)       AS files,        -- expect 36 for each
       SUM(row_count) AS total_rows,
       MIN(row_count) AS smallest_month,
       MAX(row_count) AS largest_month
FROM per_file
GROUP BY tbl, falls_within
ORDER BY tbl, falls_within;