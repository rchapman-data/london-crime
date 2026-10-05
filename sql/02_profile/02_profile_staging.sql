/* =====================================================================
   London Crime project - Step 2: profile the staging data
   ---------------------------------------------------------------------
   Profiling = getting to know the data before changing anything.
   Nothing in this script modifies data; it only looks.
   Run one numbered section at a time and note what you find -
   the findings go in the README's "data quality" section later.
   ===================================================================== */
USE LondonCrime;
GO

/* ---------------------------------------------------------------------
   1. Rows per month, per force (crimes)
   Looking for: gaps or months far smaller/larger than their neighbours.
   ------------------------------------------------------------------- */
SELECT [month],
       SUM(CASE WHEN falls_within LIKE 'Metropolitan%' THEN 1 ELSE 0 END) AS met_rows,
       SUM(CASE WHEN falls_within LIKE 'City of London%' THEN 1 ELSE 0 END) AS city_rows,
       COUNT(*) AS total_rows
FROM stg.crimes
GROUP BY [month]
ORDER BY [month];

/* ---------------------------------------------------------------------
   2. Same for outcomes - remember 'month' here is the month the OUTCOME
   was recorded, not when the crime happened.
   Looking for: confirming September 2023 is the unusually small month.
   ------------------------------------------------------------------- */
SELECT [month],
       SUM(CASE WHEN falls_within LIKE 'Metropolitan%' THEN 1 ELSE 0 END) AS met_rows,
       SUM(CASE WHEN falls_within LIKE 'City of London%' THEN 1 ELSE 0 END) AS city_rows,
       COUNT(*) AS total_rows
FROM stg.outcomes
GROUP BY [month]
ORDER BY [month];

/* ---------------------------------------------------------------------
   3. Missing values, column by column (crimes)
   NULLIF(x, '') turns an empty string into NULL, so this catches both
   "truly missing" and "empty text".
   ------------------------------------------------------------------- */
SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN NULLIF(crime_id, '')              IS NULL THEN 1 ELSE 0 END) AS missing_crime_id,
       SUM(CASE WHEN NULLIF(longitude, '')             IS NULL THEN 1 ELSE 0 END) AS missing_longitude,
       SUM(CASE WHEN NULLIF(latitude, '')              IS NULL THEN 1 ELSE 0 END) AS missing_latitude,
       SUM(CASE WHEN NULLIF(lsoa_code, '')             IS NULL THEN 1 ELSE 0 END) AS missing_lsoa,
       SUM(CASE WHEN NULLIF(crime_type, '')            IS NULL THEN 1 ELSE 0 END) AS missing_crime_type,
       SUM(CASE WHEN NULLIF(last_outcome_category, '') IS NULL THEN 1 ELSE 0 END) AS missing_outcome,
       SUM(CASE WHEN NULLIF(context, '')               IS NULL THEN 1 ELSE 0 END) AS missing_context
FROM stg.crimes;

/* ---------------------------------------------------------------------
   4. Crime types - how many of each, and how many have no Crime ID.
   Expectation: only Anti-social behaviour lacks a Crime ID.
   ------------------------------------------------------------------- */
SELECT crime_type,
       COUNT(*) AS row_count,
       SUM(CASE WHEN NULLIF(crime_id, '') IS NULL THEN 1 ELSE 0 END) AS no_crime_id
FROM stg.crimes
GROUP BY crime_type
ORDER BY row_count DESC;

/* ---------------------------------------------------------------------
   5. Duplicate Crime IDs - should each crime appear only once?
   ------------------------------------------------------------------- */
SELECT COUNT(*) AS ids_appearing_more_than_once
FROM (
    SELECT crime_id
    FROM stg.crimes
    WHERE NULLIF(crime_id, '') IS NOT NULL
    GROUP BY crime_id
    HAVING COUNT(*) > 1
) AS dupes;

-- If the number above isn't 0, look at a few examples:
SELECT TOP 20 c.*
FROM stg.crimes AS c
WHERE c.crime_id IN (
    SELECT crime_id FROM stg.crimes
    WHERE NULLIF(crime_id, '') IS NOT NULL
    GROUP BY crime_id HAVING COUNT(*) > 1
)
ORDER BY c.crime_id, c.[month];

