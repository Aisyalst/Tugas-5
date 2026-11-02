"""benchmark.py - membandingkan waktu query laporan harian (baseline vs optimasi)."""
import os
import statistics
import time

from sqlalchemy import create_engine, text

engine = create_engine(os.environ["DB_URL"])
RUNS = 7

QUERIES = {
    "A. Baseline (tanpa partisi)": """
        SELECT d.full_date, st.store_name, p.category,
               COUNT(*), SUM(f.qty), SUM(f.net_amount)
        FROM fact_sales_np f
        JOIN dim_date d ON d.date_key = f.date_key
        JOIN dim_store st ON st.store_key = f.store_key
        JOIN dim_product p ON p.product_key = f.product_key
        WHERE f.date_key BETWEEN 20260901 AND 20260930
        GROUP BY d.full_date, st.store_name, p.category""",
    "B. Partitioning": """
        SELECT d.full_date, st.store_name, p.category,
               COUNT(*), SUM(f.qty), SUM(f.net_amount)
        FROM fact_sales f
        JOIN dim_date d ON d.date_key = f.date_key
        JOIN dim_store st ON st.store_key = f.store_key
        JOIN dim_product p ON p.product_key = f.product_key
        WHERE f.date_key BETWEEN 20260901 AND 20260930
        GROUP BY d.full_date, st.store_name, p.category""",
    "C. Partitioning + MV": """
        SELECT m.sale_date, st.store_name, m.category,
               m.jumlah_item, m.total_qty, m.net_amount
        FROM mv_daily_sales m
        JOIN dim_store st ON st.store_key = m.store_key
        WHERE m.sale_date BETWEEN '2026-09-01' AND '2026-09-30'""",
}


def bench(sql: str) -> float:
    """Rata-rata waktu eksekusi (ms) setelah 1x warm-up."""
    with engine.connect() as con:
        con.execute(text(sql)).fetchall()                 # warm-up
        times = []
        for _ in range(RUNS):
            t0 = time.perf_counter()
            con.execute(text(sql)).fetchall()
            times.append((time.perf_counter() - t0) * 1000)
    return statistics.mean(times)


if __name__ == "__main__":
    results = {name: bench(sql) for name, sql in QUERIES.items()}
    base = results["A. Baseline (tanpa partisi)"]
    print(f"{'Skenario':<32}{'Rata-rata (ms)':>16}{'Peningkatan':>14}")
    for name, ms in results.items():
        gain = (base - ms) / base * 100
        print(f"{name:<32}{ms:>16.2f}{gain:>13.1f}%")
    best = max((base - v) / base * 100 for v in results.values())
    print("TARGET >= 50% :", "TERCAPAI" if best >= 50 else "BELUM TERCAPAI")
