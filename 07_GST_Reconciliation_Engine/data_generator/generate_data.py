"""
GST Reconciliation Engine - Synthetic Data Generator
=====================================================
Author : Dharmesh Kumar
Purpose: Generates a realistic, fully synthetic FY 2025-26 dataset for one
         buyer company (Karnataka, state code 29):

           data/suppliers.csv          vendor master
           data/purchase_register.csv  the buyer's books (purchase register)
           data/gstr2b.csv             GSTR-2B (auto-drafted ITC statement)
           data/ground_truth.csv       the scenario planted on every record,
                                       used by sql/07_tests.sql to measure
                                       the engine's accuracy

Every real-world mismatch type is planted deliberately (typos, timing
differences, missing invoices, wrong tax head, duplicates ...), so the SQL
engine can be graded against a known answer key.

Uses only the Python standard library. Deterministic (seeded).

Usage:  python3 data_generator/generate_data.py [--seed 42] [--invoices 4800]
"""

import argparse
import csv
import math
import os
import random
import re
from datetime import date, timedelta

GSTIN_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
BUYER_STATE = "29"                      # Karnataka
FY_START, FY_END = date(2025, 4, 1), date(2026, 3, 31)
FY_LABEL = "25-26"

STATES = {  # GST state codes (subset) with sampling weight
    "29": 40, "27": 12, "33": 10, "07": 7, "24": 7, "36": 6,
    "32": 4, "09": 4, "06": 4, "19": 3, "08": 3,
}

NAME_A = ["Shree", "Sai", "Balaji", "Ganesh", "Krishna", "Lakshmi", "Vijay", "Om",
          "Sri", "Mahalaxmi", "Apex", "Prime", "Global", "National", "Bharat",
          "Deccan", "Kaveri", "Sahyadri", "Nilgiri", "Coromandel", "Tunga", "Hampi"]
NAME_B = ["Steel", "Polymers", "Electricals", "Fasteners", "Packaging", "Chemicals",
          "Logistics", "Castings", "Hydraulics", "Textiles", "Components", "Plastics",
          "Tools", "Bearings", "Paints", "Cables", "Rubber", "Alloys", "Pumps", "Valves"]
NAME_C = ["Pvt Ltd", "Industries", "Enterprises", "Traders", "LLP", "& Co", "Corporation"]
CATEGORIES = ["Raw Material", "Packing Material", "Consumables", "Services",
              "Capital Goods", "Logistics"]

# Reliability tiers drive how often a supplier causes problems.
TIERS = {"A": 0.70, "B": 0.20, "C": 0.10}

# Scenario weights per tier (MATCHED family vs problem scenarios).
SCENARIO_WEIGHTS = {
    "A": {"MATCHED": 82, "MATCHED_TOLERANCE": 4, "MATCHED_DATE_DIFF": 3,
          "MATCHED_CROSS_PERIOD": 2, "MATCHED_FUZZY_INVNO": 3,
          "MATCHED_GSTIN_CORRECTION": 1.5, "MISMATCH_VALUE": 1, "MISMATCH_TAX_HEAD": 0.5,
          "MISSING_IN_2B": 1, "MISSING_IN_BOOKS": 2.5, "ITC_INELIGIBLE": 0.5},
    "B": {"MATCHED": 65, "MATCHED_TOLERANCE": 4, "MATCHED_DATE_DIFF": 4,
          "MATCHED_CROSS_PERIOD": 6, "MATCHED_FUZZY_INVNO": 3,
          "MATCHED_GSTIN_CORRECTION": 1.5, "MISMATCH_VALUE": 5, "MISMATCH_TAX_HEAD": 2,
          "MISSING_IN_2B": 6, "MISSING_IN_BOOKS": 3, "ITC_INELIGIBLE": 2},
    "C": {"MATCHED": 40, "MATCHED_TOLERANCE": 4, "MATCHED_DATE_DIFF": 4,
          "MATCHED_CROSS_PERIOD": 12, "MATCHED_FUZZY_INVNO": 3,
          "MATCHED_GSTIN_CORRECTION": 2, "MISMATCH_VALUE": 9, "MISMATCH_TAX_HEAD": 4,
          "MISSING_IN_2B": 16, "MISSING_IN_BOOKS": 3, "ITC_INELIGIBLE": 3},
}


