#!/usr/bin/env python3
"""
Synthetic UPI transaction generator with planted fraud patterns.

Creates a realistic-looking (but 100% synthetic) Indian UPI payments dataset:
  * cities.csv        - 25 Indian cities with coordinates
  * accounts.csv      - personal + merchant UPI accounts (VPAs)
  * transactions.csv  - normal behaviour + injected fraud
  * fraud_labels.csv  - ground truth for every planted fraud transaction

The SQL engine never reads fraud_labels.csv while detecting fraud.
The labels are used only afterwards, to measure precision and recall.

Usage:
    python data_generator/generate_data.py                 # default ~600k txns
    python data_generator/generate_data.py --accounts 10000 --txns 120000   # small/CI
"""
from __future__ import annotations

import argparse
import os
from datetime import datetime, timedelta

import numpy as np
import pandas as pd

# --------------------------------------------------------------------------
# Reference data
# --------------------------------------------------------------------------
CITIES = [
    # city, state, lat, lon, population weight
    ("Mumbai", "Maharashtra", 19.0760, 72.8777, 10),
    ("Delhi", "Delhi", 28.7041, 77.1025, 10),
    ("Bengaluru", "Karnataka", 12.9716, 77.5946, 9),
    ("Hyderabad", "Telangana", 17.3850, 78.4867, 7),
    ("Chennai", "Tamil Nadu", 13.0827, 80.2707, 7),
    ("Kolkata", "West Bengal", 22.5726, 88.3639, 7),
    ("Pune", "Maharashtra", 18.5204, 73.8567, 6),
    ("Ahmedabad", "Gujarat", 23.0225, 72.5714, 5),
    ("Jaipur", "Rajasthan", 26.9124, 75.7873, 4),
    ("Lucknow", "Uttar Pradesh", 26.8467, 80.9462, 4),
    ("Patna", "Bihar", 25.5941, 85.1376, 3),
    ("Bhopal", "Madhya Pradesh", 23.2599, 77.4126, 3),
    ("Chandigarh", "Chandigarh", 30.7333, 76.7794, 2),
    ("Kochi", "Kerala", 9.9312, 76.2673, 3),
    ("Indore", "Madhya Pradesh", 22.7196, 75.8577, 3),
    ("Nagpur", "Maharashtra", 21.1458, 79.0882, 3),
    ("Surat", "Gujarat", 21.1702, 72.8311, 4),
    ("Guwahati", "Assam", 26.1445, 91.7362, 2),
    ("Bhubaneswar", "Odisha", 20.2961, 85.8245, 2),
    ("Visakhapatnam", "Andhra Pradesh", 17.6868, 83.2185, 2),
    ("Coimbatore", "Tamil Nadu", 11.0168, 76.9558, 2),
    ("Ranchi", "Jharkhand", 23.3441, 85.3096, 2),
    ("Dehradun", "Uttarakhand", 30.3165, 78.0322, 1),
    ("Thiruvananthapuram", "Kerala", 8.5241, 76.9366, 2),
    ("Varanasi", "Uttar Pradesh", 25.3176, 82.9739, 2),
]

BANKS = [
    ("oksbi", "State Bank of India"),
    ("okhdfcbank", "HDFC Bank"),
    ("okicici", "ICICI Bank"),
    ("okaxis", "Axis Bank"),
    ("ybl", "Yes Bank"),
    ("paytm", "Paytm Payments Bank"),
    ("ibl", "IndusInd Bank"),
    ("kotak", "Kotak Mahindra Bank"),
    ("pnb", "Punjab National Bank"),
    ("barodampay", "Bank of Baroda"),
]

