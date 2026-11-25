
-- ============================================================
-- ICT371 - Q6: Monthly Payroll Processing
-- Gross Pay = Basic Salary + Allowance
-- Net Pay = Gross Pay - Deduction
-- ============================================================
-- Each question lives in its own schema (Q6), ensuring that
-- questions do not clash and the script can be re-run safely.

DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6;

-- ============================================================
-- PART (a): TABLES AND CONSTRAINTS
-- ============================================================

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    TEXT NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT  NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT ck_pay_month_start
        CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_payroll_emp_month
        UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Insert sample employee records.

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chipo Phiri',   5000, 500, 300, TRUE),
    ('Mwamba Banda',  4000, 200, 100, TRUE),
    ('Leya Tembo',    3500,   0, 200, TRUE),
    ('Tapiwa Soko',   6000, 800, 400, FALSE);


-- ============================================================
-- PART (b): FUNCTION - CALCULATE EMPLOYEE NET PAY
-- ============================================================

CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q6
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded   NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := v_basic + v_allow - v_ded;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;


-- ============================================================
-- PART (c): PROCEDURE - PROCESS MONTHLY PAYROLL
-- ============================================================
-- Processes payroll for all active employees.
-- The procedure runs as one unit: if an employee fails,
-- all inserts made during that call are rolled back.
-- Existing employee/month records are left unchanged.

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
SET search_path = q6
AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active ORDER BY employee_id LOOP
        v_net := fn_net_pay(rec.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;


-- ============================================================
-- PART (d): TRIGGER - SALARY CHANGE AUDIT
-- ============================================================
-- Records changes to an employee's basic salary.
-- Changes to other employee fields are not recorded.

CREATE OR REPLACE FUNCTION fn_trg_salary_audit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = q6
AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_trg_salary_audit();


-- ============================================================
-- PART (d): MONTHLY PAYROLL PROCESSING TESTS
-- ============================================================

-- Process payroll for two consecutive months.
-- Employee 3 becomes inactive after the first month.
-- Their previous payroll history remains available.

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE - interval '2 months'))::date);

UPDATE employees SET active = FALSE WHERE employee_id = 3;

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE - interval '1 month'))::date);

SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- Test that rerunning payroll does not create duplicate records.

SELECT COUNT(*) AS payroll_rows_before FROM payroll;

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE - interval '1 month'))::date);

SELECT COUNT(*) AS payroll_rows_after FROM payroll;


-- ============================================================
-- PART (d): VALIDATION AND ERROR-HANDLING TESTS
-- ============================================================

-- Test 1: Reject a date that is not the first day of a month.

DO $$
BEGIN
    CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date + 1);
    RAISE NOTICE 'TEST FAILED: non month-start accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (non month-start rejected): %', SQLERRM;
END $$;

-- Test 2: Reject an unknown employee.

DO $$
BEGIN
    PERFORM fn_net_pay(999);
    RAISE NOTICE 'TEST FAILED: unknown employee accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (unknown employee rejected): %', SQLERRM;
END $$;

-- Test 3: Verify that an invalid employee causes the entire
-- payroll processing call to fail and roll back.

DO $$
BEGIN
    INSERT INTO employees (full_name, basic_salary, allowance, deduction, active)
    VALUES ('Bad Data', 100, 0, 99999, TRUE);

    CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);

    RAISE NOTICE 'TEST FAILED: negative net accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (whole call failed): %', SQLERRM;
END $$;

SELECT COUNT(*) AS rows_for_current_month_expect_0
FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;


-- ============================================================
-- PART (d): TRIGGER VALIDATION TESTS
-- ============================================================

-- Test 1: Changing basic salary creates an audit record.
UPDATE employees SET basic_salary = 5200 WHERE employee_id = 1;

-- Test 2: Changing allowance does not create an audit record.
UPDATE employees SET allowance = 600 WHERE employee_id = 1;

-- Test 3: Updating salary to the same value creates no new record.
UPDATE employees SET basic_salary = 5200 WHERE employee_id = 1;

-- Display salary audit records.
SELECT * FROM salary_audit;


-- ============================================================
-- PART (e): VIEW - MONTHLY PAYROLL REPORT
-- ============================================================
-- Includes payroll history even for employees who later
-- become inactive.

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;


-- ============================================================
-- PART (f): INDEX - MONTHLY PAYROLL SEARCH OPTIMIZATION
-- ============================================================
-- The composite unique index starts with employee_id.
-- This index starts with pay_month to support searches
-- retrieving all employees' payroll for a particular month.
-- INCLUDE makes the report columns available in the index.

CREATE INDEX idx_payroll_pay_month
ON payroll (pay_month)
INCLUDE (employee_id, gross_pay, net_pay);

-- Test query performance.

EXPLAIN ANALYZE
SELECT employee_id, gross_pay, net_pay FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE - interval '1 month')::date;

-- Show that the index is usable on the small sample table.

SET enable_seqscan = OFF;

EXPLAIN ANALYZE
SELECT employee_id, gross_pay, net_pay FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE - interval '1 month')::date;

SET enable_seqscan = ON;


-- ============================================================
-- PART (g): SCHEDULED JOB - AUTOMATIC MONTHLY PAYROLL
-- ============================================================
-- Runs at 02:00 on the first day of every month.
-- Processes payroll for the previous month.

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    PERFORM cron.schedule(
        'process_payroll',
        '0 2 1 * *',
        $cmd$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - interval '1 month')::date)$cmd$
    );

    RAISE NOTICE
        'pg_cron job process_payroll scheduled for 02:00 on the 1st of each month';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE
        'pg_cron is not available here (%). Use the OS scheduler fallback below.',
        SQLERRM;
END $$;

-- ============================================================
-- SCHEDULED JOB MANAGEMENT AND FALLBACK
-- ============================================================

-- Inspect the scheduled job and its execution history.
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time
-- FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Remove the scheduled job if necessary.
-- SELECT cron.unschedule('process_payroll');

-- Fallback without pg_cron (Linux crontab):
-- 0 2 1 * * psql -U postgres -d ict371_exam -c "CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - interval '1 month')::date);"

-- Windows: Use Task Scheduler with a monthly trigger
-- on day 1 at 02:00, running the same psql command.
