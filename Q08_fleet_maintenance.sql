-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q08_fleet_maintenance.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles in different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAK 1001', 24000, 18500),   -- already 5,500 km since service: due
    ('BAL 2002', 15000, 10500),   -- 4,500 km: close, becomes due after its trips
    ('BAM 3003',  8000,  7000);   -- 1,000 km: recently serviced

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END;
$$;

-- (d) Trigger (installed before trips are added) -----------------------------
-- The vehicle row is locked so two trips for one vehicle cannot both start at
-- the same odometer value. current_odometer is updated here, exactly once.
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start % end % (end must be greater than start)',
            NEW.start_odometer, NEW.end_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)',
            v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (c) Procedure --------------------------------------------------------------
-- Deliberately does NOT touch vehicles: the trigger owns the odometer update.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE,
                                           p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
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

-- (a) continued: six trips through the procedure (each starts where the last ended)
CALL pr_record_trip(1, CURRENT_DATE - 6, 24000, 24400);
CALL pr_record_trip(1, CURRENT_DATE - 3, 24400, 24950);
CALL pr_record_trip(2, CURRENT_DATE - 5, 15000, 15300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 15300, 15700);   -- 15700-10500 = 5,200 km: now due
CALL pr_record_trip(3, CURRENT_DATE - 4,  8000,  8200);
CALL pr_record_trip(3, CURRENT_DATE - 1,  8200,  8450);

-- Tests
SELECT vehicle_id, registration, current_odometer,
       current_odometer - last_service_odometer AS km_since_service,
       fn_service_due(vehicle_id) AS service_due
FROM vehicles ORDER BY vehicle_id;

DO $$
BEGIN
    BEGIN PERFORM fn_service_due(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown vehicle): %', SQLERRM; END;
    BEGIN CALL pr_record_trip(999, CURRENT_DATE, 0, 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (procedure, unknown vehicle): %', SQLERRM; END;
    BEGIN CALL pr_record_trip(3, CURRENT_DATE, 8450, 8450);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (end not greater than start): %', SQLERRM; END;
    BEGIN CALL pr_record_trip(3, CURRENT_DATE, 8000, 8600);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (start <> current odometer): %', SQLERRM; END;
    -- direct SQL is checked by the trigger as well
    BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (3, CURRENT_DATE, 8450, 8400);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, bad mileage): %', SQLERRM; END;
END $$;

SELECT * FROM trips ORDER BY trip_id;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY vehicle_id;   -- 24950, 15700, 8450

-- (e) View -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;

-- (f) Index ------------------------------------------------------------------
-- Equality on vehicle_id then a range on trip_on: one index range scan returns
-- one vehicle's trips for the period already in date order.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
-- flagged_on keeps the date a vehicle was FIRST flagged; km_since_service is refreshed.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa              -- vehicle serviced: no longer due
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

-- Every Monday at 06:00
SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;                 -- vehicles 1 and 2

UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;                 -- only vehicle 2 remains
