-- ============================================================
-- ICT371 - Q1: Pharmacy Stock and Daily Sales
-- ============================================================

DROP SCHEMA IF EXISTS Q1 CASCADE;
CREATE SCHEMA Q1;
SET search_path TO Q1;

-- ============================================
-- Part (a): Tables and constraints
-- ============================================
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name TEXT NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),   -- price charged at sale time
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT NOT NULL,
    new_qty     INT NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 450mg', 10.50, 200),
    ('Amoxicillin 200mg', 15.00, 80),
    ('Ibuprofen 300mg',    5.00, 150);

SELECT * FROM medicines;

-- ============================================
-- Part (b): Function
-- ============================================
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number, got %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- Tests that should succeed
SELECT fn_sale_value(1, 5)  AS expect_52_50;
SELECT fn_sale_value(2, 10) AS expect_150;

-- Tests that should fail (each caught, so the script continues)
DO $$ BEGIN PERFORM fn_sale_value(1, 0);
    RAISE NOTICE 'TEST FAILED: quantity 0 accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (quantity 0 rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_sale_value(1, -3);
    RAISE NOTICE 'TEST FAILED: negative quantity accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (negative rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_sale_value(1, NULL);
    RAISE NOTICE 'TEST FAILED: NULL quantity accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (NULL rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_sale_value(999, 2);
    RAISE NOTICE 'TEST FAILED: unknown medicine accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown medicine rejected): %', SQLERRM; END $$;

-- ============================================
-- Part (c): Procedure
-- A procedure body runs as one unit: if any statement raises an error,
-- the insert and the stock update are both undone (all or nothing).
-- FOR UPDATE locks the medicine row so two sales cannot oversell stock.
-- ============================================
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock INT;
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive number, got %', p_quantity;
    END IF;

    SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: have %, requested %', v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- Six valid sales: three today, three yesterday
CALL pr_record_sale(1, 10, CURRENT_DATE);
CALL pr_record_sale(2, 5,  CURRENT_DATE);
CALL pr_record_sale(3, 8,  CURRENT_DATE);
CALL pr_record_sale(1, 15, CURRENT_DATE - 1);
CALL pr_record_sale(2, 3,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 20, CURRENT_DATE - 1);

-- Rejection test: record the "before" numbers, force an error, compare
SELECT * FROM medicines ORDER BY medicine_id;
SELECT COUNT(*) AS sales_before FROM sales;

DO $$ BEGIN CALL pr_record_sale(1, 100000, CURRENT_DATE);
    RAISE NOTICE 'TEST FAILED: oversell accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (oversell rejected): %', SQLERRM; END $$;

SELECT * FROM medicines ORDER BY medicine_id;          -- must equal the "before" stock
SELECT COUNT(*) AS sales_after FROM sales;             -- must equal sales_before (6)

-- ============================================
-- Part (d): Trigger
-- Logs only when stock_qty really changes (IS DISTINCT FROM handles NULLs).
-- ============================================
CREATE OR REPLACE FUNCTION fn_trg_stock_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_trg_stock_audit();

-- Test 1: changing another column must NOT write an audit row
SELECT COUNT(*) AS audit_before FROM stock_audit;
UPDATE medicines SET medicine_name = 'Paracetamol 500mg (renamed)' WHERE medicine_id = 1;
SELECT COUNT(*) AS audit_after_rename FROM stock_audit;      -- identical to audit_before

-- Test 2: changing stock_qty MUST write one audit row
UPDATE medicines SET stock_qty = stock_qty - 1 WHERE medicine_id = 2;
SELECT * FROM stock_audit ORDER BY audit_id DESC LIMIT 1;

-- ============================================
-- Part (e): View
-- ============================================
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

SELECT medicine_id, medicine_name, stock_qty FROM medicines ORDER BY medicine_id;
SELECT * FROM v_low_stock;                       -- empty at this point

-- Make one medicine genuinely low: sell everything except 5 units of medicine 2.
-- (Calculated from the real stock, so it never fails with "insufficient stock".)
DO $$
DECLARE v_stock INT;
BEGIN
    SELECT stock_qty INTO v_stock FROM medicines WHERE medicine_id = 2;
    IF v_stock > 5 THEN
        CALL pr_record_sale(2, v_stock - 5, CURRENT_DATE);
    END IF;
END $$;

SELECT * FROM v_low_stock;                       -- now shows Amoxicillin 200mg with 5

-- ============================================
-- Part (f): Index
-- Justification:
-- The target query filters on medicine_id (equality) and a sold_on range.
-- In a composite B-tree index, equality columns go first and the range column
-- last: PostgreSQL jumps to that medicine's entries and reads only the dates
-- in range, in order, instead of scanning the whole table.
-- ============================================
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

-- With only a few rows the planner prefers a sequential scan (cheaper than an
-- index lookup).  That is normal planner behaviour, not a flaw in the index.
EXPLAIN ANALYZE
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- To show the index is usable, discourage sequential scans for this session:
SET enable_seqscan = OFF;

EXPLAIN ANALYZE
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
-- Expect: Index (or Bitmap Index) Scan using idx_sales_medicine_sold_on

SET enable_seqscan = ON;

-- ============================================
-- Part (g): Scheduled job
-- pr_refresh_sales REPLACES the day's totals (upsert), so running it twice
-- for the same day never double-counts.
-- ============================================
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qty INT;
    v_amt NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    INTO v_qty, v_amt
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_qty, v_amt)
    ON CONFLICT (sales_date)
    DO UPDATE SET total_qty    = EXCLUDED.total_qty,
                  total_amount = EXCLUDED.total_amount;
END;
$$;

-- Prove correctness before scheduling: run twice, totals must stay identical
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales ORDER BY sales_date;
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales ORDER BY sales_date;
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;

-- Schedule: every day at 00:15, processing the PREVIOUS day.
-- pg_cron needs superuser and shared_preload_libraries = 'pg_cron'.  The DO
-- block tries it and, if the extension is missing, prints a message instead of
-- stopping the script.  A procedure is run with CALL, not SELECT.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule(
        'refresh_daily_sales',
        '15 0 * * *',
        $cmd$CALL pr_refresh_sales(CURRENT_DATE - 1)$cmd$
    );
    RAISE NOTICE 'pg_cron job refresh_daily_sales scheduled for 00:15 daily';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS-level fallback below.', SQLERRM;
END $$;

-- Inspect jobs and history (only when pg_cron is installed):
-- SELECT * FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Fallback without pg_cron: an operating-system scheduled task that runs
--   psql -U postgres -d ict371_exam -c "CALL pr_refresh_sales(CURRENT_DATE - 1);"
-- Linux crontab line:   15 0 * * * psql -U postgres -d ict371_exam -c "CALL pr_refresh_sales(CURRENT_DATE - 1);"
-- On Windows use Task Scheduler with a daily 00:15 trigger running the same psql command.