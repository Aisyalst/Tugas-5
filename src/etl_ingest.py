"""
etl_ingest.py - Ingestion pipeline retail: CSV + JSON mentah -> staging MySQL.

Alur:
  1. EXTRACT   : baca CSV (semua kolom sebagai teks) dan JSON bersarang
  2. LOAD RAW  : simpan apa adanya ke stg_sales_raw (audit / ELT)
  3. TRANSFORM : standardisasi, dedup, imputasi, validasi (pandas)
  4. LOAD CLEAN: simpan ke stg_sales_clean & stg_store_clean, baris tertolak ke etl_rejected_rows

Jalankan:
  pip install pandas sqlalchemy pymysql
  set DB_URL=mysql+pymysql://root:password@localhost:3306/retail_dw   (Windows)
  export DB_URL=mysql+pymysql://root:password@localhost:3306/retail_dw (Linux/Mac)
  python etl_ingest.py --csv data/retail_sales_raw.csv --json data/stores.json
"""
import argparse
import json
import logging
import os
import re
from pathlib import Path

import pandas as pd

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("etl")

NULL_TOKENS = ["", " ", "NA", "N/A", "NULL", "null", "None", "-", "nan"]

CATEGORY_MAP = {
    "food & beverage": "Food & Beverage", "food and beverage": "Food & Beverage",
    "f&b": "Food & Beverage", "food&beverage": "Food & Beverage",
    "personal care": "Personal Care", "personal-care": "Personal Care",
    "household": "Household", "house hold": "Household",
    "electronics": "Electronics", "electronic": "Electronics", "elektronik": "Electronics",
    "fashion": "Fashion",
    "stationery": "Stationery", "atk": "Stationery",
}
CITY_MAP = {
    "jakarta": "Jakarta", "jkt": "Jakarta", "dki jakarta": "Jakarta",
    "bandung": "Bandung", "bdg": "Bandung",
    "surabaya": "Surabaya", "sby": "Surabaya",
    "medan": "Medan",
    "pekanbaru": "Pekanbaru", "pku": "Pekanbaru",
    "makassar": "Makassar", "ujung pandang": "Makassar",
    "semarang": "Semarang", "smg": "Semarang",
}
PAYMENT_MAP = {
    "cash": "Cash", "tunai": "Cash", "qris": "QRIS",
    "debit": "Debit Card", "debit card": "Debit Card", "kartu debit": "Debit Card",
    "credit card": "Credit Card", "cc": "Credit Card", "kartu kredit": "Credit Card",
    "e-wallet": "E-Wallet", "ewallet": "E-Wallet",
}


# --------------------------------------------------------------------------- #
# EXTRACT
# --------------------------------------------------------------------------- #
def extract_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path, dtype=str, keep_default_na=False, encoding="utf-8")
    log.info("CSV dibaca: %s baris, %s kolom", len(df), df.shape[1])
    return df


def extract_json(path: str) -> pd.DataFrame:
    with open(path, encoding="utf-8") as f:
        payload = json.load(f)
    df = pd.json_normalize(payload["stores"], sep="_")      # ratakan struktur bersarang
    log.info("JSON dibaca: %s toko, kolom=%s", len(df), list(df.columns))
    return df


# --------------------------------------------------------------------------- #
# TRANSFORM - fungsi bantu
# --------------------------------------------------------------------------- #
def parse_rupiah(s: pd.Series) -> pd.Series:
    """'Rp 15.000' -> 15000 ; '15000.50' -> 15000.5 ; '' -> NaN."""
    def conv(v):
        if v is None or pd.isna(v):
            return float("nan")
        v = re.sub(r"(?i)rp|\s", "", str(v))
        if re.fullmatch(r"\d{1,3}(\.\d{3})+(,\d+)?", v):     # pemisah ribuan Indonesia
            v = v.replace(".", "").replace(",", ".")
        try:
            return float(v)
        except ValueError:
            return float("nan")
    return s.map(conv)


def parse_dates(s: pd.Series) -> pd.Series:
    """Coba beberapa format tanggal yang muncul pada data."""
    out = pd.Series(pd.NaT, index=s.index, dtype="datetime64[ns]")
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%b-%Y"):
        mask = out.isna()
        out[mask] = pd.to_datetime(s[mask], format=fmt, errors="coerce")
    return out


