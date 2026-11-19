"""Usage: python run_query.py queries/01_business_kpis.sql
Runs every statement in a .sql file against ecommerce.db and prints the results."""
import sqlite3, sys

con = sqlite3.connect("ecommerce.db")
sql = open(sys.argv[1]).read()
# split on ';' at end of statement, keeping only chunks that contain real SQL
for stmt in sql.split(";\n"):
    body = "\n".join(l for l in stmt.splitlines() if not l.strip().startswith("--")).strip()
    if not body:
        continue
    cur = con.execute(body)
    header = [d[0] for d in cur.description]
    rows = cur.fetchall()
    print("\n" + "\n".join(l for l in stmt.splitlines() if l.strip().startswith("--")))
    print(" | ".join(header))
    print("-" * 60)
    for r in rows[:15]:
        print(" | ".join(str(v) for v in r))
