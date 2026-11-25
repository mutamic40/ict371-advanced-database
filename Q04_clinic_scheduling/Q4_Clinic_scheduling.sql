-- ============================================================
-- ICT371 - Q4: Clinic Appointment Scheduling
-- Slots per doctor per day: 09:00, 10:00, 11:00, 12:00.
-- ============================================================
-- Each question lives in its own schema (Q4), so questions never clash.
-- A single DROP SCHEMA makes this script re-runnable without
-- touching other questions.

DROP SCHEMA IF EXISTS Q4 CASCADE;
CREATE SCHEMA Q4;
SET search_path TO Q4;

-- ============================================================
-- PART (a): TABLES AND CONSTRAINTS
-- ============================================================

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL
);

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status TEXT NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_slot CHECK (
        slot_time IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time)
    ),
    CONSTRAINT ck_status CHECK (
        status IN ('BOOKED', 'ATTENDED', 'CANCELLED')
    )
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0,
    attended_count INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

-- Seed patients and doctors (appointments are seeded further down,
-- once the Part (d) trigger exists to validate them).

INSERT INTO patients (full_name)
VALUES ('Misozi Zulu'), ('Tapiwa Soko'), ('Bwalya Lungu');

INSERT INTO doctors (full_name)
VALUES ('Dr Mulenga'), ('Dr Chileshe'), ('Dr Banda');


-- ============================================================
-- PART (b): FUNCTION - DAILY DOCTOR APPOINTMENT LOAD
-- ============================================================

CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INT,
    p_day DATE
)
RETURNS INT
LANGUAGE plpgsql
SET search_path = q4
AS $$
DECLARE
    v_n INT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM doctors
        WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*)
    INTO v_n
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_n;
END;
$$;


-- ============================================================
-- PART (c): PROCEDURE - BOOK APPOINTMENT
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id INT,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
SET search_path = q4
AS $$
BEGIN
    IF p_patient_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM patients
        WHERE patient_id = p_patient_id
    ) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    IF p_doctor_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM doctors
        WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (
        '09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time
    ) THEN
        RAISE EXCEPTION
            'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00',
            p_slot;
    END IF;

    INSERT INTO appointments
    (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;


-- ============================================================
-- PART (d): TRIGGER - APPOINTMENT CLASH PREVENTION
-- ============================================================
-- Two non-cancelled appointments cannot share the same
-- doctor, appointment day and time slot.
-- The doctor row is locked to prevent simultaneous bookings.
-- Created here, before any appointment data exists, since every
-- later INSERT (direct or via the Part (c) procedure) must be
-- validated by it.

CREATE OR REPLACE FUNCTION fn_trg_appointment_clash()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = q4
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        PERFORM 1
        FROM doctors
        WHERE doctor_id = NEW.doctor_id
        FOR UPDATE;

        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time = NEW.slot_time
              AND a.status <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN
            RAISE EXCEPTION
                'Slot clash: doctor % already has an appointment on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_appointment_clash();


-- ============================================================
-- SEED DATA: six sample appointments
-- (now that the trigger exists to validate them)
-- ============================================================

INSERT INTO appointments
(patient_id, doctor_id, appointment_day, slot_time, status)
VALUES
    (1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 2, '10:00', 'CANCELLED'),
    (1, 2, CURRENT_DATE, '09:00', 'BOOKED'),
    (2, 2, CURRENT_DATE, '10:00', 'BOOKED'),
    (3, 3, CURRENT_DATE + 1, '11:00', 'BOOKED'),
    (3, 1, CURRENT_DATE + 1, '12:00', 'BOOKED');


-- ============================================================
-- TESTS: PART (b) fn_daily_load
-- ============================================================

SELECT
    fn_daily_load(1, CURRENT_DATE - 2) AS d1_two_days_ago_expect_1,
    fn_daily_load(2, CURRENT_DATE) AS d2_today_expect_2,
    fn_daily_load(3, CURRENT_DATE) AS d3_today_expect_0;

DO $$
BEGIN
    PERFORM fn_daily_load(99, CURRENT_DATE);
    RAISE NOTICE 'TEST FAILED: unknown doctor accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (unknown doctor rejected): %', SQLERRM;
END $$;


-- ============================================================
-- TESTS: PART (c) pr_book_appointment
-- ============================================================

CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '09:00');

