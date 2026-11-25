
-- ============================================================
-- ICT371 - Q5: Hostel Room Allocation
-- Database: ict371_exam
-- ============================================================
-- Each question lives in its own schema (Q5), so questions
-- never clash and the script can be re-run independently.

DROP SCHEMA IF EXISTS Q5 CASCADE;
CREATE SCHEMA Q5;
SET search_path TO Q5;


-- ============================================================
-- PART (a): TABLES AND CONSTRAINTS
-- ============================================================

-- Students table
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name TEXT NOT NULL
);

-- Rooms table
CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number TEXT NOT NULL UNIQUE,
    capacity INT NOT NULL CHECK (capacity > 0)
);

-- Allocations table
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE NULL,
    status TEXT NOT NULL,

    CONSTRAINT ck_alloc_status
        CHECK (status IN ('ACTIVE', 'ENDED')),

    -- ACTIVE allocations have no release date.
    -- ENDED allocations must have a valid release date.
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED'
         AND released_on IS NOT NULL
         AND released_on >= allocated_on)
    )
);

-- Occupancy snapshot table
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL CHECK (occupied_beds >= 0),
    free_beds INT NOT NULL,

    PRIMARY KEY (snapshot_date, room_id)
);

-- Insert sample students
INSERT INTO students (student_number, full_name)
VALUES
    ('S001', 'Chipo Phiri'),
    ('S002', 'Mwamba Banda'),
    ('S003', 'Leya Tembo'),
    ('S004', 'Tapiwa Soko'),
    ('S005', 'Bwalya Lungu'),
    ('S006', 'Misozi Zulu');

-- Insert sample rooms
INSERT INTO rooms (room_number, capacity)
VALUES
    ('R101', 2),
    ('R102', 3),
    ('R103', 2);


-- ============================================================
-- PART (b): FUNCTION - CALCULATE FREE BEDS
-- ============================================================

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
SET search_path = q5
AS $$
DECLARE
    v_cap INT;
    v_active INT;
BEGIN
    SELECT capacity
    INTO v_cap
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*)
    INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_cap - v_active;
END;
$$;


-- ============================================================
-- PART (d): TRIGGER - ROOM ALLOCATION VALIDATION
-- ============================================================
-- Prevents students from having multiple active allocations.
-- Prevents rooms from exceeding their capacity.
-- Locks the room row to protect against simultaneous allocations.

CREATE OR REPLACE FUNCTION fn_trg_allocation_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = q5
AS $$
DECLARE
    v_cap INT;
    v_active INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN

        SELECT capacity
        INTO v_cap
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- Prevent multiple active allocations for one student.
        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND a.allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION
                'Student % already has an ACTIVE allocation',
                NEW.student_id;
        END IF;

        -- Count active allocations in the selected room.
        SELECT COUNT(*)
        INTO v_active
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;

        -- Reject allocation when the room is full.
        IF v_active >= v_cap THEN
            RAISE EXCEPTION
                'Room % is full (capacity %)',
                NEW.room_id, v_cap;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

-- Create allocation trigger
CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_trg_allocation_rules();


-- ============================================================
-- PART (c): PROCEDURE - ALLOCATE HOSTEL ROOM
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INT,
    p_room_id INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql
SET search_path = q5
AS $$
BEGIN
    -- Validate student existence.
    IF p_student_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM students
        WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- Lock the selected room.
    PERFORM 1
    FROM rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    -- Validate allocation date.
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'allocated_on date is required';
    END IF;

    -- Prevent multiple active allocations.
    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Student % already has an ACTIVE allocation',
            p_student_id;
    END IF;

    -- Check room availability.
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION
            'Room % has no free beds',
            p_room_id;
    END IF;

    -- Create the allocation.
    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );
END;
$$;


-- ============================================================
-- PART (d): SAMPLE DATA AND ALLOCATION TESTS
-- ============================================================

-- Seed allocations:
-- R101: Full (2/2)
-- R102: Partly occupied
-- R103: Empty, with ENDED allocation history only.

INSERT INTO allocations (
    student_id, room_id, allocated_on, released_on, status
)
VALUES
    (1, 1, CURRENT_DATE - 60, NULL, 'ACTIVE'),
    (2, 1, CURRENT_DATE - 50, NULL, 'ACTIVE'),
    (3, 2, CURRENT_DATE - 40, NULL, 'ACTIVE'),
    (4, 2, CURRENT_DATE - 90, CURRENT_DATE - 30, 'ENDED'),
    (5, 3, CURRENT_DATE - 80, CURRENT_DATE - 20, 'ENDED');

