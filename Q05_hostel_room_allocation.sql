-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q05_hostel_room_allocation.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT ck_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('2023001','Chanda Mwale'), ('2023002','Mutale Banda'),  ('2023003','Natasha Phiri'),
    ('2023004','Joseph Zulu'),  ('2023005','Bwalya Tembo'),  ('2023006','Mwila Chola');

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),    -- will be full
    ('A102', 3),    -- will be partly occupied
    ('A103', 2);    -- will stay empty

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    RETURN v_capacity - (SELECT COUNT(*)::INTEGER
                         FROM allocations
                         WHERE room_id = p_room_id AND status = 'ACTIVE');  -- ENDED rows ignored
END;
$$;

-- (d) Trigger (installed before data so direct SQL is always protected) --------
-- The room row is locked first: concurrent allocations to one room are
-- serialised, so capacity cannot be exceeded by a race.
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- one ACTIVE allocation per student (exclude the row being updated)
        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- capacity (exclude the row being updated)
        SELECT COUNT(*) INTO v_active
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_active >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- (c) Procedure --------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- lock before checking beds
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (a) continued: seed allocations --------------------------------------------
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);     -- A101 becomes full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);     -- A102 partly occupied (1/3)
-- History: student 4 used A101 earlier and has left (ENDED does not occupy a bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 1, CURRENT_DATE - 200, CURRENT_DATE - 120, 'ENDED');
-- Student 4 can now be allocated again, and A103 stays empty.
CALL pr_allocate_room(4, 2, CURRENT_DATE - 5);      -- A102 now 2/3

-- Tests
SELECT fn_free_beds(1) AS a101_free,   -- 0
       fn_free_beds(2) AS a102_free,   -- 1
       fn_free_beds(3) AS a103_free;   -- 2

DO $$
BEGIN
    BEGIN PERFORM fn_free_beds(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown room): %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(999, 3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (room full): %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (student already active): %', SQLERRM; END;
    -- direct SQL is protected by the trigger too
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, full): %', SQLERRM; END;
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (1, 3, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, 2nd active): %', SQLERRM; END;
END $$;

-- Updating an existing ACTIVE row must not count itself against capacity
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

SELECT * FROM allocations ORDER BY allocation_id;

-- (e) View -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)::INTEGER              AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id))::INTEGER AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'   -- LEFT JOIN keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index ------------------------------------------------------------------
-- Partial index on ACTIVE rows only: the capacity checks, fn_free_beds and the
-- occupancy view all count ACTIVE rows per room, and history (ENDED) rows,
-- which grow forever, are kept out of the index.
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;      -- one row per date and room
END;
$$;

-- Every day at 23:55
SELECT cron.schedule('refresh_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                         -- rerun: values replaced, no duplicates
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