/* ---------------------------------------------------------------------
   6. Can every value be converted to its proper type?
   TRY_CAST attempts a conversion and returns NULL instead of an error
   if it fails - so counting NULLs counts the bad values.
   ------------------------------------------------------------------- */
SELECT
    SUM(CASE WHEN TRY_CAST([month] + '-01' AS DATE) IS NULL THEN 1 ELSE 0 END) AS bad_month,
    SUM(CASE WHEN NULLIF(longitude, '') IS NOT NULL
              AND TRY_CAST(longitude AS DECIMAL(9,6)) IS NULL THEN 1 ELSE 0 END) AS bad_longitude,
    SUM(CASE WHEN NULLIF(latitude, '') IS NOT NULL
              AND TRY_CAST(latitude AS DECIMAL(9,6)) IS NULL THEN 1 ELSE 0 END) AS bad_latitude
FROM stg.crimes;

/* ---------------------------------------------------------------------
   7. Which LSOA boundary version does the data use?
   2011-boundary codes run up to E01033768. Codes above that only
   exist in the 2021 boundaries - if any appear, the data is 2021-based.
   ------------------------------------------------------------------- */
SELECT MIN(lsoa_code) AS min_code,
       MAX(lsoa_code) AS max_code,
       COUNT(DISTINCT lsoa_code) AS distinct_lsoas,
       COUNT(DISTINCT CASE WHEN lsoa_code > 'E01033768' THEN lsoa_code END) AS codes_only_in_2021
FROM stg.crimes
WHERE NULLIF(lsoa_code, '') IS NOT NULL;

/* ---------------------------------------------------------------------
   8. How many crimes are located outside London?
   An LSOA name is "<local authority> <3 digits><letter>", e.g. "Camden 027B".
   Chopping off the last 5 characters leaves the local authority name.
   The list below is the 32 London boroughs + City of London.
   ------------------------------------------------------------------- */
WITH located AS (
    SELECT LEFT(lsoa_name, LEN(lsoa_name) - 5) AS local_authority
    FROM stg.crimes
    WHERE NULLIF(lsoa_name, '') IS NOT NULL
)
SELECT local_authority,
       COUNT(*) AS row_count
FROM located
WHERE local_authority NOT IN (
    'City of London','Barking and Dagenham','Barnet','Bexley','Brent','Bromley',
    'Camden','Croydon','Ealing','Enfield','Greenwich','Hackney',
    'Hammersmith and Fulham','Haringey','Harrow','Havering','Hillingdon',
    'Hounslow','Islington','Kensington and Chelsea','Kingston upon Thames',
    'Lambeth','Lewisham','Merton','Newham','Redbridge','Richmond upon Thames',
    'Southwark','Sutton','Tower Hamlets','Waltham Forest','Wandsworth','Westminster'
)
GROUP BY local_authority
ORDER BY row_count DESC;

/* ---------------------------------------------------------------------
   9. Outcomes that don't match any crime in our data ("orphans").
   A LEFT JOIN keeps every outcome, and fills the crime columns with NULL
   when there's no match - so c.crime_id IS NULL means "no matching crime".
   Expectation: many orphans in early months (crimes from before Sept 2023).
   ------------------------------------------------------------------- */
SELECT o.[month] AS outcome_month,
       COUNT(*) AS outcomes,
       SUM(CASE WHEN c.crime_id IS NULL THEN 1 ELSE 0 END) AS orphans,
       CAST(100.0 * SUM(CASE WHEN c.crime_id IS NULL THEN 1 ELSE 0 END) / COUNT(*)
            AS DECIMAL(5,1)) AS pct_orphans
FROM stg.outcomes AS o
LEFT JOIN (SELECT DISTINCT crime_id FROM stg.crimes
           WHERE NULLIF(crime_id, '') IS NOT NULL) AS c
       ON c.crime_id = o.crime_id
GROUP BY o.[month]
ORDER BY o.[month];

/* ---------------------------------------------------------------------
   10. Outcome types - what categories exist, and how common are they?
   ------------------------------------------------------------------- */
SELECT outcome_type, COUNT(*) AS row_count
FROM stg.outcomes
GROUP BY outcome_type
ORDER BY row_count DESC;
