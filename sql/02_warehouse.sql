-- 02_warehouse.sql  (jalankan SETELAH python etl_ingest.py berhasil)
USE retail_dw;
-- Validasi hasil ingestion (nilai harapan untuk dataset bawaan)
SELECT COUNT(*) AS raw_rows       FROM stg_sales_raw;     -- 3090
SELECT COUNT(*) AS clean_rows     FROM stg_sales_clean;   -- 2937
SELECT COUNT(*) AS rejected_rows  FROM etl_rejected_rows; -- 63
SELECT COUNT(*) AS stores         FROM stg_store_clean;   -- 8

-- Rekonsiliasi: 3090 = 2937 (bersih) + 63 (ditolak) + 90 (duplikat dibuang)
SELECT reject_reason, COUNT(*) AS jml
FROM etl_rejected_rows GROUP BY reject_reason ORDER BY jml DESC;

-- Contoh cek kualitas: tidak boleh ada variasi penulisan lagi
SELECT DISTINCT category       FROM stg_sales_clean;
SELECT DISTINCT payment_method FROM stg_sales_clean;
SELECT DISTINCT customer_city  FROM stg_sales_clean;

-- 03. TABEL DIMENSI
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
  date_key      INT         NOT NULL PRIMARY KEY,   -- format YYYYMMDD
  full_date     DATE        NOT NULL,
  day_of_month  TINYINT     NOT NULL,
  day_name      VARCHAR(10) NOT NULL,
  week_of_year  TINYINT     NOT NULL,
  month_num     TINYINT     NOT NULL,
  month_name    VARCHAR(10) NOT NULL,
  quarter_num   TINYINT     NOT NULL,
  year_num      SMALLINT    NOT NULL,
  is_weekend    TINYINT(1)  NOT NULL,
  UNIQUE KEY uq_full_date (full_date)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS dim_product;