# --------------------------------------------------------------------------- #
# GSTIN helpers
# --------------------------------------------------------------------------- #
def gstin_checksum(first14: str) -> str:
    """Luhn mod-36 checksum used by GSTN for the 15th character."""
    total = 0
    for i, ch in enumerate(first14, start=1):
        prod = GSTIN_CHARS.index(ch) * (2 if i % 2 == 0 else 1)
        total += prod // 36 + prod % 36
    return GSTIN_CHARS[(36 - total % 36) % 36]


def make_gstin(state: str, rng: random.Random) -> str:
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    pan = ("".join(rng.choice(letters) for _ in range(3))
           + rng.choice("CFP")                       # Company / Firm / Person
           + rng.choice(letters)
           + f"{rng.randint(0, 9999):04d}"
           + rng.choice(letters))
    body = f"{state}{pan}{rng.choice('123')}Z"
    return body + gstin_checksum(body)


def corrupt_gstin(gstin: str, rng: random.Random) -> str:
    """One-character typo inside the PAN portion; guaranteed to fail checksum."""
    while True:
        pos = rng.randint(2, 11)
        pool = "0123456789" if gstin[pos].isdigit() else "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        new = gstin[:pos] + rng.choice(pool.replace(gstin[pos], "")) + gstin[pos + 1:]
        if gstin_checksum(new[:14]) != new[14]:
            return new


# --------------------------------------------------------------------------- #
# Invoice-number helpers (must mirror gst.fn_normalize_invoice_no in SQL)
# --------------------------------------------------------------------------- #
def normalize_invoice_no(s: str) -> str:
    s = re.sub(r"[^A-Z0-9]+", " ", s.upper())
    s = re.sub(r"(^|[^0-9])0+([0-9])", r"\1\2", s)
    return s.replace(" ", "")


def format_variant(inv: str, rng: random.Random) -> str:
    """How a data-entry operator might re-type the same invoice number."""
    v = inv
    for op in rng.sample(["lower", "sep", "zeros", "space"], k=rng.randint(1, 2)):
        if op == "lower":
            v = v.lower()
        elif op == "sep":
            v = v.replace("/", "#").replace("-", "/").replace("#", "-")
        elif op == "zeros":
            v = re.sub(r"(^|[^0-9])0+([0-9])", r"\1\2", v)
        elif op == "space":
            v = re.sub(r"[/-]", lambda m: f" {m.group(0)} ", v, count=1)
    return v


def typo_variant(inv: str, existing_norms: set, rng: random.Random) -> str:
    """A genuine typo: substitute one digit or swap two adjacent digits."""
    digit_pos = [i for i, ch in enumerate(inv) if ch.isdigit()]
    for _ in range(50):
        chars = list(inv)
        if rng.random() < 0.6 or len(digit_pos) < 2:
            p = rng.choice(digit_pos[-4:])
            chars[p] = rng.choice("0123456789".replace(chars[p], ""))
        else:
            pairs = [p for p in digit_pos if p + 1 in digit_pos and inv[p] != inv[p + 1]]
            if not pairs:
                continue
            p = rng.choice(pairs)
            chars[p], chars[p + 1] = chars[p + 1], chars[p]
        cand = "".join(chars)
        n = normalize_invoice_no(cand)
        if n != normalize_invoice_no(inv) and n not in existing_norms:
            return cand
    raise RuntimeError("could not build typo variant for " + inv)


def invoice_pattern(rng: random.Random):
    prefix = rng.choice(["INV", "SI", "TI", "GST", "BL", "SB", "EXP", "KA"])
    pats = [
        lambda n: f"{prefix}/{FY_LABEL}/{n:04d}",
        lambda n: f"{prefix}-{n:05d}",
        lambda n: f"{prefix}{n:06d}",
        lambda n: f"{n:04d}/{FY_LABEL}",
        lambda n: f"{prefix}/{n}",
    ]
    return rng.choice(pats)


