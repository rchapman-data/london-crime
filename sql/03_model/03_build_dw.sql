/* =====================================================================
   London Crime project - Step 3: build the clean star schema (dw)
   ---------------------------------------------------------------------
   Reads from the staging tables (stg) and builds the tables used for
   analysis in a separate schema, dw ("data warehouse").

   Decisions applied here (see docs/data_quality_notes.md):
   - Crimes located outside London are excluded (13,030 rows).
   - Crimes with no location are KEPT (they count towards London totals,
     but have no neighbourhood/borough).
   - Exact duplicate crime rows are removed; other repeated Crime IDs kept.
   - Each crime row gets its own key (crime_key); crime_id is not unique.
   - Inner/outer London uses the ONS statistical definition.
   - Robbery is its own crime group.

   Run one numbered section at a time, in order.
   The script can be re-run from the top: it drops and rebuilds everything.
   ===================================================================== */
USE LondonCrime;
GO

/* ---------------------------------------------------------------------
   0. Schema
   ------------------------------------------------------------------- */
IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
GO

-- Drop in reverse order of dependency: facts first (they point at the
-- dimensions), then the dimensions they point at.
DROP TABLE IF EXISTS dw.fact_outcome;
DROP TABLE IF EXISTS dw.fact_crime;
DROP TABLE IF EXISTS dw.lsoa_population;
DROP TABLE IF EXISTS dw.dim_lsoa;
DROP TABLE IF EXISTS dw.dim_borough;
DROP TABLE IF EXISTS dw.dim_outcome_type;
DROP TABLE IF EXISTS dw.dim_crime_type;
DROP TABLE IF EXISTS dw.dim_month;
GO

/* ---------------------------------------------------------------------
   1. dim_month - one row per month (expect 36)
   month_key is a number like 202309, which is easy to read and sort.
   period splits the 36 months into three 12-month years (Sep-Aug).
   ------------------------------------------------------------------- */
CREATE TABLE dw.dim_month (
    month_key     INT          NOT NULL PRIMARY KEY,
    month_start   DATE         NOT NULL,
    [year]        SMALLINT     NOT NULL,
    month_number  TINYINT      NOT NULL,
    month_name    VARCHAR(10)  NOT NULL,
    period_number TINYINT      NOT NULL,
    period_label  VARCHAR(20)  NOT NULL
);

WITH months AS (
    SELECT [month] FROM stg.crimes
    UNION                      -- UNION (not UNION ALL) removes duplicates
    SELECT [month] FROM stg.outcomes
)
INSERT INTO dw.dim_month
SELECT YEAR(d) * 100 + MONTH(d),
       d,
       YEAR(d),
       MONTH(d),
       DATENAME(MONTH, d),
       CASE WHEN d < '2024-09-01' THEN 1
            WHEN d < '2025-09-01' THEN 2
            ELSE 3 END,
       CASE WHEN d < '2024-09-01' THEN 'Sep 2023 - Aug 2024'
            WHEN d < '2025-09-01' THEN 'Sep 2024 - Aug 2025'
            ELSE 'Sep 2025 - Aug 2026' END
FROM months
CROSS APPLY (SELECT CAST([month] + '-01' AS DATE) AS d) AS x;
GO

/* ---------------------------------------------------------------------
   2. dim_crime_type - the 14 crime types, with broader groups
   IDENTITY(1,1) makes SQL Server number the rows automatically: 1, 2, 3...
   ------------------------------------------------------------------- */
CREATE TABLE dw.dim_crime_type (
    crime_type_key  INT IDENTITY(1,1) PRIMARY KEY,
    crime_type      NVARCHAR(100) NOT NULL UNIQUE,
    crime_group     NVARCHAR(50)  NOT NULL,
    has_outcomes    BIT           NOT NULL
);

