"""Builds ecommerce.db from schema.sql with reproducible synthetic data."""
import random, sqlite3, os
from datetime import date, timedelta

random.seed(42)
DB = "ecommerce.db"
if os.path.exists(DB):
    os.remove(DB)
con = sqlite3.connect(DB)
con.executescript(open("schema.sql").read())

cities   = ["Bengaluru", "Mumbai", "Delhi", "Chennai", "Hyderabad", "Pune", "Kolkata"]
channels = ["Organic", "Paid Search", "Social", "Referral", "Email"]
cats = {
    "Electronics": (800, 30000), "Home": (300, 8000), "Fashion": (400, 5000),
    "Beauty": (150, 3000), "Sports": (500, 12000),
}

start, end = date(2024, 1, 1), date(2025, 12, 31)
span = (end - start).days

# Customers (signups skew earlier so cohorts have time to mature)
customers = []
for i in range(1, 601):
    signup = start + timedelta(days=int(random.betavariate(1.3, 2.2) * span))
    customers.append((i, f"Customer {i}", f"user{i}@example.com",
                      random.choice(cities), random.choices(channels, [35, 25, 20, 10, 10])[0],
                      signup.isoformat()))
con.executemany("INSERT INTO customers VALUES (?,?,?,?,?,?)", customers)

# Products
products = []
pid = 1
for cat, (lo, hi) in cats.items():
    for n in range(1, 9):
        price = round(random.uniform(lo, hi), -1)
        products.append((pid, f"{cat} Item {n}", cat, price, round(price * random.uniform(0.5, 0.8), 2)))
        pid += 1
con.executemany("INSERT INTO products VALUES (?,?,?,?,?)", products)

# Orders: each customer buys a random number of times after signup
oid = iid = 0
orders, items = [], []
for cid, _, _, _, _, signup in customers:
    signup = date.fromisoformat(signup)
    for _ in range(random.choices([0,1,2,3,5,8], [10,30,25,15,12,8])[0]):
        d = signup + timedelta(days=random.randint(0, max(1, (end - signup).days)))
        if d > end: continue
        oid += 1
        status = random.choices(["completed","cancelled","returned"], [88, 7, 5])[0]
        disc = random.choice([0, 0, 0, 5, 10, 15])
        orders.append((oid, cid, d.isoformat(), status, disc))
        for p in random.sample(products, random.choices([1,2,3,4],[50,30,15,5])[0]):
            iid += 1
            items.append((iid, oid, p[0], random.choices([1,2,3],[75,20,5])[0], p[3]))
con.executemany("INSERT INTO orders VALUES (?,?,?,?,?)", orders)
con.executemany("INSERT INTO order_items VALUES (?,?,?,?,?)", items)
con.commit()
print(f"Built {DB}: {len(customers)} customers, {len(products)} products, "
      f"{len(orders)} orders, {len(items)} order items")
