-- ============================================================
-- ICT371 - Q2: University Fee Payments
-- Re-runnable. Statements that must fail are wrapped in DO blocks.
-- ============================================================
-- DROP SCHEMA makes this script re-runnable without touching other questions.
DROP SCHEMA IF EXISTS Q2 CASCADE;
CREATE SCHEMA Q2;
SET search_path TO Q2;   -- everything below is created inside Q2

-- ============================================
-- Part (a): Tables and constraints
-- ============================================
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name      TEXT NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Three students with different balances (the payments are loaded further down,
-- through the procedure, after the trigger exists).
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S2026001', 'Chipo Phiri',   5000.00),
    ('S2026002', 'Mwamba Banda',  3000.00),
    ('S2026003', 'Leya Tembo',    2000.00);   -- will have NO payments

-- ============================================
-- Part (b): Function
-- ============================================
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q2    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_due  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_due FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    -- COALESCE makes "no payments" count as 0, so the full fee is returned.
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_due - v_paid;
END;
$$;


-- ============================================
-- Part (c): Procedure
-- The student row is locked (FOR UPDATE) so two simultaneous payments cannot
-- together exceed the balance.  fee_due is never changed.
-- ============================================

CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql
SET search_path = q2    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be a positive number, got %', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'paid_on date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
    -- no audit insert here: the trigger below does it
END;
$$;

-- ============================================
-- Part (d): Trigger
-- ============================================
CREATE OR REPLACE FUNCTION fn_trg_payment_audit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = q2    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_payment_audit();

-- Seed payments through the procedure (six payments)
CALL pr_receive_payment(1, 2000, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500, CURRENT_DATE);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE);      -- student 2 is now fully settled

SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY student_id;  -- 1000, 0, 2000
SELECT COUNT(*) AS payments_rows, (SELECT COUNT(*) FROM payment_audit) AS audit_rows FROM payments;  -- 6 and 6

-- Tests that must fail (each is caught so the script continues)
DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: NULL accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (NULL rejected): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: zero accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (zero rejected): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: negative accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (negative rejected): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 1000.01, CURRENT_DATE);   -- balance is 1000.00
  RAISE NOTICE 'TEST FAILED: overpayment accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (overpayment rejected): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_fee_balance(999);
  RAISE NOTICE 'TEST FAILED: unknown student accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown student rejected): %', SQLERRM; END $$;

SELECT COUNT(*) AS payments_after_rejections, (SELECT COUNT(*) FROM payment_audit) AS audit_rows FROM payments; -- still 6 and 6
SELECT * FROM payment_audit ORDER BY audit_id;

-- ============================================
-- Part (e): View
-- ============================================

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(p.paid, 0) AS outstanding_balance
FROM students s
LEFT JOIN (SELECT student_id, SUM(amount) AS paid FROM payments GROUP BY student_id) p
       ON p.student_id = s.student_id
WHERE s.fee_due - COALESCE(p.paid, 0) > 0;          -- settled students are excluded
SELECT * FROM v_fee_balances ORDER BY student_number;   -- S2026002 (settled) is not listed

-- ============================================
-- Part (f): Index
-- Query: one student's payments in a date range.  student_id is an equality
-- test and paid_on a range, so student_id goes FIRST: the B-tree finds that
-- student's entries and reads the dates in range in order.
-- ============================================

CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN ANALYZE
SELECT * FROM payments WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
-- With a handful of rows PostgreSQL prefers a sequential scan (cheaper).
-- Discourage it for this session to show the index is usable:
SET enable_seqscan = OFF;
EXPLAIN ANALYZE
SELECT * FROM payments WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
SET enable_seqscan = ON;
-- ============================================
-- Part (g): Scheduled job
-- Upsert: rerunning replaces the day's row, never adds to it.
-- ============================================

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
SET search_path = q2    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0) FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date)
    DO UPDATE SET payment_count = EXCLUDED.payment_count,
                  total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections;
CALL pr_refresh_collections(CURRENT_DATE - 1);      -- rerun: identical result
SELECT * FROM daily_collections;

-- Schedule daily at 01:00 for the previous day (needs the pg_cron extension).
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_collections', '0 1 * * *',
                          $cmd$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$cmd$);
    RAISE NOTICE 'pg_cron job refresh_collections scheduled for 01:00 daily';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS scheduler fallback below.', SQLERRM;
END $$;
-- Inspect (when pg_cron is installed):  SELECT * FROM cron.job;  SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
-- Fallback: Linux crontab  0 1 * * * psql -U postgres -d ict371_exam -c "CALL q2.pr_refresh_collections(CURRENT_DATE - 1);"
--           Windows: Task Scheduler, daily 01:00, running the same psql command.