INSERT INTO dw.dim_crime_type (crime_type, crime_group, has_outcomes)
SELECT crime_type,
       CASE
           WHEN crime_type = 'Violence and sexual offences' THEN 'Violence'
           WHEN crime_type = 'Robbery' THEN 'Robbery'
           WHEN crime_type IN ('Burglary', 'Vehicle crime', 'Theft from the person',
                               'Shoplifting', 'Bicycle theft', 'Other theft')
                THEN 'Theft and acquisitive'
           WHEN crime_type IN ('Criminal damage and arson', 'Public order')
                THEN 'Damage and disorder'
           WHEN crime_type IN ('Drugs', 'Possession of weapons')
                THEN 'Drugs and weapons'
           WHEN crime_type = 'Anti-social behaviour' THEN 'Anti-social behaviour'
           ELSE 'Other'
       END,
       CASE WHEN crime_type = 'Anti-social behaviour' THEN 0 ELSE 1 END
FROM (SELECT DISTINCT crime_type FROM stg.crimes) AS t
ORDER BY crime_type;
GO

/* ---------------------------------------------------------------------
   3. dim_outcome_type - every outcome category, from both the outcomes
   file and the crimes file's "last outcome" column, with groups.
   Anything not matched lands in 'Unclassified' - check section 10.
   ------------------------------------------------------------------- */
CREATE TABLE dw.dim_outcome_type (
    outcome_type_key INT IDENTITY(1,1) PRIMARY KEY,
    outcome_type     NVARCHAR(200) NOT NULL UNIQUE,
    outcome_group    NVARCHAR(50)  NOT NULL,
    is_charge        BIT           NOT NULL   -- 1 = suspect charged / went to court
);

WITH all_outcomes AS (
    SELECT outcome_type AS outcome_type FROM stg.outcomes
    WHERE NULLIF(outcome_type, '') IS NOT NULL
    UNION
    SELECT last_outcome_category FROM stg.crimes
    WHERE NULLIF(last_outcome_category, '') IS NOT NULL
),
grouped AS (
    SELECT outcome_type,
           CASE
               -- out-of-court action (checked first, because some of these
               -- also start with 'Offender given')
               WHEN outcome_type IN ('Offender given a caution',
                                     'Offender given penalty notice',
                                     'Offender given a drugs possession warning',
                                     'Local resolution')
                    THEN 'Out-of-court action'
               -- charged, or at/after court
               WHEN outcome_type IN ('Suspect charged',
                                     'Suspect charged as part of another case',
                                     'Awaiting court outcome',
                                     'Court result unavailable')
                 OR outcome_type LIKE 'Offender%'
                 OR outcome_type LIKE 'Defendant%'
                 OR outcome_type LIKE 'Court case%'
                    THEN 'Charged'
               WHEN outcome_type = 'Investigation complete; no suspect identified'
                    THEN 'No suspect identified'
               WHEN outcome_type IN ('Unable to prosecute suspect',
                                     'Formal action is not in the public interest',
                                     'Further investigation is not in the public interest',
                                     'Further action is not in the public interest')
                    THEN 'Suspect identified, not proceeded'
               WHEN outcome_type = 'Action to be taken by another organisation'
                    THEN 'Passed elsewhere'
               WHEN outcome_type IN ('Under investigation', 'Status update unavailable')
                    THEN 'Pending or unknown'
               ELSE 'Unclassified'
           END AS outcome_group
    FROM all_outcomes
)
INSERT INTO dw.dim_outcome_type (outcome_type, outcome_group, is_charge)
SELECT outcome_type,
       outcome_group,
       CASE WHEN outcome_group = 'Charged' THEN 1 ELSE 0 END
FROM grouped
ORDER BY outcome_group, outcome_type;
GO

/* ---------------------------------------------------------------------
   4. dim_borough - the 32 London boroughs + City of London (expect 33)
   London borough codes all start E09. Inner/outer = ONS definition.
   ------------------------------------------------------------------- */
CREATE TABLE dw.dim_borough (
    borough_code  VARCHAR(9)    NOT NULL PRIMARY KEY,
    borough_name  NVARCHAR(100) NOT NULL,
    inner_outer   VARCHAR(5)    NOT NULL
);

