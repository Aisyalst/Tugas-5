-- =====================================================================
-- 01_staging.sql  (Tugas Kelompok 5 - ETL/ELT Pipeline Retail, MySQL 8+)
-- Urutan: (1) bagian 01-02 -> jalankan python etl_ingest.py -> (2) bagian 03 dst.
-- =====================================================================
-- 01. DATABASE
CREATE DATABASE IF NOT EXISTS retail_dw
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE retail_dw;

-- 02. TABEL STAGING
-- Data mentah: semua kolom bertipe teks agar tidak ada data yang gagal masuk
DROP TABLE IF EXISTS stg_sales_raw;
CREATE TABLE stg_sales_raw (
  trx_id            VARCHAR(30),
  trx_date          VARCHAR(30),
  trx_time          VARCHAR(20),
  customer_id       VARCHAR(20),
  customer_name     VARCHAR(100),
  customer_phone    VARCHAR(30),
  customer_email    VARCHAR(100),
  customer_city     VARCHAR(50),
  customer_segment  VARCHAR(30),
  product_code      VARCHAR(30),
  product_name      VARCHAR(150),
  category          VARCHAR(50),
  brand             VARCHAR(50),
  unit_price        VARCHAR(30),
  qty               VARCHAR(20),
  discount_pct      VARCHAR(20),
  total_amount      VARCHAR(30),
  payment_method    VARCHAR(30),
  store_code        VARCHAR(20),
  cashier_name      VARCHAR(80),
  source_file       VARCHAR(100),
  load_ts           TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- Data bersih (bertipe) hasil standardisasi pandas
DROP TABLE IF EXISTS stg_sales_clean;
CREATE TABLE stg_sales_clean (
  trx_id            VARCHAR(20)   NOT NULL,
  trx_ts            DATETIME      NOT NULL,
  customer_id       VARCHAR(20)   NOT NULL,
  customer_name     VARCHAR(100),
  customer_phone    VARCHAR(20),
  customer_email    VARCHAR(100),
  customer_city     VARCHAR(50),
  customer_segment  VARCHAR(30),
  product_code      VARCHAR(20)   NOT NULL,
  product_name      VARCHAR(150),
  category          VARCHAR(50),
  brand             VARCHAR(50),
  unit_price        DECIMAL(12,2) NOT NULL,
  qty               INT           NOT NULL,
  discount_pct      DECIMAL(5,2)  NOT NULL,
  total_amount_src  DECIMAL(14,2),
  payment_method    VARCHAR(30),
  store_code        VARCHAR(10)   NOT NULL,
  cashier_name      VARCHAR(80),
  KEY idx_stg_cust (customer_id, trx_ts)
) ENGINE=InnoDB;

-- Master toko dari JSON
DROP TABLE IF EXISTS stg_store_clean;
CREATE TABLE stg_store_clean (
  store_code     VARCHAR(10) NOT NULL,
  store_name     VARCHAR(100),
  city           VARCHAR(50),
  province       VARCHAR(50),
  region         VARCHAR(30),
  store_format   VARCHAR(30),
  area_sqm       DECIMAL(10,2),
  opened_date    DATE,
  manager_name   VARCHAR(100),
  manager_phone  VARCHAR(20)
) ENGINE=InnoDB;

-- Baris yang ditolak validasi
DROP TABLE IF EXISTS etl_rejected_rows;
CREATE TABLE etl_rejected_rows (
  trx_id         VARCHAR(30),
  product_code   VARCHAR(30),
  reject_reason  VARCHAR(200),
  rejected_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