FIRST_NAMES = [
    "Aarav", "Vivaan", "Aditya", "Arjun", "Rohan", "Rahul", "Amit", "Vikram", "Karan", "Siddharth",
    "Ananya", "Diya", "Priya", "Sneha", "Pooja", "Kavya", "Isha", "Neha", "Riya", "Meera",
    "Suresh", "Ramesh", "Manoj", "Deepak", "Sanjay", "Anil", "Rajesh", "Sunil", "Vijay", "Ajay",
    "Lakshmi", "Sunita", "Anjali", "Divya", "Shreya", "Nisha", "Swati", "Rekha", "Geeta", "Asha",
    "Imran", "Farhan", "Ayesha", "Zoya", "Harpreet", "Gurpreet", "Joseph", "Mary", "Arun", "Kiran",
]
LAST_NAMES = [
    "Sharma", "Verma", "Gupta", "Singh", "Kumar", "Patel", "Shah", "Reddy", "Rao", "Nair",
    "Iyer", "Menon", "Das", "Banerjee", "Chatterjee", "Mukherjee", "Joshi", "Kulkarni", "Desai", "Mehta",
    "Yadav", "Mishra", "Pandey", "Tiwari", "Khan", "Ali", "Fernandes", "Pillai", "Naidu", "Bose",
]
MERCHANT_CATEGORIES = [
    ("GROCERY", 22), ("FOOD_DELIVERY", 14), ("RESTAURANT", 12), ("FUEL", 9), ("PHARMACY", 8),
    ("ELECTRONICS", 5), ("UTILITIES", 8), ("TRAVEL", 5), ("EDUCATION", 3), ("ENTERTAINMENT", 6),
    ("CLOTHING", 8),
]
MERCHANT_WORDS = {
    "GROCERY": ["Kirana Store", "Supermart", "Fresh Mart", "General Store"],
    "FOOD_DELIVERY": ["Food Hub", "Tiffin Service", "Cloud Kitchen"],
    "RESTAURANT": ["Dhaba", "Restaurant", "Cafe", "Biryani House"],
    "FUEL": ["Fuel Station", "Petrol Pump"],
    "PHARMACY": ["Medicals", "Pharmacy", "Chemist"],
    "ELECTRONICS": ["Electronics", "Mobile Point", "Digital World"],
    "UTILITIES": ["Power Bill Desk", "Broadband", "Recharge Point"],
    "TRAVEL": ["Travels", "Tours", "Cab Service"],
    "EDUCATION": ["Tuition Centre", "Academy", "Coaching Classes"],
    "ENTERTAINMENT": ["Cinemas", "Gaming Zone", "Events"],
    "CLOTHING": ["Textiles", "Fashion", "Garments"],
}

START = datetime(2026, 7, 1)
DAYS = 92  # Jul 1 - Sep 30, 2026

# Hour-of-day traffic shape (index = hour). Quiet at night, peaks around lunch & evening.
HOUR_WEIGHTS = np.array([
    0.6, 0.3, 0.2, 0.15, 0.2, 0.5, 1.2, 2.5, 4.0, 5.0, 5.8, 6.2,
    6.8, 6.5, 5.8, 5.5, 5.6, 6.0, 6.8, 7.5, 7.8, 6.8, 4.5, 2.0,
])
HOUR_WEIGHTS = HOUR_WEIGHTS / HOUR_WEIGHTS.sum()


def haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dphi = p2 - p1
    dl = np.radians(lon2) - np.radians(lon1)
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