INSERT INTO dw.dim_borough
SELECT DISTINCT
       lad_code,
       lad_name,
       CASE WHEN lad_name IN ('City of London', 'Camden', 'Hackney',
                              'Hammersmith and Fulham', 'Haringey', 'Islington',
                              'Kensington and Chelsea', 'Lambeth', 'Lewisham',
                              'Newham', 'Southwark', 'Tower Hamlets',
                              'Wandsworth', 'Westminster')
            THEN 'Inner' ELSE 'Outer' END
FROM stg.lsoa_lookup
WHERE lad_code LIKE 'E09%';
GO

/* ---------------------------------------------------------------------
   5. dim_lsoa - every neighbourhood in England and Wales (expect 35,672)
   borough_code is filled only for London; lad_code/lad_name are kept for
   everywhere. Deprivation is England only, so Welsh rows have NULLs.
   ------------------------------------------------------------------- */
CREATE TABLE dw.dim_lsoa (
    lsoa_code          VARCHAR(9)    NOT NULL PRIMARY KEY,
    lsoa_name          NVARCHAR(100) NOT NULL,
    ward_code          VARCHAR(9)    NULL,
    ward_name          NVARCHAR(100) NULL,
    lad_code           VARCHAR(9)    NOT NULL,
    lad_name           NVARCHAR(100) NOT NULL,
    borough_code       VARCHAR(9)    NULL
        REFERENCES dw.dim_borough (borough_code),   -- foreign key
    is_london          BIT           NOT NULL,
    imd_rank           INT NULL,  imd_decile        TINYINT NULL,
    income_rank        INT NULL,  income_decile     TINYINT NULL,
    employment_rank    INT NULL,  employment_decile TINYINT NULL,
    crime_rank         INT NULL,  crime_decile      TINYINT NULL
);

INSERT INTO dw.dim_lsoa
SELECT l.lsoa_code,
       l.lsoa_name,
       l.ward_code,
       l.ward_name,
       l.lad_code,
       l.lad_name,
       CASE WHEN l.lad_code LIKE 'E09%' THEN l.lad_code END,
       CASE WHEN l.lad_code LIKE 'E09%' THEN 1 ELSE 0 END,
       CAST(i.imd_rank AS INT),          CAST(i.imd_decile AS TINYINT),
       CAST(i.income_rank AS INT),       CAST(i.income_decile AS TINYINT),
       CAST(i.employment_rank AS INT),   CAST(i.employment_decile AS TINYINT),
       CAST(i.crime_rank AS INT),        CAST(i.crime_decile AS TINYINT)
FROM stg.lsoa_lookup AS l
LEFT JOIN stg.imd_2025 AS i
       ON i.lsoa_code = l.lsoa_code;
GO

/* ---------------------------------------------------------------------
   6. lsoa_population - one row per neighbourhood per mid-year
   The primary key is the PAIR (lsoa_code, mid_year): a "composite key".
   ------------------------------------------------------------------- */
CREATE TABLE dw.lsoa_population (
    lsoa_code   VARCHAR(9) NOT NULL REFERENCES dw.dim_lsoa (lsoa_code),
    mid_year    SMALLINT   NOT NULL,
    population  INT        NOT NULL,
    PRIMARY KEY (lsoa_code, mid_year)
);

INSERT INTO dw.lsoa_population
SELECT lsoa_code, CAST(mid_year AS SMALLINT), CAST(population AS INT)
FROM stg.population_lsoa;
GO

/* ---------------------------------------------------------------------
   7. fact_crime - one row per crime record
   - exact duplicate rows with a Crime ID are removed
   - anti-social behaviour rows (no Crime ID) are all kept
   - crimes located outside London are excluded
   - crimes with no location are kept (lsoa_code NULL)
   This is the slow one: expect a minute or two.
   ------------------------------------------------------------------- */