CREATE TABLE dim_product (
  product_key   INT AUTO_INCREMENT PRIMARY KEY,
  product_code  VARCHAR(20)  NOT NULL,
  product_name  VARCHAR(150) NOT NULL,
  category      VARCHAR(50)  NOT NULL,
  brand         VARCHAR(50)  NOT NULL,
  UNIQUE KEY uq_product_code (product_code)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS dim_store;
CREATE TABLE dim_store (
  store_key     INT AUTO_INCREMENT PRIMARY KEY,
  store_code    VARCHAR(10)  NOT NULL,
  store_name    VARCHAR(100),
  city          VARCHAR(50),
  province      VARCHAR(50),
  region        VARCHAR(30),
  store_format  VARCHAR(30),
  area_sqm      DECIMAL(10,2),
  opened_date   DATE,
  manager_name  VARCHAR(100),
  UNIQUE KEY uq_store_code (store_code)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS dim_payment;
CREATE TABLE dim_payment (
  payment_key     INT AUTO_INCREMENT PRIMARY KEY,
  payment_method  VARCHAR(30) NOT NULL,
  UNIQUE KEY uq_payment (payment_method)
) ENGINE=InnoDB;

-- Dimensi pelanggan dengan SCD Tipe 2
DROP TABLE IF EXISTS dim_customer;
CREATE TABLE dim_customer (
  customer_key    INT AUTO_INCREMENT PRIMARY KEY,   -- surrogate key
  customer_id     VARCHAR(20) NOT NULL,             -- business key
  customer_name   VARCHAR(100),
  phone           VARCHAR(20),
  email           VARCHAR(100),
  city            VARCHAR(50),                      -- atribut yang dilacak
  segment         VARCHAR(30),                      -- atribut yang dilacak
  effective_date  DATE        NOT NULL,
  end_date        DATE        NOT NULL DEFAULT '9999-12-31',
  is_current      TINYINT(1)  NOT NULL DEFAULT 1,
  KEY idx_cust_bk (customer_id, effective_date, end_date)
) ENGINE=InnoDB;

-- 04. MEMUAT DIMENSI
-- dim_date: 1 Jan 2026 s.d. 31 Des 2026
SET SESSION cte_max_recursion_depth = 5000;
INSERT INTO dim_date (date_key, full_date, day_of_month, day_name, week_of_year,
                      month_num, month_name, quarter_num, year_num, is_weekend)
WITH RECURSIVE d AS (
  SELECT DATE('2026-01-01') AS dt
  UNION ALL
  SELECT dt + INTERVAL 1 DAY FROM d WHERE dt < '2026-12-31'
)
SELECT CAST(DATE_FORMAT(dt, '%Y%m%d') AS UNSIGNED), dt, DAY(dt), DAYNAME(dt),
       WEEK(dt, 3), MONTH(dt), MONTHNAME(dt), QUARTER(dt), YEAR(dt),
       IF(DAYOFWEEK(dt) IN (1, 7), 1, 0)
FROM d;

-- dim_product
INSERT INTO dim_product (product_code, product_name, category, brand)
SELECT product_code,
       MAX(product_name),
       MAX(category),
       COALESCE(MAX(NULLIF(brand, 'Unknown')), 'Unknown')
FROM stg_sales_clean
GROUP BY product_code;

-- dim_store (dari JSON)
INSERT INTO dim_store (store_code, store_name, city, province, region,
                       store_format, area_sqm, opened_date, manager_name)
SELECT store_code, store_name, city, province, region,
       store_format, area_sqm, opened_date, manager_name
FROM stg_store_clean;

-- dim_payment
INSERT INTO dim_payment (payment_method)
SELECT DISTINCT payment_method FROM stg_sales_clean;

-- 05. SCD TIPE 2 - PEMUATAN AWAL (membangun riwayat dari data transaksi)
-- Ide: urutkan transaksi tiap pelanggan, tandai baris saat city/segment berubah,
-- lalu setiap perubahan menjadi satu versi dengan rentang tanggal berlaku.
INSERT INTO dim_customer
  (customer_id, customer_name, phone, email, city, segment,
   effective_date, end_date, is_current)
WITH ordered AS (
  SELECT customer_id, customer_name, customer_phone, customer_email,
         customer_city, customer_segment,
         DATE(trx_ts)                       AS trx_date,
         ROW_NUMBER() OVER w                AS rn,
         LAG(customer_city)    OVER w       AS prev_city,
         LAG(customer_segment) OVER w       AS prev_segment
  FROM stg_sales_clean
  WINDOW w AS (PARTITION BY customer_id ORDER BY trx_ts, trx_id)
),
changes AS (
  SELECT *
  FROM ordered
  WHERE rn = 1
     OR NOT (customer_city    <=> prev_city)
     OR NOT (customer_segment <=> prev_segment)
),
versions AS (
  SELECT c.*,
         LEAD(trx_date) OVER (PARTITION BY customer_id
                              ORDER BY trx_date, rn) AS next_start
  FROM changes c
)
SELECT customer_id, customer_name, customer_phone, customer_email,
       customer_city, customer_segment,
       trx_date,
       COALESCE(DATE_SUB(next_start, INTERVAL 1 DAY), '9999-12-31'),
       IF(next_start IS NULL, 1, 0)
FROM versions;

-- Verifikasi: tampilkan pelanggan yang punya lebih dari 1 versi
SELECT customer_id, city, segment, effective_date, end_date, is_current
FROM dim_customer
WHERE customer_id IN (SELECT customer_id FROM dim_customer
                      GROUP BY customer_id HAVING COUNT(*) > 1)
ORDER BY customer_id, effective_date
LIMIT 20;

SELECT COUNT(*) AS total_versi, SUM(is_current) AS versi_aktif,
       COUNT(DISTINCT customer_id) AS jml_pelanggan
FROM dim_customer;   -- hasil: 342 versi, 299 aktif, 299 pelanggan

-- 06. SCD TIPE 2 - PEMUATAN INKREMENTAL (batch data berikutnya)
DROP TABLE IF EXISTS stg_customer_latest;
CREATE TABLE stg_customer_latest (
  customer_id    VARCHAR(20) NOT NULL,
  customer_name  VARCHAR(100),
  phone          VARCHAR(20),
  email          VARCHAR(100),
  city           VARCHAR(50),
  segment        VARCHAR(30),
  snapshot_date  DATE NOT NULL
);

-- Langkah A: tutup versi lama bila atribut yang dilacak berubah
UPDATE dim_customer d
JOIN stg_customer_latest s ON s.customer_id = d.customer_id
SET d.end_date   = DATE_SUB(s.snapshot_date, INTERVAL 1 DAY),
    d.is_current = 0
WHERE d.is_current = 1
  AND (NOT (d.city <=> s.city) OR NOT (d.segment <=> s.segment));

-- Langkah B: sisipkan versi baru (pelanggan berubah ATAU pelanggan baru)
INSERT INTO dim_customer
  (customer_id, customer_name, phone, email, city, segment,
   effective_date, end_date, is_current)
SELECT s.customer_id, s.customer_name, s.phone, s.email, s.city, s.segment,
       s.snapshot_date, '9999-12-31', 1
FROM stg_customer_latest s
LEFT JOIN dim_customer d
       ON d.customer_id = s.customer_id AND d.is_current = 1
WHERE d.customer_key IS NULL;

-- UJI COBA: C0001 pindah ke Pekanbaru dan naik menjadi Platinum pada 1 Nov 2026
INSERT INTO stg_customer_latest
VALUES ('C0001', 'Contoh Pelanggan', NULL, NULL, 'Pekanbaru', 'Platinum', '2026-11-01');
-- jalankan Langkah A lalu Langkah B, kemudian cek:
SELECT * FROM dim_customer WHERE customer_id = 'C0001' ORDER BY effective_date;

-- 07. TABEL FAKTA (dipartisi per bulan berdasarkan date_key)
-- Catatan: tabel InnoDB yang dipartisi TIDAK mendukung FOREIGN KEY, dan kolom
-- partisi (date_key) wajib menjadi bagian dari PRIMARY KEY.
DROP TABLE IF EXISTS fact_sales;
CREATE TABLE fact_sales (
  sales_key        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  date_key         INT             NOT NULL,
  customer_key     INT             NOT NULL,
  product_key      INT             NOT NULL,
  store_key        INT             NOT NULL,
  payment_key      INT             NOT NULL,
  trx_id           VARCHAR(20)     NOT NULL,   -- degenerate dimension
  qty              INT             NOT NULL,
  unit_price       DECIMAL(12,2)   NOT NULL,
  discount_pct     DECIMAL(5,2)    NOT NULL,
  gross_amount     DECIMAL(14,2)   NOT NULL,
  discount_amount  DECIMAL(14,2)   NOT NULL,
  net_amount       DECIMAL(14,2)   NOT NULL,
  PRIMARY KEY (sales_key, date_key),
  KEY idx_f_customer (customer_key),
  KEY idx_f_product  (product_key),
  KEY idx_f_store    (store_key)
) ENGINE=InnoDB
PARTITION BY RANGE (date_key) (
    PARTITION p202601 VALUES LESS THAN (20260201),
    PARTITION p202602 VALUES LESS THAN (20260301),
    PARTITION p202603 VALUES LESS THAN (20260401),
    PARTITION p202604 VALUES LESS THAN (20260501),
    PARTITION p202605 VALUES LESS THAN (20260601),
    PARTITION p202606 VALUES LESS THAN (20260701),
    PARTITION p202607 VALUES LESS THAN (20260801),
    PARTITION p202608 VALUES LESS THAN (20260901),
    PARTITION p202609 VALUES LESS THAN (20261001),
    PARTITION p202610 VALUES LESS THAN (20261101),
    PARTITION p202611 VALUES LESS THAN (20261201),
    PARTITION p202612 VALUES LESS THAN (20270101),
    PARTITION pmax VALUES LESS THAN MAXVALUE
);

-- Memuat fakta: setiap baris staging dipetakan ke surrogate key dimensi.
-- Join ke dim_customer memakai rentang tanggal agar mendapat VERSI yang tepat (SCD2).
INSERT INTO fact_sales
  (date_key, customer_key, product_key, store_key, payment_key, trx_id,
   qty, unit_price, discount_pct, gross_amount, discount_amount, net_amount)
SELECT CAST(DATE_FORMAT(s.trx_ts, '%Y%m%d') AS UNSIGNED),
       c.customer_key, p.product_key, st.store_key, pm.payment_key, s.trx_id,
       s.qty, s.unit_price, s.discount_pct,
       s.qty * s.unit_price,
       s.qty * s.unit_price
         - ROUND(s.qty * s.unit_price * (1 - s.discount_pct / 100), 2),
       ROUND(s.qty * s.unit_price * (1 - s.discount_pct / 100), 2)
FROM stg_sales_clean s
JOIN dim_customer c  ON c.customer_id = s.customer_id
                    AND DATE(s.trx_ts) BETWEEN c.effective_date AND c.end_date
JOIN dim_product  p  ON p.product_code = s.product_code
JOIN dim_store    st ON st.store_code  = s.store_code
JOIN dim_payment  pm ON pm.payment_method = s.payment_method;

-- Validasi
SELECT COUNT(*) AS baris_fakta FROM fact_sales;           -- harus = 2937
SELECT COUNT(*) AS baris_staging FROM stg_sales_clean;    -- 2937
SELECT ROUND(SUM(net_amount), 2) AS omzet_fakta FROM fact_sales;
SELECT ROUND(SUM(qty * unit_price * (1 - discount_pct / 100)), 2) AS omzet_staging
FROM stg_sales_clean;                                      -- harus sama (selisih pembulatan kecil)

-- Lihat distribusi baris per partisi
SELECT PARTITION_NAME, TABLE_ROWS
FROM INFORMATION_SCHEMA.PARTITIONS
WHERE TABLE_SCHEMA = 'retail_dw' AND TABLE_NAME = 'fact_sales'
ORDER BY PARTITION_ORDINAL_POSITION;

-- 08. BASELINE (sebelum optimasi): fakta TANPA partisi
DROP TABLE IF EXISTS fact_sales_np;
CREATE TABLE fact_sales_np LIKE fact_sales;
ALTER TABLE fact_sales_np REMOVE PARTITIONING;
INSERT INTO fact_sales_np SELECT * FROM fact_sales;
ANALYZE TABLE fact_sales_np, fact_sales;

-- Query laporan harian (skenario A: baseline)
SELECT d.full_date, st.store_name, p.category,
       COUNT(*)            AS jumlah_item,
       SUM(f.qty)          AS total_qty,
       SUM(f.net_amount)   AS omzet
FROM fact_sales_np f
JOIN dim_date    d  ON d.date_key    = f.date_key
JOIN dim_store   st ON st.store_key  = f.store_key
JOIN dim_product p  ON p.product_key = f.product_key
WHERE f.date_key BETWEEN 20260901 AND 20260930
GROUP BY d.full_date, st.store_name, p.category
ORDER BY d.full_date, omzet DESC;

-- Skenario B: tabel berpartisi (query sama, ganti fact_sales_np -> fact_sales)
-- Buktikan partition pruning: kolom "partitions" harus hanya menampilkan p202609
EXPLAIN
SELECT d.full_date, st.store_name, p.category, COUNT(*), SUM(f.qty), SUM(f.net_amount)
FROM fact_sales f
JOIN dim_date    d  ON d.date_key    = f.date_key
JOIN dim_store   st ON st.store_key  = f.store_key
JOIN dim_product p  ON p.product_key = f.product_key
WHERE f.date_key BETWEEN 20260901 AND 20260930
GROUP BY d.full_date, st.store_name, p.category;

-- 09. MATERIALIZED VIEW (diemulasi, karena MySQL tidak punya CREATE MATERIALIZED VIEW)
DROP TABLE IF EXISTS mv_daily_sales;
CREATE TABLE mv_daily_sales (
  sale_date     DATE          NOT NULL,
  store_key     INT           NOT NULL,
  category      VARCHAR(50)   NOT NULL,
  jumlah_item   INT           NOT NULL,
  total_qty     INT           NOT NULL,
  gross_amount  DECIMAL(16,2) NOT NULL,
  net_amount    DECIMAL(16,2) NOT NULL,
  refreshed_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (sale_date, store_key, category)
) ENGINE=InnoDB;

-- Prosedur refresh inkremental: hitung ulang mulai tanggal p_from
DROP PROCEDURE IF EXISTS sp_refresh_mv_daily_sales;
DELIMITER $$
CREATE PROCEDURE sp_refresh_mv_daily_sales(IN p_from DATE)
BEGIN
  DELETE FROM mv_daily_sales WHERE sale_date >= p_from;

  INSERT INTO mv_daily_sales
    (sale_date, store_key, category, jumlah_item, total_qty, gross_amount, net_amount)
  SELECT d.full_date, f.store_key, p.category,
         COUNT(*), SUM(f.qty), SUM(f.gross_amount), SUM(f.net_amount)
  FROM fact_sales f
  JOIN dim_date    d ON d.date_key    = f.date_key
  JOIN dim_product p ON p.product_key = f.product_key
  WHERE d.full_date >= p_from
  GROUP BY d.full_date, f.store_key, p.category;
END$$
DELIMITER ;

-- Pemuatan awal (full refresh)
CALL sp_refresh_mv_daily_sales('2026-01-01');

-- Penjadwalan otomatis harian (refresh 3 hari terakhir)
SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS ev_refresh_mv_daily_sales;
CREATE EVENT ev_refresh_mv_daily_sales
  ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 1 HOUR)
  DO CALL sp_refresh_mv_daily_sales(DATE_SUB(CURDATE(), INTERVAL 3 DAY));

-- Skenario C: laporan harian dibaca dari MV (hasil sama dengan query baseline)
SELECT m.sale_date AS full_date, st.store_name, m.category,
       m.jumlah_item, m.total_qty, m.net_amount AS omzet
FROM mv_daily_sales m
JOIN dim_store st ON st.store_key = m.store_key
WHERE m.sale_date BETWEEN '2026-09-01' AND '2026-09-30'
ORDER BY m.sale_date, omzet DESC;

-- Cek kesesuaian MV vs fakta (selisih harus 0)
SELECT (SELECT SUM(net_amount) FROM fact_sales) -
       (SELECT SUM(net_amount) FROM mv_daily_sales) AS selisih;
