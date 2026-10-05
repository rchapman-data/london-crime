# Data quality notes

Findings from profiling the staging tables (Step 2). These feed the README's "Data quality and limitations" section.

## Load
- 72 crime files and 72 outcome files (36 months x Met + City of London) loaded with no rejected rows.
- Crimes: 3,440,762 rows (Met 3,412,646; City 28,116). Outcomes: 2,872,758 rows (Met 2,849,136; City 23,622).
- Monthly crime counts are steady (roughly 91k-103k), with no gaps.

## Crimes table
- **Anti-social behaviour (702,673 rows) has no Crime ID and no outcome.** Every other crime type has both. ASB can't be linked to outcomes.
- **Context** is empty in every row. Drop it.
- **No location:** 12,549 rows have no coordinates and 12,550 have no LSOA (about 0.4%). They count toward London-wide totals but can't be mapped to a borough.
- Month, latitude and longitude all convert cleanly to proper types.
- **Duplicate Crime IDs:** 21,564 IDs appear more than once. Some are identical copies; at least one has the same ID under two crime types. Under investigation (query 11).
- **LSOA boundaries:** the data uses 2021 LSOA codes (codes above E01033768 appear). Reference data must therefore use 2021 boundaries.
- **Outside London:** 11,042 distinct LSOAs appear, against roughly 5,000 in London. Met records include crimes located in other areas: neighbouring districts (Epping Forest, Dartford), places further away (Birmingham, Manchester) and some Welsh LSOAs (W01...). These are excluded from geographic analysis.
- **Query 12 totals:** 13,030 rows (0.4%) are located outside London, including 190 in Wales. A further 12,550 have no location. In total, 25,580 rows (0.7%) can't be assigned to a London borough. 4,981 distinct London LSOAs appear in the data, so almost every London neighbourhood is covered.

## Outcomes table
- **Every outcome matches a crime in the crimes table (0 orphans).** So the download only includes outcomes for crimes recorded from Sept 2023 onwards.
- That means outcome volumes in the early months are artificially low, because only very recent crimes could have an outcome yet. Example: Sept 2023 has 23,640 outcomes, against 60k-100k in later months. Analyse outcomes by the month of the *crime*, not the month of the outcome.
- The most recent crimes have had less time to reach an outcome (right-censoring).
- 12 outcome types. The largest are "Investigation complete; no suspect identified" (1.78m), "Unable to prosecute suspect" (770k) and "Suspect charged" (215k).
