-- ============================================================
-- ICT371 - Q8: Transport Fleet Maintenance
-- Database: ict371_exam
-- ============================================================

-- Service is due when current_odometer - last_service_odometer >= 5000 km.

-- Each question lives in its own schema (Q8), so questions never clash and a single
-- DROP SCHEMA makes this script re-runnable without touching other questions.

DROP SCHEMA IF EXISTS Q8 CASCADE;
CREATE SCHEMA Q8;
SET search_path TO Q8;   -- everything below is created inside Q8


-- ============================================================
-- Part (a): Tables and Constraints
-- ============================================================

CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          TEXT NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT  NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT  NOT NULL CHECK (end_odometer >= 0),
    CONSTRAINT ck_trip_distance CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT  NOT NULL,
    flagged_on       DATE NOT NULL
);


-- Three vehicles in different service positions

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001', 12000,  8000),    -- 4000 km since service (not due yet)
    ('ABC 1002', 20000, 14000),    -- 6000 km since service (already due)
    ('ABC 1003',  5000,  5000);    -- 0 km since service


-- ============================================================
-- Part (d): Trigger (BEFORE INSERT)
-- ============================================================

-- Locks the vehicle row, checks the start odometer equals the vehicle's current value,
-- rejects bad mileage, then moves current_odometer to the trip end.  A trip inserted
-- once fires the trigger once, so the odometer is updated exactly once.

CREATE OR REPLACE FUNCTION fn_trg_trip_odometer()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = Q8    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_current INT;
BEGIN
    SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must be greater than start)', NEW.start_odometer, NEW.end_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match the vehicle''s current odometer %', NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_trg_trip_odometer();


-- ============================================================
-- Part (b): Function
-- ============================================================

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = Q8    -- lets pg_cron / other sessions find the tables
AS $$
DECLARE
    v_cur INT;
    v_svc INT;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_cur, v_svc
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_cur - v_svc) >= 5000;
END;
$$;


-- ============================================================
-- Part (c): Procedure
-- ============================================================

-- Does NOT touch the vehicle odometer; the trigger does.

CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql
SET search_path = Q8    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    IF p_vehicle_id IS NULL OR NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are all required';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;


-- Six trips, loaded through the procedure now that the trigger exists

CALL pr_record_trip(1, CURRENT_DATE - 5, 12000, 12500);
CALL pr_record_trip(1, CURRENT_DATE - 4, 12500, 13000);    -- vehicle 1 reaches exactly 5000 km since service
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 3, 20300, 20800);
CALL pr_record_trip(3, CURRENT_DATE - 2, 5000, 5400);
CALL pr_record_trip(3, CURRENT_DATE - 1, 5400, 5900);

SELECT vehicle_id, registration, current_odometer, last_service_odometer,
       current_odometer - last_service_odometer AS km_since_service, fn_service_due(vehicle_id) AS due
FROM vehicles ORDER BY vehicle_id;                        -- 13000 (due), 20800 (due), 5900 (not due)


-- Tests that must fail

DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12100);       -- start is not the current odometer (13000)
  RAISE NOTICE 'TEST FAILED: wrong start accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (start mismatch rejected): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 13000, 13000);       -- end not greater
  RAISE NOTICE 'TEST FAILED: zero-distance trip accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (end <= start rejected): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
  RAISE NOTICE 'TEST FAILED: unknown vehicle accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (unknown vehicle rejected): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_service_due(99);
  RAISE NOTICE 'TEST FAILED: fn unknown vehicle accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (fn unknown vehicle rejected): %', SQLERRM; END $$;


-- Direct SQL is protected by the same trigger:

DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (2, CURRENT_DATE, 1, 50);
  RAISE NOTICE 'TEST FAILED: direct insert with wrong start accepted';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK (direct insert rejected): %', SQLERRM; END $$;

SELECT COUNT(*) AS trips_rows_expect_6 FROM trips;

SELECT current_odometer AS v1_odometer_expect_13000 FROM vehicles WHERE vehicle_id = 1;   -- unchanged by failed attempts


-- ============================================================
-- Part (e): View
-- ============================================================

CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;                      -- ABC 1001 (5000, boundary) and ABC 1002 (6800)


-- ============================================================
-- Part (f): Index
-- ============================================================

-- Query: one vehicle's trips in a date range.  vehicle_id (equality) first, trip_on (range)
-- second: the B-tree finds the vehicle then reads only the dates in range, in order.

CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN ANALYZE
SELECT * FROM trips WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = OFF;                                               -- tiny table: show the index is usable

EXPLAIN ANALYZE
SELECT * FROM trips WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = ON;


-- ============================================================
-- Part (g): Scheduled Job
-- ============================================================

-- Upserts one alert per due vehicle and deletes alerts of vehicles that are no longer due.

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
SET search_path = Q8    -- lets pg_cron / other sessions find the tables
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service;     -- keeps the original flagged_on date

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                      WHERE v.vehicle_id = sa.vehicle_id
                        AND v.current_odometer - v.last_service_odometer >= 5000);
END;
$$;

CALL pr_refresh_service_alerts();

SELECT * FROM service_alerts ORDER BY vehicle_id;                       -- vehicles 1 and 2

CALL pr_refresh_service_alerts();                                        -- rerun: still one row per vehicle

SELECT COUNT(*) AS alert_rows_expect_2 FROM service_alerts;


-- Service vehicle 2: its alert must disappear on the next refresh

UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;

CALL pr_refresh_service_alerts();

SELECT * FROM service_alerts ORDER BY vehicle_id;                       -- only vehicle 1 remains


-- Every Monday at 06:00 ('0 6 * * 1')

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_service_alerts', '0 6 * * 1', $cmd$CALL Q8.pr_refresh_service_alerts()$cmd$);
    RAISE NOTICE 'pg_cron job refresh_service_alerts scheduled for Mondays 06:00';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron is not available here (%). Use the OS scheduler fallback below.', SQLERRM;
END $$;


-- Fallback: crontab  0 6 * * 1 psql -U postgres -d ict371_exam -c "CALL Q8.pr_refresh_service_alerts();"