SELECT COUNT(*) AS appointments_now FROM appointments;

DO $$
BEGIN
    CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '09:00');
    RAISE NOTICE 'TEST FAILED: clash accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (clash rejected): %', SQLERRM;
END $$;

DO $$
BEGIN
    CALL pr_book_appointment(1, 3, CURRENT_DATE - 1, '09:00');
    RAISE NOTICE 'TEST FAILED: past date accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (past date rejected): %', SQLERRM;
END $$;

DO $$
BEGIN
    CALL pr_book_appointment(1, 3, CURRENT_DATE + 3, '13:00');
    RAISE NOTICE 'TEST FAILED: bad slot accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (unsupported slot rejected): %', SQLERRM;
END $$;

DO $$
BEGIN
    CALL pr_book_appointment(99, 3, CURRENT_DATE + 3, '10:00');
    RAISE NOTICE 'TEST FAILED: unknown patient accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (unknown patient rejected): %', SQLERRM;
END $$;


-- ============================================================
-- TESTS: PART (d) trigger - UPDATE validation
-- ============================================================

-- Test 1: Updating a row without changing its slot must not
-- clash with itself.

UPDATE appointments
SET status = 'BOOKED'
WHERE appointment_id = 3;

-- Test 2: Moving an appointment onto an occupied slot
-- must be rejected.

DO $$
BEGIN
    UPDATE appointments
    SET slot_time = '10:00'
    WHERE appointment_id = 3;

    RAISE NOTICE 'TEST FAILED: update clash accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (update clash rejected): %', SQLERRM;
END $$;

-- Test 3: A cancelled appointment does not block its slot.

INSERT INTO appointments
(patient_id, doctor_id, appointment_day, slot_time, status)
VALUES (3, 1, CURRENT_DATE - 2, '10:00', 'ATTENDED');


-- ============================================================
-- PART (e): VIEW - TODAY'S APPOINTMENTS
-- ============================================================
-- Displays only the fields needed by the front desk.

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT *
FROM v_today_appointments
ORDER BY slot_time;


-- ============================================================
-- PART (f): INDEX - APPOINTMENT SEARCH OPTIMIZATION
-- ============================================================
-- The composite index supports filtering by appointment day
-- and doctor ID.

CREATE INDEX idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);

EXPLAIN ANALYZE
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 2;

-- Show that the index is usable on the small sample table.

SET enable_seqscan = OFF;

EXPLAIN ANALYZE
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 2;

SET enable_seqscan = ON;


-- ============================================================
-- PART (g): SCHEDULED JOB - DAILY CLINIC SUMMARY
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
SET search_path = q4
AS $$
BEGIN
    INSERT INTO clinic_summary
    (summary_date, booked_count, attended_count, cancelled_count)
    SELECT
        p_day,
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);

SELECT * FROM clinic_summary;

-- Run again to prove that totals are replaced, not added.

CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);

SELECT * FROM clinic_summary;

-- Schedule the daily job using pg_cron.

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    PERFORM cron.schedule(
        'refresh_clinic_summary',
        '0 1 * * *',
        $cmd$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$cmd$
    );

    RAISE NOTICE
        'pg_cron job refresh_clinic_summary scheduled for 01:00 daily';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE
        'pg_cron is not available here (%). Use the OS scheduler fallback below.',
        SQLERRM;
END $$;

-- Fallback without pg_cron:
-- Linux crontab:
-- 0 1 * * * psql -U postgres -d ict371_exam -c "CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1);"