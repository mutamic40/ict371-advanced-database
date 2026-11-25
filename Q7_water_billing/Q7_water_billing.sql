-- ============================================================
-- ICT371 - Q7: Water Meter Readings and Billing
-- ============================================================

-- ============================================================
-- Part (a): Tables and Constraints
-- ============================================================

DROP SCHEMA IF EXISTS Q7 CASCADE;
CREATE SCHEMA Q7;
SET search_path TO Q7;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   TEXT NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT  NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT ck_reading_month CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES ('Chipo Phiri'), ('Mwamba Banda'), ('Leya Tembo');


-- ============================================================
-- Part (b): Function
-- ============================================================

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = Q7
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Units must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Units must not be negative, got %', p_units;
    END IF;
    RETURN round(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

SELECT fn_water_charge(0) AS u0_expect_0, fn_water_charge(5) AS u5_expect_25, fn_water_charge(10) AS u10_expect_50,
       fn_water_charge(15) AS u15_expect_90, fn_water_charge(25) AS u25_expect_170;

DO $$ BEGIN PERFORM fn_water_charge(NULL);
  RAISE NOTICE 'TEST FAILED: NULL accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (NULL rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_water_charge(-1);
  RAISE NOTICE 'TEST FAILED: negative accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (negative rejected): %', SQLERRM; END $$;


-- ============================================================
-- Part (c): Procedure
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
SET search_path = Q7
AS $$
DECLARE
    v_prev NUMERIC(12,2);
    v_curr NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 15);
UPDATE bills SET amount_paid = 30 WHERE reading_id = 3;
UPDATE bills SET amount_paid = 25 WHERE reading_id = 5;
SELECT * FROM bills ORDER BY bill_id;

DO $$ BEGIN CALL pr_generate_bill(2, CURRENT_DATE + 30);
  RAISE NOTICE 'TEST FAILED: second bill accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (duplicate bill rejected): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: unknown reading accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown reading rejected): %', SQLERRM; END $$;

DO $$ BEGIN UPDATE bills SET amount_paid = 999 WHERE reading_id = 2;
  RAISE NOTICE 'TEST FAILED: overpaid bill accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (amount_paid above charge rejected): %', SQLERRM; END $$;


-- ============================================================
-- Part (d): Trigger
-- ============================================================

CREATE OR REPLACE FUNCTION fn_trg_reading_check()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = Q7
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)', NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_trg_reading_check();

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, date_trunc('month', CURRENT_DATE - interval '2 months')::date, 100, 100),
    (1, date_trunc('month', CURRENT_DATE - interval '1 month')::date,  100, 110),
    (2, date_trunc('month', CURRENT_DATE - interval '2 months')::date,  50,  65),
    (2, date_trunc('month', CURRENT_DATE - interval '1 month')::date,   65,  75),
    (3, date_trunc('month', CURRENT_DATE - interval '2 months')::date,   0,   5),
    (3, date_trunc('month', CURRENT_DATE - interval '1 month')::date,    5,  30);

SELECT COUNT(*) AS readings_before FROM readings;

DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, date_trunc('month', CURRENT_DATE)::date, 200, 150);
  RAISE NOTICE 'TEST FAILED: lower reading accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (lower reading rejected): %', SQLERRM; END $$;

DO $$ BEGIN UPDATE readings SET current_reading = 1 WHERE reading_id = 6;
  RAISE NOTICE 'TEST FAILED: lower update accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (lower update rejected): %', SQLERRM; END $$;

SELECT COUNT(*) AS readings_after FROM readings;


-- ============================================================
-- Part (e): View
-- ============================================================

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;


-- ============================================================
-- Part (f): Index
-- ============================================================

CREATE INDEX idx_bills_unpaid_due ON bills (due_on) INCLUDE (reading_id, charge, amount_paid)
WHERE amount_paid < charge;

EXPLAIN ANALYZE
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE ORDER BY due_on;

SET enable_seqscan = OFF;

EXPLAIN ANALYZE
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE ORDER BY due_on;

SET enable_seqscan = ON;


-- ============================================================
-- Part (g): Scheduled Job
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
SET search_path = Q7
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_receivables', '30 0 * * *', $cmd$CALL Q7.pr_refresh_receivables()$cmd$);
    RAISE NOTICE 'pg_cron job refresh_receivables scheduled for 00:30 daily';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS scheduler fallback below.', SQLERRM;
END $$;