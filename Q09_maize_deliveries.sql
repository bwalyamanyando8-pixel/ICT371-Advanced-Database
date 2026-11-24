-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q09_maize_deliveries.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,          -- supplied by the trigger
    total_value  NUMERIC(12,2) NOT NULL,          -- supplied by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mwale'),
    ('F002', 'Mutale Banda'),
    ('F003', 'Natasha Phiri');    -- ends up with no unpaid deliveries

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    ELSIF p_grade = 'A' THEN RETURN 5.00;
    ELSIF p_grade = 'B' THEN RETURN 4.00;
    ELSIF p_grade = 'C' THEN RETURN 3.00;
    ELSE
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;
END;
$$;

-- (d) Trigger ----------------------------------------------------------------
-- Pricing lives here, so the procedure AND direct SQL always follow one rule.
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_delivery_pricing();

-- (c) Procedure --------------------------------------------------------------
-- Inserts only the basic fields; unit_rate and total_value come from the trigger.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade VARCHAR,
                                                p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);          -- rejects NULL / unsupported grade early

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (a) continued: load six deliveries AFTER the trigger exists -----------------
-- Direct INSERTs omit unit_rate and total_value; the trigger fills them in.
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 120.50, CURRENT_DATE - 3, TRUE),
    (1, 'B',  80.00, CURRENT_DATE - 2, FALSE),
    (2, 'C', 200.00, CURRENT_DATE - 1, FALSE),
    (3, 'A',  50.00, CURRENT_DATE - 1, TRUE);
CALL pr_receive_delivery(2, 'A', 75.25, CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'C', 40.00, CURRENT_DATE);

-- Tests
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;

DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL grade): %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('Z');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unsupported grade): %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(999, 'A', 10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown farmer): %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (zero weight): %', SQLERRM; END;
    BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on) VALUES (1, 'A', -5, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, negative weight): %', SQLERRM; END;
END $$;

-- Direct SQL cannot bypass pricing: a hand-typed rate/value is overwritten
UPDATE deliveries SET unit_rate = 99, total_value = 99999 WHERE delivery_id = 1;

SELECT * FROM deliveries ORDER BY delivery_id;

-- (e) View -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE   -- LEFT JOIN keeps farmers with none
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;    -- F003 shows 0

-- (f) Index ------------------------------------------------------------------
-- Equality on farmer_id then a range on delivered_on: one scan finds a farmer's
-- deliveries between two dates, already ordered by date.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;     -- replaced, never added again
END;
$$;

-- Every day at 01:30 for the previous day
SELECT cron.schedule('refresh_daily_purchases', '30 1 * * *',
                     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);         -- rerun: same totals
SELECT * FROM daily_purchases ORDER BY purchase_date;