-- Allocate student 6 to room R102.
CALL pr_allocate_room(6, 2, CURRENT_DATE);

-- Check available beds in all rooms.
SELECT
    room_id,
    fn_free_beds(room_id) AS free_beds
FROM rooms
ORDER BY room_id;

-- Test 1: Reject allocation into a full room.
DO $$
BEGIN
    CALL pr_allocate_room(4, 1, CURRENT_DATE);
    RAISE NOTICE 'TEST FAILED: full room accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (full room rejected): %', SQLERRM;
END $$;

-- Test 2: Reject a second active allocation for one student.
DO $$
BEGIN
    CALL pr_allocate_room(1, 3, CURRENT_DATE);
    RAISE NOTICE 'TEST FAILED: second ACTIVE allocation accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (second ACTIVE rejected): %', SQLERRM;
END $$;

-- Test 3: Reject an unknown student.
DO $$
BEGIN
    CALL pr_allocate_room(99, 3, CURRENT_DATE);
    RAISE NOTICE 'TEST FAILED: unknown student accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (unknown student rejected): %', SQLERRM;
END $$;

-- Test 4: Reject an unknown room.
DO $$
BEGIN
    CALL pr_allocate_room(4, 99, CURRENT_DATE);
    RAISE NOTICE 'TEST FAILED: unknown room accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (unknown room rejected): %', SQLERRM;
END $$;

-- Test 5: Reject an unknown room in the function.
DO $$
BEGIN
    PERFORM fn_free_beds(99);
    RAISE NOTICE 'TEST FAILED: fn accepted unknown room';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (fn unknown room rejected): %', SQLERRM;
END $$;

-- Test 6: Direct SQL insertion is also protected by the trigger.
DO $$
BEGIN
    INSERT INTO allocations (
        student_id, room_id, allocated_on, status
    )
    VALUES (4, 1, CURRENT_DATE, 'ACTIVE');

    RAISE NOTICE 'TEST FAILED: direct insert into full room accepted';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK (direct insert rejected): %', SQLERRM;
END $$;

-- Test 7: Updating an ACTIVE row without changing its room is allowed.
UPDATE allocations
SET allocated_on = allocated_on
WHERE allocation_id = 1;


-- ============================================================
-- PART (e): VIEW - ROOM OCCUPANCY
-- ============================================================
-- Displays room capacity, occupied beds and available beds.
-- LEFT JOIN ensures that empty rooms are also displayed.

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON a.room_id = r.room_id
   AND a.status = 'ACTIVE'
GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;

-- Test the room occupancy view.
SELECT *
FROM v_room_occupancy
ORDER BY room_number;


-- ============================================================
-- PART (f): INDEX - ACTIVE ROOM ALLOCATIONS
-- ============================================================
-- A partial index stores only ACTIVE allocations.
-- ENDED allocation records are excluded, keeping the index smaller.

CREATE INDEX idx_alloc_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';

-- Test query performance.
EXPLAIN ANALYZE
SELECT *
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

-- Show that the index is usable on the small sample table.
SET enable_seqscan = OFF;

EXPLAIN ANALYZE
SELECT *
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

SET enable_seqscan = ON;


-- ============================================================
-- PART (g): SCHEDULED JOB - DAILY OCCUPANCY SNAPSHOT
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
SET search_path = q5
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id),
        r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
        ON a.room_id = r.room_id
       AND a.status = 'ACTIVE'
    GROUP BY
        r.room_id,
        r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

-- Generate the daily occupancy snapshot.
CALL pr_refresh_occupancy();

-- Display occupancy snapshot results.
SELECT *
FROM occupancy_snapshot
ORDER BY room_id;

-- Run again to prove that records are replaced, not duplicated.
CALL pr_refresh_occupancy();

SELECT COUNT(*) AS snapshot_rows
FROM occupancy_snapshot;


-- ============================================================
-- PART (g): SCHEDULED JOB - AUTOMATIC DAILY EXECUTION
-- ============================================================
-- Schedule the occupancy refresh procedure for 23:55 daily.

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    PERFORM cron.schedule(
        'refresh_occupancy',
        '55 23 * * *',
        $cmd$CALL q5.pr_refresh_occupancy()$cmd$
    );

    RAISE NOTICE
        'pg_cron job refresh_occupancy scheduled for 23:55 daily';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE
        'pg_cron is not available here (%). Use the OS scheduler fallback below.',
        SQLERRM;
END $$;

-- Fallback without pg_cron:
-- Linux crontab:
-- 55 23 * * * psql -U postgres -d ict371_exam -c "CALL q5.pr_refresh_occupancy();"
