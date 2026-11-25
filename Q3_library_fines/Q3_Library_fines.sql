-- ============================================================
-- ICT371 - Q3: Library Returns and Overdue Fines
-- ============================================================
-- Each question lives in its own schema (Q3), so questions never clash and a single
-- DROP SCHEMA makes this script re-runnable without touching other questions.
DROP SCHEMA IF EXISTS Q3 CASCADE;
CREATE SCHEMA Q3;
SET search_path TO Q3;   -- everything below is created inside q3
-- ============================================
-- Part (a): Tables and constraints
-- ============================================
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   TEXT NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name TEXT NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_loans_due CHECK (due_on >= borrowed_on),
    CONSTRAINT ck_loans_return CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES ('Database Foundations'), ('Programming Foundations'), ('Networks Explained');

-- Six loans, all inserted OPEN.  Returns are recorded later through the procedure
-- (after the trigger exists) so the audit rows are produced naturally.
-- Open fines are not stored; they are calculated on demand by fn_loan_fine.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mwale',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue (16 days)
    (2, 'Brian Chanda',  CURRENT_DATE - 3,  CURRENT_DATE + 11),  -- 2 open, on time
    (1, 'Carol Zulu',    CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 3 will be returned LATE
    (3, 'David Phiri',   CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 4 will be returned ON the due date
    (2, 'Esther Banda',  CURRENT_DATE - 15, CURRENT_DATE - 1),   -- 5 will be returned EARLY
    (3, 'Felix Moyo',    CURRENT_DATE - 12, CURRENT_DATE - 2);   -- 6 open, overdue (2 days)

-- ============================================
-- Part (b): Function
-- ============================================
-- Overdue days counted up to the EARLIER of p_as_of and returned_on.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q3    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_due DATE;
    v_ret DATE;
    v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
    RETURN 2 * GREATEST(v_end - v_due, 0);       -- never below zero
END;
$$;

-- ============================================
-- Part (c): Procedure
-- A procedure body runs as one unit: if any statement raises an error,
-- Both updates run inside one procedure call, so the return date and the final
-- fine are stored together or not at all.
-- ============================================

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
SET search_path = q3    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed_on %', p_returned_on, v_borrowed;
    END IF;

    UPDATE loans SET returned_on = p_returned_on WHERE loan_id = p_loan_id;
    UPDATE loans SET fine_amount = fn_loan_fine(p_loan_id, p_returned_on) WHERE loan_id = p_loan_id;
END;
$$;

-- ============================================
-- Part (d): Trigger
-- The second UPDATE in the procedure does not change returned_on, so it adds no audit row.
-- ============================================

CREATE OR REPLACE FUNCTION fn_trg_loan_audit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = q3    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_trg_loan_audit();

-- Record the three returns
CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late  -> K12
CALL pr_return_loan(4, CURRENT_DATE - 6);    -- on the due date -> K0
CALL pr_return_loan(5, CURRENT_DATE - 5);    -- early -> K0

SELECT loan_id, due_on, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;                       -- exactly 3 rows
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id; -- 32, 0, 12, 0, 0, 4

-- Tests that must fail
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: second return accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (already returned rejected): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: unknown loan accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown loan rejected): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
  RAISE NOTICE 'TEST FAILED: return before borrowing accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (return before borrowed_on rejected): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
  RAISE NOTICE 'TEST FAILED: unknown loan accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (fn unknown loan rejected): %', SQLERRM; END $$;

-- Trigger test: updating a column other than returned_on must NOT write an audit row
SELECT COUNT(*) AS audit_before FROM loan_audit;
UPDATE loans SET borrower_name = 'Alice M. Mwale' WHERE loan_id = 1;
SELECT COUNT(*) AS audit_after FROM loan_audit;                    -- identical

-- ============================================
-- Part (e): View
-- ============================================
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans ORDER BY loan_id;                    -- loans 1 and 6

-- ============================================
-- Part (f): Index
-- Query: unreturned loans of one book.  A PARTIAL index holds only the rows
-- WHERE returned_on IS NULL, so it stays small (most loans are eventually
-- returned) and matches the query's two conditions exactly.
-- ============================================

CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN ANALYZE
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
SET enable_seqscan = OFF;                                          -- tiny table: show the index is usable
EXPLAIN ANALYZE
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
SET enable_seqscan = ON;


-- ============================================
-- Part (g): Scheduled job
-- Counts loans still unreturned as of p_as_of (borrowed by then, and not returned,
-- or returned only after that date) and sums their fines as of that date.
-- ============================================

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
SET search_path = q3    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET overdue_count = EXCLUDED.overdue_count,
                  total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;                                      -- 3 loans, fine 36
CALL pr_refresh_overdue(CURRENT_DATE);                              -- rerun replaces the same date
SELECT * FROM overdue_summary;

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_overdue', '10 0 * * *',
                          $cmd$CALL q3.pr_refresh_overdue(CURRENT_DATE)$cmd$);
    RAISE NOTICE 'pg_cron job refresh_overdue scheduled for 00:10 daily';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS scheduler fallback below.', SQLERRM;
END $$;
-- Fallback: crontab  10 0 * * * psql -U postgres -d ict371_exam -c "CALL Q3.pr_refresh_overdue(CURRENT_DATE);"
--           Windows Task Scheduler, daily 00:10, same psql command.