CREATE TABLE dw.fact_crime (
    crime_key        INT IDENTITY(1,1) PRIMARY KEY,
    crime_id         VARCHAR(64)   NULL,      -- NULL for anti-social behaviour
    month_key        INT           NOT NULL REFERENCES dw.dim_month (month_key),
    police_force     VARCHAR(30)   NOT NULL,
    crime_type_key   INT           NOT NULL REFERENCES dw.dim_crime_type (crime_type_key),
    lsoa_code        VARCHAR(9)    NULL     REFERENCES dw.dim_lsoa (lsoa_code),
    latitude         DECIMAL(9,6)  NULL,
    longitude        DECIMAL(9,6)  NULL,
    location         NVARCHAR(200) NULL,
    last_outcome_key INT           NULL     REFERENCES dw.dim_outcome_type (outcome_type_key)
);

-- Exact duplicates are only removed for rows WITH a Crime ID.
-- Anti-social behaviour has no Crime ID, so two separate incidents in the
-- same month at the same (anonymised) map point look identical - those are
-- real, separate incidents and must all be kept. Hence two halves:
WITH deduped AS (
    -- (a) crimes with an ID: DISTINCT removes exact duplicate rows
    SELECT DISTINCT
           NULLIF(crime_id, '')              AS crime_id,
           [month],
           falls_within,
           crime_type,
           NULLIF(lsoa_code, '')             AS lsoa_code,
           NULLIF(latitude, '')              AS latitude,
           NULLIF(longitude, '')             AS longitude,
           NULLIF(location, '')              AS location,
           NULLIF(last_outcome_category, '') AS last_outcome_category
    FROM stg.crimes
    WHERE NULLIF(crime_id, '') IS NOT NULL

    UNION ALL   -- stack the two halves; ALL = don't remove anything

    -- (b) rows without an ID (anti-social behaviour): keep every row
    SELECT NULL,
           [month],
           falls_within,
           crime_type,
           NULLIF(lsoa_code, ''),
           NULLIF(latitude, ''),
           NULLIF(longitude, ''),
           NULLIF(location, ''),
           NULLIF(last_outcome_category, '')
    FROM stg.crimes
    WHERE NULLIF(crime_id, '') IS NULL
)
INSERT INTO dw.fact_crime (crime_id, month_key, police_force, crime_type_key,
                           lsoa_code, latitude, longitude, location, last_outcome_key)
SELECT d.crime_id,
       CAST(LEFT(d.[month], 4) AS INT) * 100 + CAST(RIGHT(d.[month], 2) AS INT),
       CASE WHEN d.falls_within LIKE 'Metropolitan%' THEN 'Metropolitan Police'
            ELSE 'City of London Police' END,
       ct.crime_type_key,
       d.lsoa_code,
       CAST(d.latitude  AS DECIMAL(9,6)),
       CAST(d.longitude AS DECIMAL(9,6)),
       d.location,
       ot.outcome_type_key
FROM deduped AS d
JOIN dw.dim_crime_type AS ct
     ON ct.crime_type = d.crime_type
LEFT JOIN dw.dim_outcome_type AS ot
     ON ot.outcome_type = d.last_outcome_category
LEFT JOIN dw.dim_lsoa AS l
     ON l.lsoa_code = d.lsoa_code
WHERE d.lsoa_code IS NULL          -- no location: keep
   OR l.is_london = 1;             -- located in London: keep
GO

/* ---------------------------------------------------------------------
   8. fact_outcome - one row per outcome event
   Only outcomes for crimes that are in fact_crime (i.e. London crimes).
   Linked to fact_crime by crime_id - not a formal foreign key, because
   crime_id is not unique in fact_crime.
   ------------------------------------------------------------------- */
CREATE TABLE dw.fact_outcome (
    outcome_key       INT IDENTITY(1,1) PRIMARY KEY,
    crime_id          VARCHAR(64) NOT NULL,
    outcome_month_key INT         NOT NULL REFERENCES dw.dim_month (month_key),
    outcome_type_key  INT         NOT NULL REFERENCES dw.dim_outcome_type (outcome_type_key)
);