def norm_phone(v):
    if v is None or pd.isna(v):
        return None
    d = re.sub(r"\D", "", str(v))
    if d.startswith("62"):
        d = d[2:]
    elif d.startswith("0"):
        d = d[1:]
    return "+62" + d if 8 <= len(d) <= 13 else None


def norm_store(v):
    if v is None or pd.isna(v):
        return None
    s = re.sub(r"[^A-Z0-9]", "", str(v).upper())
    return f"{s[:3]}-{s[3:]}" if len(s) >= 5 else None


def to_none(df: pd.DataFrame) -> pd.DataFrame:
    return df.replace(NULL_TOKENS, pd.NA)


# --------------------------------------------------------------------------- #
# TRANSFORM - penjualan
# --------------------------------------------------------------------------- #
def transform_sales(raw: pd.DataFrame):
    df = raw.copy()
    for c in df.columns:
        df[c] = df[c].astype("object").map(lambda x: x.strip() if isinstance(x, str) else x)
    df = to_none(df)

    # 1. Deduplikasi (duplikat persis & kunci bisnis trx_id + product_code)
    n0 = len(df)
    df["trx_id"] = df["trx_id"].str.upper()
    df = df.drop_duplicates(subset=["trx_id", "product_code"], keep="first").copy()
    log.info("Duplikat dibuang: %s baris", n0 - len(df))

    # 2. Tanggal & waktu
    d = parse_dates(df["trx_date"])
    t = pd.to_timedelta(df["trx_time"].fillna("00:00:00").astype(str), errors="coerce").fillna(pd.Timedelta(0))
    df["trx_ts"] = d + t

    # 3. Angka
    df["unit_price"] = parse_rupiah(df["unit_price"])
    df["total_amount_src"] = parse_rupiah(df["total_amount"])
    df["qty"] = pd.to_numeric(df["qty"], errors="coerce")
    df["discount_pct"] = pd.to_numeric(df["discount_pct"].astype("object").str.replace("%", "", regex=False),
                                       errors="coerce").fillna(0)

    # 4. Imputasi harga kosong dengan median harga produk
    med = df.groupby("product_code")["unit_price"].transform("median")
    n_imp = df["unit_price"].isna().sum()
    df["unit_price"] = df["unit_price"].fillna(med)
    log.info("Harga diimputasi (median produk): %s baris", n_imp)

    # 5. Standardisasi teks
    df["customer_id"] = df["customer_id"].str.upper().fillna("C-UNKNOWN")
    df["customer_name"] = df["customer_name"].str.title()
    df["customer_phone"] = df["customer_phone"].map(norm_phone)
    df["customer_email"] = df["customer_email"].str.lower().where(
        df["customer_email"].str.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", na=False))
    df["customer_city"] = df["customer_city"].str.lower().map(CITY_MAP)
    df["customer_segment"] = df["customer_segment"].str.title()
    df["category"] = df["category"].str.lower().map(CATEGORY_MAP)
    df["product_name"] = df["product_name"].str.title()
    df["payment_method"] = df["payment_method"].str.lower().map(PAYMENT_MAP).fillna("Other")
    df["store_code"] = df["store_code"].map(norm_store)

    # 6. Imputasi atribut pelanggan berdasarkan riwayat transaksinya sendiri
    #    (ffill lalu bfill per pelanggan, urut waktu) -> mencegah perubahan SCD palsu
    df = df.sort_values(["customer_id", "trx_ts"]).reset_index(drop=True)
    anon = df["customer_id"] == "C-UNKNOWN"
    for c in ["customer_name", "customer_phone", "customer_email", "customer_city", "customer_segment"]:
        df[c] = df.groupby("customer_id")[c].transform(lambda s: s.ffill().bfill())
    df.loc[anon, ["customer_name", "customer_phone", "customer_email", "customer_city", "customer_segment"]] = \
        ["Walk-in Customer", None, None, "Unknown", "Unknown"]
    df["customer_city"] = df["customer_city"].fillna("Unknown")
    df["customer_segment"] = df["customer_segment"].fillna("Unknown")
    df["brand"] = df["brand"].fillna("Unknown")
    df["cashier_name"] = df["cashier_name"].str.title().fillna("Unknown")

    # 7. Validasi -> pisahkan baris tertolak
    reasons = pd.Series("", index=df.index)
    reasons[df["trx_ts"].isna()] += "tanggal_invalid;"
    reasons[df["qty"].isna()] += "qty_kosong;"
    reasons[df["qty"] <= 0] += "qty_tidak_positif;"
    reasons[df["qty"] > 100] += "qty_outlier;"
    reasons[df["unit_price"].isna() | (df["unit_price"] <= 0)] += "harga_invalid;"
    reasons[df["discount_pct"].between(0, 100) == False] += "diskon_invalid;"  # noqa: E712
    reasons[df["category"].isna() | df["store_code"].isna()] += "kategori_atau_toko_invalid;"
    bad = reasons != ""
    rejected = raw.loc[[]].copy()  # placeholder struktur
    rejected = df.loc[bad].assign(reject_reason=reasons[bad])
    clean = df.loc[~bad].copy()

    # 8. Rekonsiliasi total
    calc = (clean["qty"] * clean["unit_price"] * (1 - clean["discount_pct"] / 100)).round(2)
    mismatch = (calc - clean["total_amount_src"]).abs() > 1
    log.info("Total sumber tidak cocok dengan hitung ulang: %s baris (dipakai nilai hitung ulang)", mismatch.sum())
    clean["qty"] = clean["qty"].astype(int)

    cols = ["trx_id", "trx_ts", "customer_id", "customer_name", "customer_phone", "customer_email",
            "customer_city", "customer_segment", "product_code", "product_name", "category", "brand",
            "unit_price", "qty", "discount_pct", "total_amount_src", "payment_method",
            "store_code", "cashier_name"]
    log.info("Hasil: %s bersih, %s ditolak", len(clean), len(rejected))
    return clean[cols], rejected


# --------------------------------------------------------------------------- #
# TRANSFORM - toko (JSON)
# --------------------------------------------------------------------------- #
def transform_stores(df: pd.DataFrame) -> pd.DataFrame:
    out = pd.DataFrame({
        "store_code": df["store_code"].map(norm_store),
        "store_name": df["store_name"].str.strip(),
        "city": df["location_city"],
        "province": df["location_province"],
        "region": df["location_region"],
        "store_format": df["attributes_format"],
        "area_sqm": pd.to_numeric(df.get("attributes_area_sqm").astype("object")
                                  .astype(str).str.extract(r"(\d+(?:\.\d+)?)")[0], errors="coerce"),
        "opened_date": pd.to_datetime(df["opened_date"], errors="coerce").dt.date,
        "manager_name": df["manager_name"],
        "manager_phone": df.get("manager_phone").map(norm_phone) if "manager_phone" in df else None,
    })
    return out


# --------------------------------------------------------------------------- #
# LOAD
# --------------------------------------------------------------------------- #
def get_engine():
    from sqlalchemy import create_engine
    url = os.getenv("DB_URL", "mysql+pymysql://root:password@localhost:3306/retail_dw?charset=utf8mb4")
    return create_engine(url, future=True)


def load_table(engine, df: pd.DataFrame, table: str, truncate=True):
    from sqlalchemy import text
    if truncate:
        with engine.begin() as con:
            con.execute(text(f"TRUNCATE TABLE {table}"))
    df.to_sql(table, engine, if_exists="append", index=False, chunksize=1000, method="multi")
    log.info("Dimuat %s baris ke %s", len(df), table)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="data/retail_sales_raw.csv")
    ap.add_argument("--json", default="data/stores.json")
    ap.add_argument("--dry-run", action="store_true", help="hanya transform, tanpa menulis ke DB")
    a = ap.parse_args()

    raw_sales = extract_csv(a.csv)
    raw_store = extract_json(a.json)
    clean, rejected = transform_sales(raw_sales)
    stores = transform_stores(raw_store)

    Path("output").mkdir(exist_ok=True)
    rejected.to_csv("output/rejected_rows.csv", index=False)
    clean.to_csv("output/sales_clean_preview.csv", index=False)

    if a.dry_run:
        log.info("Dry-run selesai. Lihat folder output/")
        return

    eng = get_engine()
    raw_db = raw_sales.copy()
    raw_db["source_file"] = Path(a.csv).name
    load_table(eng, raw_db, "stg_sales_raw")                      # ELT: simpan mentah
    load_table(eng, clean.rename(columns={"total_amount_src": "total_amount_src"}), "stg_sales_clean")
    load_table(eng, stores, "stg_store_clean")
    rej = rejected[["trx_id", "product_code", "reject_reason"]].copy()
    load_table(eng, rej, "etl_rejected_rows")
    log.info("ETL ingestion selesai.")


if __name__ == "__main__":
    main()
