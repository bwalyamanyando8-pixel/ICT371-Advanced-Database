-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q04_clinic_appointments.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL
        CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES ('Chanda Mwale'), ('Mutale Banda'), ('Natasha Phiri');
INSERT INTO doctors  (full_name) VALUES ('Dr. Zulu'), ('Dr. Tembo'), ('Dr. Chola');

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    RETURN (SELECT COUNT(*)::INTEGER             -- COUNT gives 0 when no bookings exist
            FROM appointments
            WHERE doctor_id = p_doctor_id
              AND appointment_day = p_day
              AND status <> 'CANCELLED');
END;
$$;

-- (d) Trigger (created before the procedure so every insert is protected) -----
-- Locking the doctor row serialises concurrent bookings for the same doctor,
-- so two sessions cannot both pass the clash check for the same slot.
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)  -- skip itself on UPDATE
        ) THEN
            RAISE EXCEPTION 'Doctor % already has a booking on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- (c) Procedure --------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;

    -- The trigger rejects a clash with another non-cancelled appointment.
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (a) continued: six appointments (the trigger is already active) --------------
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
    (1, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED'),   -- reuses the cancelled slot: allowed
    (2, 3, CURRENT_DATE,     '11:00', 'BOOKED'),
    (3, 1, CURRENT_DATE,     '09:00', 'BOOKED');

CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '10:00');   -- one more through the procedure

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE - 1) AS dr1_yesterday,    -- 2
       fn_daily_load(2, CURRENT_DATE - 1) AS dr2_yesterday,    -- 1 (cancelled one ignored)
       fn_daily_load(3, CURRENT_DATE + 30) AS dr3_empty_day;   -- 0

DO $$
BEGIN
    BEGIN PERFORM fn_daily_load(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown doctor): %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(999, 1, CURRENT_DATE + 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown patient): %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '11:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (past date): %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (bad slot): %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(3, 2, CURRENT_DATE + 1, '10:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (clash on INSERT): %', SQLERRM; END;
    -- clash on UPDATE: move appointment 6 onto Dr. Chola's (doctor 3) taken 11:00 slot today
    BEGIN UPDATE appointments SET doctor_id = 3, slot_time = '11:00' WHERE appointment_id = 6;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (clash on UPDATE): %', SQLERRM; END;
END $$;

-- Updating a row without changing its slot is NOT a clash with itself
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 5;
UPDATE appointments SET status = 'BOOKED'   WHERE appointment_id = 5;

SELECT * FROM appointments ORDER BY appointment_id;

-- (e) View -------------------------------------------------------------------
-- Only the three needed columns are exposed: no IDs, no other patient data.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index ------------------------------------------------------------------
-- Non-unique composite index: day first (the date is always supplied), then
-- doctor_id, so "this doctor's appointments on this day" is a direct B-tree lookup.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE - 1
  AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;   -- replaced on rerun
END;
$$;

-- Every day at 01:00 for the previous day
SELECT cron.schedule('refresh_clinic_summary', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);         -- rerun: same single row
SELECT * FROM clinic_summary ORDER BY summary_date;