INSERT INTO dw.fact_outcome (crime_id, outcome_month_key, outcome_type_key)
SELECT o.crime_id,
       CAST(LEFT(o.[month], 4) AS INT) * 100 + CAST(RIGHT(o.[month], 2) AS INT),
       ot.outcome_type_key
FROM stg.outcomes AS o
JOIN dw.dim_outcome_type AS ot
     ON ot.outcome_type = o.outcome_type
WHERE EXISTS (SELECT 1 FROM dw.fact_crime AS f WHERE f.crime_id = o.crime_id);
GO

/* ---------------------------------------------------------------------
   9. Indexes - like the index at the back of a book: they let SQL Server
   jump to matching rows instead of reading all 3.4 million.
   One on each column we'll often filter or join on.
   ------------------------------------------------------------------- */
CREATE INDEX ix_fact_crime_month      ON dw.fact_crime (month_key);
CREATE INDEX ix_fact_crime_type       ON dw.fact_crime (crime_type_key);
CREATE INDEX ix_fact_crime_lsoa       ON dw.fact_crime (lsoa_code);
CREATE INDEX ix_fact_crime_crime_id   ON dw.fact_crime (crime_id);
CREATE INDEX ix_fact_outcome_crime_id ON dw.fact_outcome (crime_id);
CREATE INDEX ix_fact_outcome_month    ON dw.fact_outcome (outcome_month_key);
GO

/* ---------------------------------------------------------------------
   10. Checks
   ------------------------------------------------------------------- */
-- a) Row counts.
--    Expect: dim_month 36, dim_crime_type 14, dim_borough 33,
--    dim_lsoa 35,672, lsoa_population 107,016,
--    fact_crime a little under 3,427,732 (3,440,762 minus 13,030 outside
--    London, minus the exact duplicates).
SELECT 'dim_month' AS tbl, COUNT(*) AS row_count FROM dw.dim_month
UNION ALL SELECT 'dim_crime_type',   COUNT(*) FROM dw.dim_crime_type
UNION ALL SELECT 'dim_outcome_type', COUNT(*) FROM dw.dim_outcome_type
UNION ALL SELECT 'dim_borough',      COUNT(*) FROM dw.dim_borough
UNION ALL SELECT 'dim_lsoa',         COUNT(*) FROM dw.dim_lsoa
UNION ALL SELECT 'lsoa_population',  COUNT(*) FROM dw.lsoa_population
UNION ALL SELECT 'fact_crime',       COUNT(*) FROM dw.fact_crime
UNION ALL SELECT 'fact_outcome',     COUNT(*) FROM dw.fact_outcome;

-- b) Where did the staging rows go? (an audit trail for the README)
SELECT
    (SELECT COUNT(*) FROM stg.crimes)    AS staging_rows,
    (SELECT COUNT(*) FROM dw.fact_crime) AS fact_rows,
    (SELECT COUNT(*) FROM stg.crimes) - (SELECT COUNT(*) FROM dw.fact_crime)
        AS rows_removed;    -- expect roughly 15,000: 13,030 outside London
                            -- plus about 2,000 exact duplicates

-- c) Outcome types and their groups - check nothing says 'Unclassified'
SELECT outcome_group, outcome_type, is_charge
FROM dw.dim_outcome_type
ORDER BY outcome_group, outcome_type;

-- d) Inner/outer: expect 14 Inner and 19 Outer
SELECT inner_outer, COUNT(*) AS boroughs
FROM dw.dim_borough
GROUP BY inner_outer;

-- e) Crime groups
SELECT crime_group, crime_type, has_outcomes
FROM dw.dim_crime_type
ORDER BY crime_group, crime_type;

-- f) Exact duplicate OUTCOME rows - we haven't profiled these yet.
--    Not removed; just counted, to decide on later.
SELECT COUNT(*) AS duplicate_outcome_groups
FROM (
    SELECT crime_id, outcome_month_key, outcome_type_key
    FROM dw.fact_outcome
    GROUP BY crime_id, outcome_month_key, outcome_type_key
    HAVING COUNT(*) > 1
) AS d;
