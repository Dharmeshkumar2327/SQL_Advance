# Sample output

*Full console output of `./run_all.sh --regenerate` on PostgreSQL 16 (GST Reconciliation Engine, by Dharmesh Kumar).*

```text
==> Generating synthetic data
suppliers           : 120
purchase register   : 4772 rows (incl. 10 junk)
gstr-2b             : 4720 rows
ground truth labels : 9492
deleted vouchers    : 16 (gaps planted)
==> (Re)creating database gst_recon
==> Running sql/00_setup.sql
>> 00_setup: creating schemas and extensions
==> Running sql/01_functions.sql
>> 01_functions: GSTIN validation, invoice normalisation, GST calendar
==> Running sql/02_schema.sql
>> 02_schema: tables, constraints, indexes, reference data
==> Running sql/03_load.sql
>> 03_load: loading CSVs into staging
>> 03_load: validating and promoting to core tables
    table_name     | rows 
-------------------+------
 suppliers         |  120
 purchase_register | 4762
 gstr2b            | 4720
 load_rejects      |   10
(4 rows)

==> Running sql/04_matching_engine.sql
>> 04_matching_engine: creating gst.run_reconciliation()
>> 04_matching_engine: executing reconciliation for FY 2025-26
NOTICE: Run 1 started for FY 2025-26 (tolerance Rs 10, edit distance 2, window 3 days)
NOTICE:   P0 duplicates      : 45 rows
NOTICE:   P1 exact key       : 4366 pairs
NOTICE:   P2 fuzzy invoice # : 133 pairs
NOTICE:   P3 GSTIN correction: 68 pairs
NOTICE:   P4 unmatched       : 150 books-only, 153 2B-only
NOTICE:   POST ineligible ITC: 35 pairs re-flagged
NOTICE: Run 1 finished.
 p_run_id 
----------
        1
(1 row)

 run_id | financial_year | pr_records | b2b_records | result_rows | seconds |              pass_log               
--------+----------------+------------+-------------+-------------+---------+-------------------------------------
      1 | 2025-26        |       4762 |        4720 |        4915 |    0.44 | [                                  +
        |                |            |             |             |         |     {                              +
        |                |            |             |             |         |         "ms": 13,                  +
        |                |            |             |             |         |         "pass": "P0_DUPLICATE",    +
        |                |            |             |             |         |         "rows": 45                 +
        |                |            |             |             |         |     },                             +
        |                |            |             |             |         |     {                              +
        |                |            |             |             |         |         "ms": 139,                 +
        |                |            |             |             |         |         "pass": "P1_EXACT_KEY",    +
        |                |            |             |             |         |         "rows": 4366               +
        |                |            |             |             |         |     },                             +
        |                |            |             |             |         |     {                              +
        |                |            |             |             |         |         "ms": 12,                  +
        |                |            |             |             |         |         "pass": "P2_FUZZY_INVNO",  +
        |                |            |             |             |         |         "rows": 133                +
        |                |            |             |             |         |     },                             +
        |                |            |             |             |         |     {                              +
        |                |            |             |             |         |         "ms": 5,                   +
        |                |            |             |             |         |         "pass": "P3_GSTIN_FIX",    +
        |                |            |             |             |         |         "rows": 68                 +
        |                |            |             |             |         |     },                             +
        |                |            |             |             |         |     {                              +
        |                |            |             |             |         |         "ms": 6,                   +
        |                |            |             |             |         |         "pass": "P4_UNMATCHED",    +
        |                |            |             |             |         |         "rows": 303                +
        |                |            |             |             |         |     },                             +
        |                |            |             |             |         |     {                              +
        |                |            |             |             |         |         "pass": "POST_ELIGIBILITY",+
        |                |            |             |             |         |         "rows": 35                 +
        |                |            |             |             |         |     }                              +
        |                |            |             |             |         | ]
(1 row)

==> Running sql/05_reports.sql
>> 05_reports: creating reporting views

================ RECONCILIATION SUMMARY ================
 status_group |       match_status       | records | pct_records |  itc_books  |   itc_2b    | itc_at_risk | itc_unclaimed | itc_reversal 
--------------+--------------------------+---------+-------------+-------------+-------------+-------------+---------------+--------------
 MATCHED      | MATCHED                  |    3664 |       74.55 | 32597891.01 | 32597891.01 |        0.00 |          0.00 |         0.00
 MATCHED      | MATCHED_TOLERANCE        |     184 |        3.74 |  2069253.75 |  2069253.75 |        0.00 |          0.00 |         0.00
 MATCHED      | MATCHED_DATE_DIFF        |     162 |        3.30 |  1331926.28 |  1331926.28 |        0.00 |          0.00 |         0.00
 MATCHED      | MATCHED_FUZZY_INVNO      |     133 |        2.71 |  1096823.95 |  1096823.95 |        0.00 |          0.00 |         0.00
 MATCHED      | MATCHED_GSTIN_CORRECTION |      68 |        1.38 |   743351.95 |   743351.95 |        0.00 |          0.00 |         0.00
 MATCHED      | (subtotal)               |    4211 |       85.68 | 37839246.94 | 37839246.94 |        0.00 |          0.00 |         0.00
 TIMING       | MATCHED_CROSS_PERIOD     |     171 |        3.48 |  1445517.45 |  1445517.45 |        0.00 |          0.00 |         0.00
 TIMING       | (subtotal)               |     171 |        3.48 |  1445517.45 |  1445517.45 |        0.00 |          0.00 |         0.00
 MISMATCH     | MISMATCH_VALUE           |     103 |        2.10 |   703052.98 |   666514.94 |   107124.04 |      70586.00 |         0.00
 MISMATCH     | MISMATCH_TAX_HEAD        |      47 |        0.96 |   396524.29 |   396524.29 |   396524.29 |          0.00 |         0.00
 MISMATCH     | (subtotal)               |     150 |        3.05 |  1099577.27 |  1063039.23 |   503648.33 |      70586.00 |         0.00
 MISSING      | MISSING_IN_BOOKS         |     123 |        2.50 |        0.00 |  1224578.10 |        0.00 |    1224578.10 |         0.00
 MISSING      | CREDIT_NOTE_NOT_BOOKED   |      30 |        0.61 |        0.00 |   -66768.77 |        0.00 |          0.00 |     66768.77
 MISSING      | MISSING_IN_2B            |     150 |        3.05 |  1251385.28 |        0.00 |  1251385.28 |          0.00 |         0.00
 MISSING      | (subtotal)               |     303 |        6.16 |  1251385.28 |  1157809.33 |  1251385.28 |    1224578.10 |     66768.77
 COMPLIANCE   | DUPLICATE_IN_BOOKS       |      45 |        0.92 |   396069.24 |        0.00 |        0.00 |          0.00 |    396069.24
 COMPLIANCE   | ITC_INELIGIBLE           |      35 |        0.71 |   262961.14 |        0.00 |   262961.14 |          0.00 |         0.00
 COMPLIANCE   | (subtotal)               |      80 |        1.63 |   659030.38 |        0.00 |   262961.14 |          0.00 |    396069.24
 TOTAL        |                          |    4915 |      100.00 | 42294757.32 | 41505612.95 |  2017994.75 |    1295164.10 |    462838.01
(19 rows)

==> Running sql/06_advanced_analytics.sql
>> 06_advanced_analytics

---- Q1. Month x status pivot (record counts) ----
 period  | matched | timing | mismatch | missing_in_2b | missing_in_books | compliance | match_rate_pct 
---------+---------+--------+----------+---------------+------------------+------------+----------------
 2025-04 |     333 |     10 |       14 |             9 |               12 |          5 |           86.9
 2025-05 |     358 |     11 |        9 |            17 |               15 |          4 |           86.5
 2025-06 |     332 |     17 |       11 |            15 |               14 |         10 |           83.2
 2025-07 |     347 |     16 |       14 |            11 |                9 |          6 |           86.1
 2025-08 |     341 |     16 |       12 |            14 |               14 |          9 |           84.0
 2025-09 |     325 |     18 |       11 |            17 |               12 |          4 |           84.0
 2025-10 |     378 |     13 |       14 |            16 |               16 |          6 |           85.3
 2025-11 |     316 |     12 |       10 |            10 |                8 |          6 |           87.3
 2025-12 |     350 |     20 |       14 |             9 |               19 |          6 |           83.7
 2026-01 |     391 |     15 |       16 |            12 |               16 |          6 |           85.7
 2026-02 |     342 |      9 |        8 |             7 |                5 |         10 |           89.8
 2026-03 |     398 |     14 |       17 |            13 |               13 |          8 |           86.0


---- Q2. ITC at risk by supplier state and quarter (GROUPING SETS) ----
     state      | fy_quarter | open_items | itc_at_risk 
----------------+------------+------------+-------------
 Karnataka      | * ALL *    |        121 |   896936.13
 Maharashtra    | * ALL *    |         24 |   242030.00
 Uttar Pradesh  | * ALL *    |         24 |   209058.18
 Gujarat        | * ALL *    |         27 |   193347.37
 Delhi          | * ALL *    |         22 |   132842.36
 Kerala         | * ALL *    |         13 |   102424.75
 Tamil Nadu     | * ALL *    |         18 |    98651.16
 West Bengal    | * ALL *    |         13 |    55982.22
 Telangana      | * ALL *    |         13 |    45542.27
 Haryana        | * ALL *    |          4 |    29776.77
 Rajasthan      | * ALL *    |          5 |    11403.54
 * ALL STATES * | Q4         |         71 |   560549.29
 * ALL STATES * | Q2         |         71 |   543877.82
 * ALL STATES * | Q1         |         75 |   459821.42
 * ALL STATES * | Q3         |         67 |   453746.22
 * ALL STATES * | * ALL *    |        284 |  2017994.75


---- Q3. Missing purchase-voucher numbers (gaps-and-islands) ----
 gap_start | gap_end | missing_count | first_missing_voucher 
-----------+---------+---------------+-----------------------
        39 |      39 |             1 | PV/25-26/00039
        94 |      94 |             1 | PV/25-26/00094
       708 |     708 |             1 | PV/25-26/00708
      1101 |    1101 |             1 | PV/25-26/01101
      1286 |    1286 |             1 | PV/25-26/01286
      1368 |    1368 |             1 | PV/25-26/01368
      2011 |    2011 |             1 | PV/25-26/02011
      2018 |    2018 |             1 | PV/25-26/02018
      2286 |    2286 |             1 | PV/25-26/02286
      2422 |    2422 |             1 | PV/25-26/02422
      2701 |    2701 |             1 | PV/25-26/02701
      3505 |    3505 |             1 | PV/25-26/03505
      4224 |    4224 |             1 | PV/25-26/04224
      4428 |    4428 |             1 | PV/25-26/04428
      4740 |    4740 |             1 | PV/25-26/04740
      4749 |    4749 |             1 | PV/25-26/04749


---- Q4. Benford's law: first-digit distribution of invoice values ----
 first_digit | observed | expected | observed_pct | benford_pct | chi_square |       verdict       
-------------+----------+----------+--------------+-------------+------------+---------------------
           1 |     1429 |   1433.5 |        30.01 |       30.10 |       4.22 | Conforms (p > 0.05)
           2 |      835 |    838.5 |        17.53 |       17.61 |       4.22 | Conforms (p > 0.05)
           3 |      586 |    595.0 |        12.31 |       12.49 |       4.22 | Conforms (p > 0.05)
           4 |      452 |    461.5 |         9.49 |        9.69 |       4.22 | Conforms (p > 0.05)
           5 |      379 |    377.1 |         7.96 |        7.92 |       4.22 | Conforms (p > 0.05)
           6 |      329 |    318.8 |         6.91 |        6.69 |       4.22 | Conforms (p > 0.05)
           7 |      286 |    276.2 |         6.01 |        5.80 |       4.22 | Conforms (p > 0.05)
           8 |      227 |    243.6 |         4.77 |        5.12 |       4.22 | Conforms (p > 0.05)
           9 |      239 |    217.9 |         5.02 |        4.58 |       4.22 | Conforms (p > 0.05)


---- Q5. Suppliers whose mismatch rate is getting worse ----
        supplier_name        | latest_month | prev_pct | rolling_3m_problem_pct | change_pts 
-----------------------------+--------------+----------+------------------------+------------
 Sai Electricals & Co        | Mar-2026     |     20.0 |                   66.7 |       46.7
 Sai Pumps & Co              | Mar-2026     |     16.7 |                   60.0 |       43.3
 Om Pumps LLP                | Mar-2026     |     25.0 |                   50.0 |       25.0
 Om Hydraulics Traders       | Mar-2026     |      0.0 |                   20.0 |       20.0
 Mahalaxmi Logistics Traders | Mar-2026     |     16.7 |                   33.3 |       16.6


---- Q6. Biggest open item for each of the 10 riskiest suppliers (LATERAL) ----
        supplier_name         | grade | supplier_itc_at_risk | books_invoice_no | invoice_date |   match_status    | item_itc_at_risk 
------------------------------+-------+----------------------+------------------+--------------+-------------------+------------------
 Tunga Steel Corporation      | D     |            187858.32 | 0162/25-26       | 2025-11-16   | MISSING_IN_2B     |         67825.46
 Hampi Rubber Enterprises     | C     |            142730.86 | SB/81            | 2025-06-08   | MISMATCH_TAX_HEAD |        121013.41
 Vijay Valves Pvt Ltd         | B     |            102610.36 | GST000158        | 2026-03-10   | MISSING_IN_2B     |        101236.11
 Sahyadri Cables Enterprises  | B     |             85778.45 | 0365/25-26       | 2026-01-21   | MISMATCH_TAX_HEAD |         30561.88
 Bharat Polymers LLP          | B     |             76802.53 | SB/425           | 2026-03-02   | MISMATCH_VALUE    |         31712.58
 Krishna Polymers Enterprises | B     |             76400.74 | EXP/110          | 2025-05-14   | MISSING_IN_2B     |         14053.19
 Kaveri Paints Pvt Ltd        | B     |             76155.12 | INV-00136        | 2025-12-09   | MISSING_IN_2B     |         37115.27
 Vijay Packaging Corporation  | B     |             65864.80 | SB/25-26/0264    | 2025-08-25   | MISSING_IN_2B     |         14050.57
 Hampi Textiles Industries    | C     |             61273.21 | INV000050        | 2025-09-01   | MISMATCH_TAX_HEAD |         17420.26
 Sri Components LLP           | C     |             60030.04 | INV/53           | 2025-09-13   | MISSING_IN_2B     |         57934.41


---- Q7. GSTR-1 filing delay distribution by supplier grade ----
 grade | suppliers | median_delay_days | p90_delay_days | worst_delay_days 
-------+-----------+-------------------+----------------+------------------
 A     |        69 |              -4.0 |            0.0 |               45
 B     |        34 |              -2.0 |            2.0 |               45
 C     |        12 |               0.0 |            2.0 |               44
 D     |         5 |               0.0 |           21.3 |               42


---- Q8. Pareto: how few suppliers cause 80% of ITC at risk ----
 supplier_rank |        supplier_name         | itc_at_risk | cumulative_pct | pareto_band | suppliers_with_risk 
---------------+------------------------------+-------------+----------------+-------------+---------------------
             1 | Tunga Steel Corporation      |   187858.32 |            9.3 | vital few   |                  82
             2 | Hampi Rubber Enterprises     |   142730.86 |           16.4 | vital few   |                  82
             3 | Vijay Valves Pvt Ltd         |   102610.36 |           21.5 | vital few   |                  82
             4 | Sahyadri Cables Enterprises  |    85778.45 |           25.7 | vital few   |                  82
             5 | Bharat Polymers LLP          |    76802.53 |           29.5 | vital few   |                  82
             6 | Krishna Polymers Enterprises |    76400.74 |           33.3 | vital few   |                  82
             7 | Kaveri Paints Pvt Ltd        |    76155.12 |           37.1 | vital few   |                  82
             8 | Vijay Packaging Corporation  |    65864.80 |           40.3 | vital few   |                  82
             9 | Hampi Textiles Industries    |    61273.21 |           43.4 | vital few   |                  82
            10 | Sri Components LLP           |    60030.04 |           46.4 | vital few   |                  82
            11 | Om Bearings Enterprises      |    55782.67 |           49.1 | vital few   |                  82
            12 | Mahalaxmi Logistics Traders  |    46642.08 |           51.4 | vital few   |                  82
            13 | Ganesh Paints Pvt Ltd        |    44946.14 |           53.7 | vital few   |                  82
            14 | Om Packaging Pvt Ltd         |    42541.80 |           55.8 | vital few   |                  82
            15 | Sai Paints Corporation       |    41733.12 |           57.8 | vital few   |                  82

==> Running sql/07_tests.sql
>> 07_tests: running test suite
NOTICE: PASS  T01a  known-good GSTIN 27AAPFU0939F1ZV is valid
NOTICE: PASS  T01b  same GSTIN with wrong check digit is invalid
NOTICE: PASS  T01c  14-character GSTIN is invalid
NOTICE: PASS  T02a  INV/25-26/0012 == inv-25-26-12
NOTICE: PASS  T02b  SB000069 == sb69
NOTICE: PASS  T02c  different invoices stay different
NOTICE: PASS  T03  4762 books records, 4762 classified
NOTICE: PASS  T04  4720 2B records, 4720 classified
NOTICE: PASS  T05a  books ITC control total Rs 42294757.32
NOTICE: PASS  T05b  2B available ITC control total Rs 41505612.95
NOTICE: PASS  T06  no negative ITC buckets
NOTICE: PASS  T07  10 of 10 junk rows rejected with the expected reason
NOTICE: PASS  T08  9482 of 9482 labelled records classified correctly (100.00%)

================ ENGINE ACCURACY vs GROUND TRUTH ================
     expected_status      | labelled_records | correctly_classified | accuracy_pct |             planted_scenarios             
--------------------------+------------------+----------------------+--------------+-------------------------------------------
 MATCHED                  |             7328 |                 7328 |       100.00 | CREDIT_NOTE_BOOKED, EXACT, FORMAT_VARIANT
 MATCHED_TOLERANCE        |              368 |                  368 |       100.00 | ROUNDING_DIFF
 MATCHED_CROSS_PERIOD     |              342 |                  342 |       100.00 | SUPPLIER_FILED_LATE
 MATCHED_DATE_DIFF        |              324 |                  324 |       100.00 | INVOICE_DATE_TYPO
 MATCHED_FUZZY_INVNO      |              266 |                  266 |       100.00 | INVOICE_NO_TYPO
 MISMATCH_VALUE           |              206 |                  206 |       100.00 | SUPPLIER_REPORTED_WRONG_VALUE
 MISSING_IN_2B            |              150 |                  150 |       100.00 | SUPPLIER_DID_NOT_FILE
 MATCHED_GSTIN_CORRECTION |              136 |                  136 |       100.00 | GSTIN_TYPO
 MISSING_IN_BOOKS         |              123 |                  123 |       100.00 | INVOICE_NOT_BOOKED
 MISMATCH_TAX_HEAD        |               94 |                   94 |       100.00 | WRONG_PLACE_OF_SUPPLY
 ITC_INELIGIBLE           |               70 |                   70 |       100.00 | ITC_BLOCKED_IN_2B
 DUPLICATE_IN_BOOKS       |               45 |                   45 |       100.00 | DOUBLE_BOOKED
 CREDIT_NOTE_NOT_BOOKED   |               30 |                   30 |       100.00 | CREDIT_NOTE_NOT_BOOKED
(13 rows)


Done. Connect with:  psql -d gst_recon
Try:  SELECT * FROM gst.v_recon_summary;
```
