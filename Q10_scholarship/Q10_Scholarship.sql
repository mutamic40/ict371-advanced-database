-- ============================================================
-- ICT371 - Q10: Scholarship Application Assessment
-- Database: ict371_exam
-- ============================================================

-- Qualifies only if age 18-25 inclusive AND monthly income <= K3,000 AND average mark >= 70.

-- Each question lives in its own schema (Q10), so questions never clash and a single
-- DROP SCHEMA makes this script re-runnable without touching other questions.

DROP SCHEMA IF EXISTS Q10 CASCADE;
CREATE SCHEMA Q10;
SET search_path TO Q10;   -- everything below is created inside Q10


-- ============================================================
-- Part (a): Tables and Constraints
-- ============================================================

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name      TEXT NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT  NOT NULL REFERENCES students(student_id),
    age_at_application INT  NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             TEXT NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     TEXT NOT NULL,
    new_status     TEXT NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('S001', 'Chipo Phiri'), ('S002', 'Mwamba Banda'), ('S003', 'Leya Tembo');


-- Six PENDING applications across three students: qualifying, failing and boundary cases

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 80.00, CURRENT_DATE - 20, 'PENDING'),   -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 18, 'PENDING'),   -- 2 boundary on all three rules: qualifies
    (2, 25, 1500.00, 90.00, CURRENT_DATE - 15, 'PENDING'),   -- 3 age 25 (upper boundary): qualifies
    (2, 26, 1000.00, 85.00, CURRENT_DATE - 12, 'PENDING'),   -- 4 age 26: fails
    (3, 22, 3001.00, 75.00, CURRENT_DATE - 10, 'PENDING'),   -- 5 income just above K3,000: fails
    (3, 19, 2500.00, 69.99, CURRENT_DATE - 5,  'PENDING');   -- 6 mark just below 70: fails


-- ============================================================
-- Part (b): Function
-- ============================================================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = Q10    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$;

SELECT fn_scholarship_eligible(18, 3000, 70)    AS all_boundaries_expect_true,
       fn_scholarship_eligible(17, 1000, 90)    AS age17_expect_false,
       fn_scholarship_eligible(26, 1000, 90)    AS age26_expect_false,
       fn_scholarship_eligible(20, 3000.01, 90) AS income_expect_false,
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_expect_false;

DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
  RAISE NOTICE 'TEST FAILED: NULL accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (NULL rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
  RAISE NOTICE 'TEST FAILED: age 0 accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (age 0 rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
  RAISE NOTICE 'TEST FAILED: negative income accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (negative income rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
  RAISE NOTICE 'TEST FAILED: mark 101 accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (mark 101 rejected): %', SQLERRM; END $$;


-- ============================================================
-- Part (d): Trigger
-- ============================================================

CREATE OR REPLACE FUNCTION fn_trg_decision_audit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = Q10    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_trg_decision_audit();


-- ============================================================
-- Part (c): Procedure
-- ============================================================

-- FOR UPDATE locks the application, so two runs cannot assess the same one twice.

CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
SET search_path = Q10    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_status TEXT;
    v_age    INT;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_status;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark) THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;


-- Assess one application by hand

CALL pr_assess_application(1);

SELECT application_id, status FROM applications WHERE application_id = 1;                -- APPROVED

SELECT * FROM decision_audit;                                                             -- 1 row: PENDING -> APPROVED

DO $$ BEGIN CALL pr_assess_application(1);
  RAISE NOTICE 'TEST FAILED: reassessment accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (already assessed rejected): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_assess_application(999);
  RAISE NOTICE 'TEST FAILED: unknown application accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown application rejected): %', SQLERRM; END $$;


-- Trigger test: an update that leaves status unchanged writes no audit row

SELECT COUNT(*) AS audit_before FROM decision_audit;

UPDATE applications SET status = status WHERE application_id = 1;

UPDATE applications SET monthly_income = 2100 WHERE application_id = 1;

SELECT COUNT(*) AS audit_after FROM decision_audit;                                       -- identical


-- ============================================================
-- Part (g): Scheduled Job
-- ============================================================

-- A query FOR loop over PENDING applications only; completed ones are never selected,
-- so a rerun cannot reassess them or add duplicate audit rows.

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
SET search_path = Q10    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();

SELECT application_id, age_at_application, monthly_income, average_mark, status FROM applications ORDER BY application_id;
                                                  -- 1,2,3 APPROVED; 4,5,6 REJECTED

SELECT COUNT(*) AS audit_rows_expect_6 FROM decision_audit;

CALL pr_assess_pending();                                              -- rerun: nothing is pending

SELECT COUNT(*) AS audit_rows_after_rerun_expect_6 FROM decision_audit;

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('assess_pending', '0 8 * * 1', $cmd$CALL Q10.pr_assess_pending()$cmd$);
    RAISE NOTICE 'pg_cron job assess_pending scheduled for Mondays 08:00';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS scheduler fallback below.', SQLERRM;
END $$;

-- Fallback: crontab  0 8 * * 1 psql -U postgres -d ict371_exam -c "CALL Q10.pr_assess_pending();"


-- ============================================================
-- Part (e): View
-- ============================================================

-- Shows only what is needed; household income is omitted.

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants ORDER BY student_number;


-- ============================================================
-- Part (f): Index
-- ============================================================

-- Query: applications with a given status in a submitted_on range.  status (equality) first,
-- submitted_on (range) second.

CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

EXPLAIN ANALYZE
SELECT * FROM applications WHERE status = 'APPROVED' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = OFF;                                                  -- tiny table: show the index is usable

EXPLAIN ANALYZE
SELECT * FROM applications WHERE status = 'APPROVED' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = ON;