# --------------------------------------------------------------------------
# Generator
# --------------------------------------------------------------------------
class UPIDataGenerator:
    def __init__(self, n_accounts: int, n_txns: int, seed: int):
        self.rng = np.random.default_rng(seed)
        self.n_accounts = n_accounts
        self.n_txns = n_txns
        self.city_names = [c[0] for c in CITIES]
        self.city_lat = np.array([c[2] for c in CITIES])
        self.city_lon = np.array([c[3] for c in CITIES])
        w = np.array([c[4] for c in CITIES], dtype=float)
        self.city_w = w / w.sum()
        self.fraud_rows: list[dict] = []
        self.next_device = 0

    # ---------------- accounts ----------------
    def _vpa(self, first, last, idx, handle):
        return f"{first.lower()}.{last.lower()}{idx}@{handle}"

    def build_accounts(self):
        rng = self.rng
        n = self.n_accounts
        n_merchant = int(n * 0.08)
        n_personal = n - n_merchant

        rows = []
        home_city = rng.choice(len(CITIES), size=n, p=self.city_w)
        bank_idx = rng.integers(0, len(BANKS), size=n)

        # Most accounts existed well before the observation window; a few are new.
        age_days = rng.integers(45, 3 * 365, size=n)
        created = np.array([START - timedelta(days=int(d), seconds=int(s))
                            for d, s in zip(age_days, rng.integers(0, 86400, size=n))])
        new_mask = rng.random(n) < 0.03          # 3% open during the window
        new_offsets = rng.integers(0, DAYS - 5, size=n)
        for i in np.where(new_mask)[0]:
            created[i] = START + timedelta(days=int(new_offsets[i]), seconds=int(rng.integers(0, 86400)))

        cat_names = [c[0] for c in MERCHANT_CATEGORIES]
        cat_w = np.array([c[1] for c in MERCHANT_CATEGORIES], dtype=float)
        cat_w /= cat_w.sum()

        for i in range(n):
            handle, bank = BANKS[bank_idx[i]]
            city = self.city_names[home_city[i]]
            if i < n_personal:
                f = FIRST_NAMES[rng.integers(len(FIRST_NAMES))]
                l = LAST_NAMES[rng.integers(len(LAST_NAMES))]
                rows.append(dict(
                    account_id=i + 1, vpa=self._vpa(f, l, i + 1, handle), holder_name=f"{f} {l}",
                    bank_name=bank, account_type="PERSONAL", merchant_category=None,
                    home_city=city, created_at=created[i],
                    kyc_level="FULL" if rng.random() < 0.85 else "MIN",
                ))
            else:
                cat = rng.choice(cat_names, p=cat_w)
                l = LAST_NAMES[rng.integers(len(LAST_NAMES))]
                word = MERCHANT_WORDS[cat][rng.integers(len(MERCHANT_WORDS[cat]))]
                name = f"{l} {word}"
                rows.append(dict(
                    account_id=i + 1, vpa=f"{name.lower().replace(' ', '')}{i + 1}@{handle}",
                    holder_name=name, bank_name=bank, account_type="MERCHANT", merchant_category=cat,
                    home_city=city, created_at=created[i], kyc_level="FULL",
                ))

        self.accounts = pd.DataFrame(rows)
        self.n_personal = n_personal
        self.home_city_idx = home_city
        # behavioural profile per account
        self.activity = rng.lognormal(0, 1.0, size=n)
        self.typical_amt = rng.lognormal(np.log(450), 0.6, size=n)
        self.second_city_idx = rng.choice(len(CITIES), size=n, p=self.city_w)

    def _add_fraud_account(self, kind: str, created_at: datetime, city_idx: int) -> int:
        """Append a mule / scam / cash-out account and return its id."""
        acc_id = int(self.accounts["account_id"].max()) + 1
        rng = self.rng
        handle, bank = BANKS[rng.integers(len(BANKS))]
        if kind == "CASHOUT":
            name = f"{LAST_NAMES[rng.integers(len(LAST_NAMES))]} Gift Cards & Crypto"
            row = dict(account_id=acc_id, vpa=f"{name.lower().replace(' ', '').replace('&', '')}{acc_id}@{handle}",
                       holder_name=name, bank_name=bank, account_type="MERCHANT",
                       merchant_category="GIFT_CARDS_CRYPTO", home_city=self.city_names[city_idx],
                       created_at=created_at, kyc_level="MIN")
        else:
            f = FIRST_NAMES[rng.integers(len(FIRST_NAMES))]
            l = LAST_NAMES[rng.integers(len(LAST_NAMES))]
            row = dict(account_id=acc_id, vpa=self._vpa(f, l, acc_id, handle), holder_name=f"{f} {l}",
                       bank_name=bank, account_type="PERSONAL", merchant_category=None,
                       home_city=self.city_names[city_idx], created_at=created_at, kyc_level="MIN")
        self.accounts = pd.concat([self.accounts, pd.DataFrame([row])], ignore_index=True)
        return acc_id

    # ---------------- normal behaviour ----------------
    def build_normal_transactions(self):
        rng = self.rng
        N = self.n_txns
        n_p = self.n_personal
        w = self.activity[:n_p] / self.activity[:n_p].sum()
        payer = rng.choice(n_p, size=N, p=w)  # 0-based index

        day = rng.integers(0, DAYS, size=N)
        hour = rng.choice(24, size=N, p=HOUR_WEIGHTS)
        sec = rng.integers(0, 3600, size=N)
        ts = np.datetime64(START) + (day * 86400 + hour * 3600 + sec).astype("timedelta64[s]")

        is_p2m = rng.random(N) < 0.62
        on_trip = rng.random(N) < 0.02
        txn_city = np.where(on_trip, self.second_city_idx[payer], self.home_city_idx[payer])

        # payees
        payee = np.empty(N, dtype=np.int64)
        merch_idx = np.arange(n_p, self.n_accounts)
        merch_city = self.home_city_idx[merch_idx]
        pers_idx = np.arange(n_p)
        pers_city = self.home_city_idx[pers_idx]
        local = rng.random(N) < 0.85
        for c in range(len(CITIES)):
            m_c = merch_idx[merch_city == c]
            p_c = pers_idx[pers_city == c]
            sel_m = is_p2m & (txn_city == c) & local
            sel_p = (~is_p2m) & (txn_city == c) & local
            if len(m_c):
                payee[sel_m] = rng.choice(m_c, size=sel_m.sum())
            else:
                payee[sel_m] = rng.choice(merch_idx, size=sel_m.sum())
            if len(p_c):
                payee[sel_p] = rng.choice(p_c, size=sel_p.sum())
            else:
                payee[sel_p] = rng.choice(pers_idx, size=sel_p.sum())
        far = ~local
        payee[far & is_p2m] = rng.choice(merch_idx, size=(far & is_p2m).sum())
        payee[far & ~is_p2m] = rng.choice(pers_idx, size=(far & ~is_p2m).sum())
        same = payee == payer
        payee[same] = (payee[same] + 1) % n_p

        # amounts: account's typical spend * noise; P2P slightly larger
        amt = self.typical_amt[payer] * rng.lognormal(0, 0.75, size=N)
        amt = np.where(is_p2m, amt, amt * 1.6)
        amt = np.clip(amt, 1, 99_999)
        whole = rng.random(N) < 0.6
        amt = np.where(whole, np.round(amt), np.round(amt, 2))
        amt = np.maximum(amt, 1)

        channel = np.where(
            is_p2m,
            rng.choice(["QR", "INTENT", "COLLECT"], size=N, p=[0.70, 0.25, 0.05]),
            rng.choice(["VPA_ENTRY", "INTENT", "COLLECT", "QR"], size=N, p=[0.45, 0.35, 0.10, 0.10]),
        )
        primary = rng.random(N) < 0.95
        device = np.where(primary,
                          np.char.add("D", np.char.zfill((payer + 1).astype(str), 7)) ,
                          np.char.add(np.char.add("D", np.char.zfill((payer + 1).astype(str), 7)), "B"))
        failed = rng.random(N) < 0.025
        reason = np.where(failed, rng.choice(["INSUFFICIENT_FUNDS", "BANK_TIMEOUT", "WRONG_PIN"],
                                             size=N, p=[0.45, 0.30, 0.25]), None)

        df = pd.DataFrame(dict(
            txn_ts=ts, payer_account_id=payer + 1, payee_account_id=payee + 1, amount=amt,
            txn_type=np.where(is_p2m, "P2M", "P2P"), channel=channel, device_id=device,
            txn_city=np.array(self.city_names)[txn_city],
            status=np.where(failed, "FAILED", "SUCCESS"), failure_reason=reason,
        ))
        # drop transactions that happen before either account was opened
        created = self.accounts.set_index("account_id")["created_at"]
        ok = (df["txn_ts"].values > created.reindex(df["payer_account_id"]).values) & \
             (df["txn_ts"].values > created.reindex(df["payee_account_id"]).values)
        self.normal = df[ok].reset_index(drop=True)
        self.normal["fraud_pattern"] = None

    # ---------------- helpers for fraud injection ----------------
    def _new_device(self, prefix="X"):
        self.next_device += 1
        return f"{prefix}{self.next_device:07d}"

    def _rand_ts(self, min_day=20, max_day=DAYS - 1, hours=None):
        d = int(self.rng.integers(min_day, max_day))
        h = int(self.rng.choice(24, p=HOUR_WEIGHTS)) if hours is None else int(self.rng.choice(hours))
        return START + timedelta(days=d, hours=h, seconds=int(self.rng.integers(0, 3600)))

    def _established_personal(self, k):
        """Pick k distinct personal accounts with enough activity and opened before the window."""
        created = self.accounts["created_at"].values[: self.n_personal]
        cand = np.where((self.activity[: self.n_personal] > 1.0) & (created < np.datetime64(START)))[0]
        return self.rng.choice(cand, size=k, replace=False)

    def _row(self, ts, payer, payee, amount, txn_type, channel, device, city, pattern,
             status="SUCCESS", reason=None):
        self.fraud_rows.append(dict(
            txn_ts=ts, payer_account_id=int(payer), payee_account_id=int(payee),
            amount=round(float(amount), 2), txn_type=txn_type, channel=channel, device_id=device,
            txn_city=city, status=status, failure_reason=reason, fraud_pattern=pattern,
        ))

    def _rand_payee(self, kind: str, t: datetime) -> int:
        """Random existing PERSONAL or MERCHANT account (1-based id) opened before time t."""
        created = self.accounts["created_at"].values
        while True:
            if kind == "MERCHANT":
                idx = int(self.rng.integers(self.n_personal, self.n_accounts))
            else:
                idx = int(self.rng.integers(0, self.n_personal))
            if created[idx] < np.datetime64(t):
                return idx + 1

    def _far_city(self, city_idx, min_km=800):
        d = haversine_km(self.city_lat[city_idx], self.city_lon[city_idx], self.city_lat, self.city_lon)
        options = np.where(d >= min_km)[0]
        return int(self.rng.choice(options))

    # ---------------- fraud patterns ----------------
    def inject_fraud(self, scale: float):
        rng = self.rng
        k = lambda base: max(3, int(base * scale))
        cn = self.city_names
        mule_pool = [
            self._add_fraud_account("MULE", START + timedelta(days=int(rng.integers(5, 40))),
                                    int(rng.choice(len(CITIES), p=self.city_w)))
            for _ in range(k(120))
        ]
        cashouts = [self._add_fraud_account("CASHOUT", START + timedelta(days=int(rng.integers(0, 10))),
                                            int(rng.integers(len(CITIES)))) for _ in range(6)]
        mule_created = self.accounts.set_index("account_id")["created_at"]

        # 1) VELOCITY_BURST - account takeover: rapid draining on a new device
        for a in self._established_personal(k(120)):
            t = self._rand_ts()
            dev = self._new_device("X")
            payees = rng.choice(mule_pool, size=int(rng.integers(1, 4)))
            city = cn[self.home_city_idx[a]] if rng.random() < 0.6 else cn[self._far_city(self.home_city_idx[a])]
            t = max(t, max(mule_created[p] for p in payees) + timedelta(hours=1))
            for _ in range(int(rng.integers(8, 16))):
                t += timedelta(seconds=int(rng.integers(20, 75)))
                self._row(t, a + 1, rng.choice(payees), rng.integers(1999, 15000), "P2P",
                          "VPA_ENTRY", dev, city, "VELOCITY_BURST")

        # 2) IMPOSSIBLE_TRAVEL - genuine txn at home, then a far-away txn minutes later
        for a in self._established_personal(k(150)):
            t = self._rand_ts()
            home = self.home_city_idx[a]
            self._row(t, a + 1, self._rand_payee("MERCHANT", t),
                      round(self.typical_amt[a]), "P2M", "QR", f"D{a + 1:07d}", cn[home], None)
            far = self._far_city(home, 800)
            t2 = t + timedelta(minutes=int(rng.integers(8, 45)))
            self._row(t2, a + 1, self._rand_payee("PERSONAL", t2), rng.integers(3000, 30000),
                      "P2P", "INTENT", self._new_device("T"), cn[far], "IMPOSSIBLE_TRAVEL")

        # 3) MULE_CHAIN - victim pays a mule, money hops 3-5 mules, then cashed out
        victims = self._established_personal(k(60))
        for v in victims:
            t = self._rand_ts(min_day=45)
            hops = rng.choice(mule_pool, size=int(rng.integers(3, 6)), replace=False)
            amt = float(rng.integers(20000, 90000))
            self._row(t, v + 1, hops[0], amt, "P2P", "VPA_ENTRY", f"D{v + 1:07d}",
                      cn[self.home_city_idx[v]], "MULE_CHAIN")
            for i in range(1, len(hops)):
                t += timedelta(minutes=int(rng.integers(4, 40)))
                amt = round(amt * rng.uniform(0.96, 0.995))
                self._row(t, hops[i - 1], hops[i], amt, "P2P", "INTENT", f"M{hops[i - 1]:07d}",
                          self.accounts.loc[self.accounts.account_id == hops[i - 1], "home_city"].iloc[0],
                          "MULE_CHAIN")
            t += timedelta(minutes=int(rng.integers(4, 40)))
            amt = round(amt * rng.uniform(0.96, 0.995))
            self._row(t, hops[-1], rng.choice(cashouts), amt, "P2M", "QR", f"M{hops[-1]:07d}",
                      self.accounts.loc[self.accounts.account_id == hops[-1], "home_city"].iloc[0],
                      "MULE_CHAIN")

        # 4) NEW_DEVICE_HIGH_VALUE - first use of a device with a huge amount (SIM swap)
        for a in self._established_personal(k(200)):
            t = self._rand_ts(min_day=40)
            amt = min(99_999, max(25_000, self.typical_amt[a] * rng.uniform(15, 40)))
            self._row(t, a + 1, self._rand_payee("PERSONAL", t), round(amt), "P2P",
                      "VPA_ENTRY", self._new_device("N"), cn[self.home_city_idx[a]], "NEW_DEVICE_HIGH_VALUE")

        # 5) STRUCTURING - many payments just below a Rs 10,000 review threshold in one day
        for a in self._established_personal(k(50)):
            t = self._rand_ts(hours=range(9, 14))
            for _ in range(int(rng.integers(5, 10))):
                t += timedelta(minutes=int(rng.integers(15, 90)))
                self._row(t, a + 1, self._rand_payee("PERSONAL", t),
                          rng.uniform(9500, 9999.99), "P2P", "VPA_ENTRY", f"D{a + 1:07d}",
                          cn[self.home_city_idx[a]], "STRUCTURING")

        # 6) FAN_IN_COLLECT_SCAM - brand-new account collects money from many strangers in a day
        for _ in range(k(40)):
            city = int(rng.choice(len(CITIES), p=self.city_w))
            created = START + timedelta(days=int(rng.integers(10, DAYS - 10)))
            scam = self._add_fraud_account("SCAM", created, city)
            t = created + timedelta(days=int(rng.integers(1, 8)), hours=int(rng.integers(8, 12)))
            for v in self._established_personal(int(rng.integers(12, 31))):
                ts = t + timedelta(minutes=int(rng.integers(0, 20 * 60)))
                self._row(ts, v + 1, scam, rng.choice([499, 999, 1499, 1999, 2499, 4999]), "P2P",
                          "COLLECT", f"D{v + 1:07d}", cn[self.home_city_idx[v]], "FAN_IN_COLLECT_SCAM")

        # 7) ODD_HOUR_ANOMALY - 1am-4am payment far above the customer's normal spend
        for a in self._established_personal(k(200)):
            t = self._rand_ts(min_day=40, hours=[1, 2, 3, 4])
            amt = min(99_999, max(6000, self.typical_amt[a] * rng.uniform(12, 30)))
            self._row(t, a + 1, self._rand_payee("PERSONAL", t), round(amt), "P2P",
                      "VPA_ENTRY", f"D{a + 1:07d}", cn[self.home_city_idx[a]], "ODD_HOUR_ANOMALY")

        # 8) PIN_BRUTE_FORCE - several wrong-PIN failures, then a successful big payment
        for a in self._established_personal(k(80)):
            t = self._rand_ts()
            dev = self._new_device("P")
            payee = rng.choice(mule_pool)
            t = max(t, mule_created[payee] + timedelta(hours=1))
            amt = rng.integers(10000, 60000)
            for _ in range(int(rng.integers(3, 7))):
                t += timedelta(seconds=int(rng.integers(15, 60)))
                self._row(t, a + 1, payee, amt, "P2P", "VPA_ENTRY", dev, cn[self.home_city_idx[a]],
                          None, status="FAILED", reason="WRONG_PIN")
            t += timedelta(seconds=int(rng.integers(15, 60)))
            self._row(t, a + 1, payee, amt, "P2P", "VPA_ENTRY", dev, cn[self.home_city_idx[a]],
                      "PIN_BRUTE_FORCE")

    # ---------------- evasive fraud (designed to slip past the rules) ----------------
    def inject_evasive_fraud(self, scale: float):
        """Fraud that deliberately stays under thresholds -> realistic false negatives."""
        rng = self.rng
        k = lambda base: max(2, int(base * scale))
        cn = self.city_names
        mules = self.accounts.loc[(self.accounts.kyc_level == "MIN") &
                                  (self.accounts.account_type == "PERSONAL") &
                                  (self.accounts.created_at > START) &
                                  (self.accounts.created_at < START + timedelta(days=40)), "account_id"].to_numpy()

        # Slow mule chain: hops 70-180 minutes apart (rule waits max 60)
        for v in self._established_personal(k(12)):
            t = self._rand_ts(min_day=50)
            hops = rng.choice(mules, size=3, replace=False)
            amt = float(rng.integers(20000, 80000))
            self._row(t, v + 1, hops[0], amt, "P2P", "VPA_ENTRY", f"D{v + 1:07d}",
                      cn[self.home_city_idx[v]], "MULE_CHAIN")
            for i in range(1, len(hops)):
                t += timedelta(minutes=int(rng.integers(70, 180)))
                amt = round(amt * rng.uniform(0.96, 0.99))
                self._row(t, hops[i - 1], hops[i], amt, "P2P", "INTENT", f"M{hops[i - 1]:07d}",
                          cn[self.home_city_idx[v]], "MULE_CHAIN")

        # Low-and-slow takeover: 4-5 payments spread over ~40 minutes
        for a in self._established_personal(k(25)):
            t = self._rand_ts(min_day=45)
            dev = self._new_device("S")
            payee = rng.choice(mules)
            for _ in range(int(rng.integers(4, 6))):
                t += timedelta(minutes=int(rng.integers(6, 12)))
                self._row(t, a + 1, payee, rng.integers(1500, 4000), "P2P", "VPA_ENTRY", dev,
                          cn[self.home_city_idx[a]], "VELOCITY_BURST")

        # Structuring spread over two days (3 per day, rule needs 4 in one day)
        for a in self._established_personal(k(10)):
            t = self._rand_ts(hours=range(9, 12))
            for d in range(2):
                for _ in range(3):
                    t += timedelta(minutes=int(rng.integers(30, 120)))
                    self._row(t + timedelta(days=d), a + 1, self._rand_payee("PERSONAL", t),
                              rng.uniform(9500, 9999.99), "P2P", "VPA_ENTRY", f"D{a + 1:07d}",
                              cn[self.home_city_idx[a]], "STRUCTURING")

    # ---------------- hard negatives (genuine, but look suspicious) ----------------
    def inject_hard_negatives(self, scale: float):
        """Legitimate behaviour that trips rules -> realistic false positives. NOT labelled."""
        rng = self.rng
        k = lambda base: max(2, int(base * scale))
        cn = self.city_names

        # Bought a new phone, then paid rent / college fees from it
        for a in self._established_personal(k(150)):
            t = self._rand_ts(min_day=40)
            self._row(t, a + 1, self._rand_payee("PERSONAL", t), rng.integers(20000, 60000), "P2P",
                      "VPA_ENTRY", self._new_device("G"), cn[self.home_city_idx[a]], None)

        # Shopping spree at a mall: 6-8 quick payments to different shops
        for a in self._established_personal(k(40)):
            t = self._rand_ts(hours=range(17, 21))
            for _ in range(int(rng.integers(6, 9))):
                t += timedelta(seconds=int(rng.integers(40, 90)))
                self._row(t, a + 1, self._rand_payee("MERCHANT", t), rng.integers(1200, 4500), "P2M",
                          "QR", f"D{a + 1:07d}", cn[self.home_city_idx[a]], None)

        # Student opens a new account and collects trip money from 10-14 friends
        for _ in range(k(25)):
            city = int(rng.choice(len(CITIES), p=self.city_w))
            created = START + timedelta(days=int(rng.integers(10, DAYS - 10)))
            organiser = self._add_fraud_account("GENUINE", created, city)
            self.accounts.loc[self.accounts.account_id == organiser, "kyc_level"] = "FULL"
            t = created + timedelta(days=int(rng.integers(1, 6)), hours=10)
            for f in self._established_personal(int(rng.integers(10, 15))):
                self._row(t + timedelta(minutes=int(rng.integers(0, 600))), f + 1, organiser,
                          rng.choice([1500, 2000, 2500, 3000]), "P2P", "INTENT", f"D{f + 1:07d}",
                          cn[self.home_city_idx[f]], None)

        # Late-night emergency payment (hospital / flight ticket)
        for a in self._established_personal(k(60)):
            t = self._rand_ts(min_day=40, hours=[1, 2, 3, 4])
            self._row(t, a + 1, self._rand_payee("MERCHANT", t),
                      min(99_999, max(8000, self.typical_amt[a] * rng.uniform(15, 40))), "P2M",
                      "INTENT", f"D{a + 1:07d}", cn[self.home_city_idx[a]], None)

        # Monthly rent split into 4 payments of ~Rs 9,800 to the same landlord
        for a in self._established_personal(k(12)):
            t = self._rand_ts(hours=range(9, 12))
            landlord = self._rand_payee("PERSONAL", t)
            for _ in range(4):
                t += timedelta(minutes=int(rng.integers(5, 30)))
                self._row(t, a + 1, landlord, 9800, "P2P", "VPA_ENTRY", f"D{a + 1:07d}",
                          cn[self.home_city_idx[a]], None)

    # ---------------- output ----------------
    def finalize(self, out_dir: str):
        os.makedirs(out_dir, exist_ok=True)
        fraud = pd.DataFrame(self.fraud_rows)
        fraud["txn_ts"] = pd.to_datetime(fraud["txn_ts"])
        txns = pd.concat([self.normal, fraud], ignore_index=True)
        txns["txn_ts"] = pd.to_datetime(txns["txn_ts"]).dt.floor("s")
        txns = txns.sort_values(["txn_ts", "payer_account_id"], kind="stable").reset_index(drop=True)
        txns.insert(0, "txn_id", np.arange(1, len(txns) + 1) + 100_000_000)

        labels = txns.loc[txns["fraud_pattern"].notna(), ["txn_id", "fraud_pattern"]]
        txns = txns.drop(columns=["fraud_pattern"])

        cities = pd.DataFrame([(c[0], c[1], c[2], c[3]) for c in CITIES],
                              columns=["city", "state", "latitude", "longitude"])
        acc = self.accounts.copy()
        acc["created_at"] = pd.to_datetime(acc["created_at"]).dt.floor("s")

        cities.to_csv(os.path.join(out_dir, "cities.csv"), index=False)
        acc.to_csv(os.path.join(out_dir, "accounts.csv"), index=False)
        txns.to_csv(os.path.join(out_dir, "transactions.csv"), index=False)
        labels.to_csv(os.path.join(out_dir, "fraud_labels.csv"), index=False)

        print(f"cities        : {len(cities):>9,}")
        print(f"accounts      : {len(acc):>9,}")
        print(f"transactions  : {len(txns):>9,}")
        print(f"fraud labels  : {len(labels):>9,}  ({len(labels) / len(txns):.2%} of txns)")
        print(labels["fraud_pattern"].value_counts().to_string())
        print(f"written to    : {os.path.abspath(out_dir)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--accounts", type=int, default=50_000, help="number of genuine accounts")
    ap.add_argument("--txns", type=int, default=600_000, help="number of normal transactions")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="data", help="output folder")
    args = ap.parse_args()

    g = UPIDataGenerator(args.accounts, args.txns, args.seed)
    g.build_accounts()
    g.build_normal_transactions()
    scale = args.accounts / 50_000
    g.inject_fraud(scale)
    g.inject_evasive_fraud(scale)
    g.inject_hard_negatives(scale)
    g.finalize(args.out)


if __name__ == "__main__":
    main()
