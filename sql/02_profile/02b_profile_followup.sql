/* =====================================================================
   London Crime project - Step 2b: follow-up profiling
   Two questions raised by the first profiling pass.
   ===================================================================== */
USE LondonCrime;
GO

/* ---------------------------------------------------------------------
   11. What kind of duplicates are the 21,564 repeated Crime IDs?
   For each repeated ID, count how many rows it has and how many
   DIFFERENT values each column takes across those rows.
   If every "n_" column is 1, the rows are identical copies.
   If n_types is 2, the same crime appears under two crime types.
   ------------------------------------------------------------------- */
WITH per_id AS (
    SELECT crime_id,
           COUNT(*)                              AS n_rows,
           COUNT(DISTINCT crime_type)            AS n_types,
           COUNT(DISTINCT [month])               AS n_months,
           COUNT(DISTINCT location)              AS n_locations,
           COUNT(DISTINCT last_outcome_category) AS n_outcomes,
           COUNT(DISTINCT source_file)           AS n_files
    FROM stg.crimes
    WHERE NULLIF(crime_id, '') IS NOT NULL
    GROUP BY crime_id
    HAVING COUNT(*) > 1
)
SELECT n_rows, n_types, n_months, n_locations, n_outcomes, n_files,
       COUNT(*) AS ids
FROM per_id
GROUP BY n_rows, n_types, n_months, n_locations, n_outcomes, n_files
ORDER BY ids DESC;

/* ---------------------------------------------------------------------
   12. Outside London: totals rather than a list.
   - outside_london_rows: located in a non-London local authority
   - welsh_rows: LSOA codes starting W (Wales)
   - no_location_rows: no LSOA at all
   ------------------------------------------------------------------- */
WITH located AS (
    SELECT lsoa_code,
           CASE WHEN NULLIF(lsoa_name, '') IS NULL THEN NULL
                ELSE LEFT(lsoa_name, LEN(lsoa_name) - 5) END AS local_authority
    FROM stg.crimes
)
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN local_authority IS NOT NULL AND local_authority NOT IN (
        'City of London','Barking and Dagenham','Barnet','Bexley','Brent','Bromley',
        'Camden','Croydon','Ealing','Enfield','Greenwich','Hackney',
        'Hammersmith and Fulham','Haringey','Harrow','Havering','Hillingdon',
        'Hounslow','Islington','Kensington and Chelsea','Kingston upon Thames',
        'Lambeth','Lewisham','Merton','Newham','Redbridge','Richmond upon Thames',
        'Southwark','Sutton','Tower Hamlets','Waltham Forest','Wandsworth','Westminster'
    ) THEN 1 ELSE 0 END) AS outside_london_rows,
    SUM(CASE WHEN lsoa_code LIKE 'W%' THEN 1 ELSE 0 END) AS welsh_rows,
    SUM(CASE WHEN local_authority IS NULL THEN 1 ELSE 0 END) AS no_location_rows,
    COUNT(DISTINCT CASE WHEN local_authority IN (
        'City of London','Barking and Dagenham','Barnet','Bexley','Brent','Bromley',
        'Camden','Croydon','Ealing','Enfield','Greenwich','Hackney',
        'Hammersmith and Fulham','Haringey','Harrow','Havering','Hillingdon',
        'Hounslow','Islington','Kensington and Chelsea','Kingston upon Thames',
        'Lambeth','Lewisham','Merton','Newham','Redbridge','Richmond upon Thames',
        'Southwark','Sutton','Tower Hamlets','Waltham Forest','Wandsworth','Westminster'
    ) THEN lsoa_code END) AS london_lsoas   -- expect roughly 5,000
FROM located;