# --------------------------------------------------------------------------- #
# Money helpers
# --------------------------------------------------------------------------- #
def r2(x: float) -> float:
    return round(x + 1e-9, 2)


def tax_split(taxable: float, rate: float, intra: bool):
    tax = r2(taxable * rate / 100)
    if intra:
        half = r2(tax / 2)
        return 0.0, half, r2(tax - half)          # igst, cgst, sgst
    return tax, 0.0, 0.0


def period_of(d: date) -> str:
    return f"{d.year:04d}-{d.month:02d}"


def next_month_first(d: date) -> date:
    return date(d.year + (d.month // 12), d.month % 12 + 1, 1)


# --------------------------------------------------------------------------- #
# Main generation
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--suppliers", type=int, default=120)
    ap.add_argument("--invoices", type=int, default=4800)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data"))
    args = ap.parse_args()
    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    # ---------------- suppliers ----------------
    suppliers, used_names = [], set()
    states, sw = zip(*STATES.items())
    for _ in range(args.suppliers):
        while True:
            name = f"{rng.choice(NAME_A)} {rng.choice(NAME_B)} {rng.choice(NAME_C)}"
            if name not in used_names:
                used_names.add(name)
                break
        st = rng.choices(states, sw)[0]
        suppliers.append({
            "gstin": make_gstin(st, rng),
            "legal_name": name.upper(),
            "trade_name": name,
            "state_code": st,
            "vendor_category": rng.choice(CATEGORIES),
            "onboarding_date": (date(2021, 1, 1) + timedelta(days=rng.randint(0, 1500))).isoformat(),
            "tier": rng.choices(list(TIERS), list(TIERS.values()))[0],
            "pattern": invoice_pattern(rng),
            "seq": rng.randint(1, 300),
            "cn_seq": 0,
            "weight": rng.paretovariate(1.3),      # a few big vendors, many small
        })
    sup_w = [s["weight"] for s in suppliers]

    pr_rows, b2b_rows, truth = [], [], []
    norms_by_sup = {s["gstin"]: set() for s in suppliers}

    def new_doc(sup, inv_date, doc_type="INV"):
        if doc_type == "INV":
            sup["seq"] += rng.randint(1, 3)        # vendor also bills other customers
            inv_no = sup["pattern"](sup["seq"])
        else:
            sup["cn_seq"] += 1
            inv_no = f"CN/{FY_LABEL}/{sup['cn_seq']:03d}"
        norms_by_sup[sup["gstin"]].add(normalize_invoice_no(inv_no))
        taxable = r2(min(max(rng.lognormvariate(10.3, 1.15), 850), 4_500_000))
        if doc_type == "CRN":
            taxable = r2(taxable * rng.uniform(0.05, 0.3))
        rate = rng.choices([5, 12, 18, 28], [15, 15, 60, 10])[0]
        intra = sup["state_code"] == BUYER_STATE
        igst, cgst, sgst = tax_split(taxable, rate, intra)
        cess = r2(taxable * 0.01) if (rate == 28 and rng.random() < 0.3) else 0.0
        return {"invoice_no": inv_no, "invoice_date": inv_date, "doc_type": doc_type,
                "taxable": taxable, "igst": igst, "cgst": cgst, "sgst": sgst,
                "cess": cess, "rate": rate}

    def filing_date(sup, period_first: date, late=False):
        due = next_month_first(period_first) + timedelta(days=10)   # 11th of next month
        if late:
            return due + timedelta(days=rng.randint(20, 45))
        lo, hi = {"A": (-9, 0), "B": (-5, 2), "C": (-2, 2)}[sup["tier"]]
        return due + timedelta(days=rng.randint(lo, hi))

    voucher_counter = [0]
    deleted_vouchers = set()

    def next_voucher():
        voucher_counter[0] += 1
        # ~0.3% of voucher numbers are "deleted" -> gap analysis finds them
        if rng.random() < 0.003:
            deleted_vouchers.add(voucher_counter[0])
            voucher_counter[0] += 1
        return f"PV/{FY_LABEL}/{voucher_counter[0]:05d}"

    def add_pr(sup, doc, *, inv_no=None, inv_date=None, gstin=None, heads=None,
               taxable=None, claim_period=None, scenario, expected):
        d = inv_date or doc["invoice_date"]
        booking = min(d + timedelta(days=rng.randint(0, 4)),
                      next_month_first(d) - timedelta(days=1))
        igst, cgst, sgst = heads or (doc["igst"], doc["cgst"], doc["sgst"])
        row = {
            "voucher_no": next_voucher(), "booking_date": booking.isoformat(),
            "supplier_gstin": gstin or sup["gstin"],
            "supplier_name": rng.choice([sup["trade_name"], sup["legal_name"],
                                         sup["trade_name"].replace(" Pvt Ltd", "")]),
            "invoice_no": inv_no or doc["invoice_no"], "invoice_date": d.isoformat(),
            "document_type": doc["doc_type"], "place_of_supply": BUYER_STATE,
            "taxable_value": f"{taxable if taxable is not None else doc['taxable']:.2f}",
            "igst": f"{igst:.2f}", "cgst": f"{cgst:.2f}", "sgst": f"{sgst:.2f}",
            "cess": f"{doc['cess']:.2f}",
            "itc_claim_period": claim_period or period_of(d),
        }
        pr_rows.append(row)
        truth.append({"source": "PR", "record_key": row["voucher_no"],
                      "scenario": scenario, "expected_status": expected})
        return row

    def add_2b(sup, doc, *, inv_date=None, heads=None, taxable=None, period=None,
               late=False, itc_available=True, reason="", scenario, expected):
        d = inv_date or doc["invoice_date"]
        per = period or period_of(d)
        per_first = date(int(per[:4]), int(per[5:]), 1)
        igst, cgst, sgst = heads or (doc["igst"], doc["cgst"], doc["sgst"])
        row = {
            "return_period": per, "supplier_gstin": sup["gstin"],
            "trade_name": sup["trade_name"],
            "document_type": "CDNR" if doc["doc_type"] == "CRN" else "B2B",
            "invoice_no": doc["invoice_no"], "invoice_date": d.isoformat(),
            "place_of_supply": BUYER_STATE,
            "taxable_value": f"{taxable if taxable is not None else doc['taxable']:.2f}",
            "igst": f"{igst:.2f}", "cgst": f"{cgst:.2f}", "sgst": f"{sgst:.2f}",
            "cess": f"{doc['cess']:.2f}",
            "itc_available": "Y" if itc_available else "N",
            "itc_unavailable_reason": reason,
            "gstr1_filing_date": filing_date(sup, per_first, late).isoformat(),
        }
        b2b_rows.append(row)
        truth.append({"source": "2B",
                      "record_key": f"{row['supplier_gstin']}|{row['invoice_no']}|{per}",
                      "scenario": scenario, "expected_status": expected})
        return row

    # ---------------- invoices, in date order ----------------
    fy_days = (FY_END - FY_START).days
    inv_dates = sorted(FY_START + timedelta(days=rng.randint(0, fy_days))
                       for _ in range(args.invoices))
    matched_pool = []   # (sup, doc) pairs eligible to become duplicates later

    # Phase 1: issue every document first, so the full set of each supplier's
    # invoice numbers is known before any typo is planted (a typo must never
    # collide with a number the supplier issues later in the year).
    plan = []
    for d in inv_dates:
        sup = rng.choices(suppliers, sup_w)[0]
        weights = SCENARIO_WEIGHTS[sup["tier"]]
        sc = rng.choices(list(weights), list(weights.values()))[0]
        # Date-shift scenarios need room to move inside the same month
        if sc == "MATCHED_DATE_DIFF" and not (6 <= d.day <= 22):
            d = d.replace(day=rng.randint(6, 22))
        plan.append((sup, new_doc(sup, d), sc, d))

    # Phase 2: write books / 2B rows according to the planted scenario
    for sup, doc, sc, d in plan:
        if sc == "MATCHED":
            inv_books = format_variant(doc["invoice_no"], rng) if rng.random() < 0.25 else None
            row = add_pr(sup, doc, inv_no=inv_books,
                         scenario="EXACT" if not inv_books else "FORMAT_VARIANT", expected="MATCHED")
            add_2b(sup, doc, scenario="EXACT", expected="MATCHED")
            matched_pool.append((sup, doc, row["booking_date"]))

        elif sc == "MATCHED_TOLERANCE":
            delta = rng.choice([-1, 1]) * rng.randint(1, 4)
            add_pr(sup, doc, taxable=r2(doc["taxable"] + delta),
                   scenario="ROUNDING_DIFF", expected=sc)
            add_2b(sup, doc, scenario="ROUNDING_DIFF", expected=sc)

        elif sc == "MATCHED_DATE_DIFF":
            shift = rng.choice([-1, 1]) * rng.randint(1, 5)
            add_pr(sup, doc, inv_date=d + timedelta(days=shift),
                   scenario="INVOICE_DATE_TYPO", expected=sc)
            add_2b(sup, doc, scenario="INVOICE_DATE_TYPO", expected=sc)

        elif sc == "MATCHED_CROSS_PERIOD":
            add_pr(sup, doc, scenario="SUPPLIER_FILED_LATE", expected=sc)
            add_2b(sup, doc, period=period_of(next_month_first(d)), late=True,
                   scenario="SUPPLIER_FILED_LATE", expected=sc)

        elif sc == "MATCHED_FUZZY_INVNO":
            typo = typo_variant(doc["invoice_no"], norms_by_sup[sup["gstin"]], rng)
            add_pr(sup, doc, inv_no=typo, scenario="INVOICE_NO_TYPO", expected=sc)
            add_2b(sup, doc, scenario="INVOICE_NO_TYPO", expected=sc)

        elif sc == "MATCHED_GSTIN_CORRECTION":
            add_pr(sup, doc, gstin=corrupt_gstin(sup["gstin"], rng),
                   scenario="GSTIN_TYPO", expected=sc)
            add_2b(sup, doc, scenario="GSTIN_TYPO", expected=sc)

        elif sc == "MISMATCH_VALUE":
            factor = rng.choice([rng.uniform(0.6, 0.95), rng.uniform(1.05, 1.4)])
            t2 = r2(doc["taxable"] * factor)
            heads2 = tax_split(t2, doc["rate"], sup["state_code"] == BUYER_STATE)
            add_pr(sup, doc, scenario="SUPPLIER_REPORTED_WRONG_VALUE", expected=sc)
            add_2b(sup, doc, taxable=t2, heads=heads2,
                   scenario="SUPPLIER_REPORTED_WRONG_VALUE", expected=sc)

        elif sc == "MISMATCH_TAX_HEAD":
            total = r2(doc["igst"] + doc["cgst"] + doc["sgst"])
            if doc["igst"] > 0:                       # books IGST, supplier charged CGST+SGST
                half = r2(total / 2)
                wrong = (0.0, half, r2(total - half))
            else:                                     # books CGST+SGST, supplier showed IGST
                wrong = (total, 0.0, 0.0)
            add_pr(sup, doc, scenario="WRONG_PLACE_OF_SUPPLY", expected=sc)
            add_2b(sup, doc, heads=wrong, scenario="WRONG_PLACE_OF_SUPPLY", expected=sc)

        elif sc == "MISSING_IN_2B":
            add_pr(sup, doc, scenario="SUPPLIER_DID_NOT_FILE", expected=sc)

        elif sc == "MISSING_IN_BOOKS":
            add_2b(sup, doc, scenario="INVOICE_NOT_BOOKED", expected=sc)

        elif sc == "ITC_INELIGIBLE":
            reason = rng.choice(["POS_RULE", "SECTION_16_4"])
            add_pr(sup, doc, scenario="ITC_BLOCKED_IN_2B", expected=sc)
            add_2b(sup, doc, itc_available=False, reason=reason,
                   scenario="ITC_BLOCKED_IN_2B", expected=sc)

    # ---------------- credit notes ----------------
    for i in range(70):
        sup = rng.choices(suppliers, sup_w)[0]
        d = FY_START + timedelta(days=rng.randint(0, fy_days))
        doc = new_doc(sup, d, "CRN")
        if i < 40:     # booked correctly
            add_pr(sup, doc, scenario="CREDIT_NOTE_BOOKED", expected="MATCHED")
            add_2b(sup, doc, scenario="CREDIT_NOTE_BOOKED", expected="MATCHED")
        else:          # supplier issued it, accounts team never booked it
            add_2b(sup, doc, scenario="CREDIT_NOTE_NOT_BOOKED", expected="CREDIT_NOTE_NOT_BOOKED")

    # ---------------- duplicate bookings ----------------
    # Booked again 1-20 days after the original (e.g. a second copy of the bill)
    for sup, doc, orig_booking in rng.sample(matched_pool, 45):
        row = add_pr(sup, doc, inv_no=format_variant(doc["invoice_no"], rng),
                     scenario="DOUBLE_BOOKED", expected="DUPLICATE_IN_BOOKS")
        row["booking_date"] = (date.fromisoformat(orig_booking)
                               + timedelta(days=rng.randint(1, 20))).isoformat()

    # ---------------- junk rows that the loader must reject ----------------
    junk_specs = [
        ("supplier_gstin", "", "MISSING_GSTIN"),
        ("supplier_gstin", "29ABCDE1234", "BAD_GSTIN_LENGTH"),
        ("invoice_date", "31-02-2025", "BAD_DATE"),
        ("invoice_date", "2025-13-05", "BAD_DATE"),
        ("taxable_value", "-15000.00", "NEGATIVE_AMOUNT"),
        ("taxable_value", "12,500.00", "NON_NUMERIC_AMOUNT"),
        ("igst", "abc", "NON_NUMERIC_AMOUNT"),
        ("invoice_no", "", "MISSING_INVOICE_NO"),
        ("invoice_date", "2026-04-15", "OUTSIDE_FY"),
        ("taxable_value", "", "NON_NUMERIC_AMOUNT"),
    ]
    for field, bad, reason in junk_specs:
        base = dict(rng.choice(pr_rows))
        base["voucher_no"] = next_voucher()
        base[field] = bad
        pr_rows.append(base)
        truth.append({"source": "REJECT", "record_key": base["voucher_no"],
                      "scenario": reason, "expected_status": "REJECTED"})

    # Books are naturally ordered by voucher
    pr_rows.sort(key=lambda r: r["voucher_no"])
    b2b_rows.sort(key=lambda r: (r["return_period"], r["supplier_gstin"], r["invoice_no"]))

    # ---------------- write CSVs ----------------
    def write(name, rows, fields):
        with open(os.path.join(args.out, name), "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            w.writeheader()
            w.writerows(rows)

    write("suppliers.csv", suppliers,
          ["gstin", "legal_name", "trade_name", "state_code", "vendor_category", "onboarding_date"])
    write("purchase_register.csv", pr_rows, list(pr_rows[0].keys()))
    write("gstr2b.csv", b2b_rows, list(b2b_rows[0].keys()))
    write("ground_truth.csv", truth, ["source", "record_key", "scenario", "expected_status"])

    print(f"suppliers           : {len(suppliers)}")
    print(f"purchase register   : {len(pr_rows)} rows (incl. {len(junk_specs)} junk)")
    print(f"gstr-2b             : {len(b2b_rows)} rows")
    print(f"ground truth labels : {len(truth)}")
    print(f"deleted vouchers    : {len(deleted_vouchers)} (gaps planted)")


if __name__ == "__main__":
    main()
