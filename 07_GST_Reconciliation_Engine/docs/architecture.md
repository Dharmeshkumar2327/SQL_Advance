# Architecture & Data Model

*GST Reconciliation Engine, by Dharmesh Kumar*

## 1. Layers

| Schema | Role | Trust level |
|---|---|---|
| `stg` | Raw CSV landing tables (every column is `TEXT`) and `load_rejects` | untrusted |
| `gst` | Validated core model, engine, run audit, reporting views | trusted |
| `qa`  | Ground-truth labels, accuracy view, assertion helper | test only |

## 2. Entity-relationship diagram

```mermaid
erDiagram
    STATE_CODE ||--o{ SUPPLIER : "registered in"
    STATE_CODE ||--|| COMPANY : "registered in"
    STATE_CODE ||--o{ PURCHASE_REGISTER : "place of supply"
    STATE_CODE ||--o{ GSTR2B : "place of supply"
    SUPPLIER ||..o{ GSTR2B : "files GSTR-1 (by GSTIN)"
    SUPPLIER ||..o{ PURCHASE_REGISTER : "billed (GSTIN may be mistyped)"
    RECON_RUN ||--o{ RECON_RESULT : produces
    PURCHASE_REGISTER |o--o| RECON_RESULT : "books side"
    GSTR2B |o--o| RECON_RESULT : "2B side"
    STATUS_CATALOG ||--o{ RECON_RESULT : classifies

    COMPANY { char15 gstin PK "single-row table" }
    SUPPLIER { int supplier_id PK
               char15 gstin UK "checksum-validated"
               char10 pan "generated" }
    PURCHASE_REGISTER { bigint pr_id PK
               text voucher_no UK
               char15 supplier_gstin "no FK on purpose"
               text invoice_no_norm "generated"
               numeric total_tax "generated"
               bool gstin_is_valid "generated" }
    GSTR2B { bigint b2b_id PK
               char7 return_period
               text section "B2B or CDNR"
               bool itc_available
               text invoice_no_norm "generated" }
    RECON_RUN { int run_id PK
               jsonb pass_log
               jsonb config_snapshot }
    RECON_RESULT { bigint result_id PK
               bigint pr_id "unique per run"
               bigint b2b_id "unique per run"
               text match_status FK
               numeric itc_at_risk
               numeric itc_unclaimed
               numeric itc_reversal }
    STATUS_CATALOG { text match_status PK
               smallint severity
               text recommended_action }
```

Dotted lines are logical relationships that are deliberately **not** enforced with foreign keys: the books contain mistyped GSTINs, and the engine has to reconcile them rather than reject them.

## 3. Engine flow

```mermaid
flowchart TD
    S[Unmatched books _pr<br/>Unmatched 2B _2b] --> P0[P0 Duplicates in books]
    P0 --> P1[P1 Exact key<br/>GSTIN + invoice_no_norm + doc class]
    P1 -->|classify| C1{value / tax head /<br/>period / date / rounding}
    P1 --> P2[P2 Fuzzy invoice no.<br/>levenshtein ≤ 2 AND value AND date]
    P2 --> P3[P3 GSTIN typo<br/>same invoice + value, GSTIN distance ≤ 2]
    P3 --> P4[P4 Leftovers<br/>MISSING_IN_2B / MISSING_IN_BOOKS /<br/>CREDIT_NOTE_NOT_BOOKED]
    P4 --> PO[POST: 2B says ITC unavailable → ITC_INELIGIBLE]
    PO --> V[VALUATION: at-risk / unclaimed / reversal]
```

After each pass, matched records are deleted from the temporary working sets, so later (looser) passes can never steal a record that a stricter pass already paired.

## 4. Status catalogue

| Status | Group | Severity | Rupee bucket |
|---|---|---|---|
| MATCHED | MATCHED | 0 | none |
| MATCHED_TOLERANCE | MATCHED | 0 | none |
| MATCHED_DATE_DIFF | MATCHED | 1 | none |
| MATCHED_FUZZY_INVNO | MATCHED | 1 | none |
| MATCHED_GSTIN_CORRECTION | MATCHED | 2 | none |
| MATCHED_CROSS_PERIOD | TIMING | 1 | none |
| MISMATCH_VALUE | MISMATCH | 2 | at risk (books > 2B) or unclaimed (2B > books) |
| MISMATCH_TAX_HEAD | MISMATCH | 3 | at risk |
| MISSING_IN_2B | MISSING | 3 | at risk |
| MISSING_IN_BOOKS | MISSING | 1 | unclaimed |
| CREDIT_NOTE_NOT_BOOKED | MISSING | 2 | reversal |
| DUPLICATE_IN_BOOKS | COMPLIANCE | 3 | reversal |
| ITC_INELIGIBLE | COMPLIANCE | 3 | at risk |

## 5. Synthetic data design

`data_generator/generate_data.py` (standard library only, seed 42):

- **120 suppliers** across 11 states, with Pareto-distributed purchase volume and reliability tiers A/B/C. Tier-C suppliers are about 16× more likely to skip filing.
- **Valid GSTINs** with real Luhn mod-36 checksums, built from random PAN-format strings.
- **Five invoice-number styles** (`INV/25-26/0012`, `SI-00012`, `KA000012`, `0012/25-26`, `GST/12`).
- **Lognormal invoice values**, which follow Benford's law (confirmed by Q4).
- **Two-phase generation:** every supplier's full invoice series is issued first, then typos are planted, so a typo can never collide with a real invoice number issued later in the year.
- Every record gets a **ground-truth label**, which is how the engine is graded.
