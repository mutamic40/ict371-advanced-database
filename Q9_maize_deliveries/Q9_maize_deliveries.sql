-- ============================================================
-- ICT371 - Q9: Farmer Cooperative Maize Deliveries
-- Database: ict371_exam
-- ============================================================

-- Rates: grade A K5/kg, B K4/kg, C K3/kg.  The trigger prices EVERY row, including direct SQL.

-- Each question lives in its own schema (Q9), so questions never clash and a single
-- DROP SCHEMA makes this script re-runnable without touching other questions.

DROP SCHEMA IF EXISTS Q9 CASCADE;
CREATE SCHEMA Q9;
SET search_path TO Q9;   -- everything below is created inside Q9


-- ============================================================
-- Part (a): Tables and Constraints
-- ============================================================

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number TEXT NOT NULL UNIQUE,
    full_name     TEXT NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT  NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,          -- filled by the trigger
    total_value  NUMERIC(12,2) NOT NULL,          -- filled by the trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FM001', 'Lusungu Daka'), ('FM002', 'Nchimunya Hama'), ('FM003', 'Taonga Zulu');


-- ============================================================
-- Part (b): Function
-- ============================================================

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = Q9    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;
    v_rate := CASE upper(btrim(p_grade)) WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: %. Use A, B or C', p_grade;
    END IF;
    RETURN v_rate;
END;
$$;

SELECT fn_maize_rate('A') AS a_expect_5, fn_maize_rate('B') AS b_expect_4, fn_maize_rate('C') AS c_expect_3;

DO $$ BEGIN PERFORM fn_maize_rate(NULL);
  RAISE NOTICE 'TEST FAILED: NULL grade accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (NULL grade rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_maize_rate('D');
  RAISE NOTICE 'TEST FAILED: grade D accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (grade D rejected): %', SQLERRM; END $$;


-- ============================================================
-- Part (d): Trigger
-- ============================================================

-- Sets unit_rate and total_value from the grade and weight on every insert and update,
-- so a direct INSERT or UPDATE cannot store an inconsistent value.

CREATE OR REPLACE FUNCTION fn_trg_delivery_pricing()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = Q9    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := round(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_trg_delivery_pricing();


-- ============================================================
-- Part (c): Procedure
-- ============================================================

-- Inserts only the basic fields; the trigger supplies unit_rate and total_value.

CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
SET search_path = Q9    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    IF p_farmer_id IS NULL OR NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);                  -- rejects NULL or unsupported grade with a clear message
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, upper(btrim(p_grade)), p_weight, p_date, FALSE);
END;
$$;


-- Six deliveries: all grades; payment state changed afterwards for three of them

CALL pr_receive_delivery(1, 'A', 250.50, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 100,    CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 400,    CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 80,     CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 150.25, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C', 60,     CURRENT_DATE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 5);   -- both paid and unpaid states exist

SELECT * FROM deliveries ORDER BY delivery_id;                          -- values: 1252.50, 400, 1200, 400, 601, 180


-- Direct SQL follows the same pricing rule: the wrong values given below are overwritten

INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (3, 'A', 10, 99, 99999, CURRENT_DATE);

SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;  -- 5.00 and 50.00

DELETE FROM deliveries WHERE delivery_id = 7;


-- Tests that must fail

DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: unknown farmer accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown farmer rejected): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: zero weight accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (zero weight rejected): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: grade Z accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (grade Z rejected): %', SQLERRM; END $$;

DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on) VALUES (1, 'A', -5, 5, 0, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: negative weight accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (direct negative weight rejected): %', SQLERRM; END $$;


-- Updating the weight re-prices the row automatically:

UPDATE deliveries SET weight_kg = 100 WHERE delivery_id = 1;

SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 1;   -- 500.00


-- ============================================================
-- Part (e): View
-- ============================================================

-- LEFT JOIN with the unpaid condition inside ON keeps farmers who have no unpaid deliveries (amount 0).

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name, COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;


-- ============================================================
-- Part (f): Index
-- ============================================================

-- Query: one farmer's deliveries between two dates.  farmer_id (equality) first, delivered_on (range) second.

CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN ANALYZE
SELECT * FROM deliveries WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = OFF;                                                  -- tiny table: show the index is usable

EXPLAIN ANALYZE
SELECT * FROM deliveries WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = ON;


-- ============================================================
-- Part (g): Scheduled Job
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
SET search_path = Q9    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight,
                  total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);

SELECT * FROM daily_purchases;

CALL pr_refresh_purchases(CURRENT_DATE - 1);                              -- rerun: replaced, not doubled

SELECT * FROM daily_purchases;

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_purchases', '30 1 * * *', $cmd$CALL Q9.pr_refresh_purchases(CURRENT_DATE - 1)$cmd$);
    RAISE NOTICE 'pg_cron job refresh_purchases scheduled for 01:30 daily';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS scheduler fallback below.', SQLERRM;
END $$;

-- Fallback: crontab  30 1 * * * psql -U postgres -d ict371_exam -c "CALL Q9.pr_refresh_purchases(CURRENT_DATE - 1);"