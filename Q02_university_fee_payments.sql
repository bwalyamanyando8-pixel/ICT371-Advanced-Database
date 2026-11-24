-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q02_university_fee_payments.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Three students with different fee balances. Payments are loaded further down
-- through pr_receive_payment, so the audit trigger records every one of them.
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('2023001', 'Chanda Mwale',   5000.00),
    ('2023002', 'Mutale Banda',   3000.00),
    ('2023003', 'Natasha Phiri',  4500.00);   -- will have no payments initially

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;     -- 0 when no payments exist

    RETURN v_fee - v_paid;
END;
$$;

-- (c) Procedure --------------------------------------------------------------
-- The student row is locked so two simultaneous payments cannot together
-- exceed the balance. The audit row is NOT written here: the trigger does it.
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);        -- fee_due is never touched
END;
$$;

-- (d) Trigger ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- (a) continued: seven payments (more than the required six) through the procedure ------------------------
CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 3000.00, CURRENT_DATE - 2);   -- Mutale is fully settled
CALL pr_receive_payment(1,  250.00, CURRENT_DATE);
-- Student 3 intentionally has no payments yet.
CALL pr_receive_payment(1,  100.00, CURRENT_DATE);
CALL pr_receive_payment(1,   50.00, CURRENT_DATE);

-- Tests
SELECT fn_fee_balance(1) AS balance_student_1,   -- 5000 - 4400 = 600
       fn_fee_balance(2) AS balance_student_2,   -- 0
       fn_fee_balance(3) AS balance_student_3;   -- full fee 4500

DO $$
BEGIN
    BEGIN PERFORM fn_fee_balance(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(3, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL): %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (zero): %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(3, -10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative): %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(3, 9999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (above balance): %', SQLERRM; END;
END $$;

SELECT * FROM students ORDER BY student_id;          -- fee_due unchanged
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;       -- one audit row per payment

-- (e) View -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;   -- settled students excluded

SELECT * FROM v_fee_balances ORDER BY student_number;

-- (f) Index ------------------------------------------------------------------
-- Equality column (student_id) first, range column (paid_on) second, so one
-- index scan returns exactly one student's payments inside the date range.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;     -- replaces, never accumulates
END;
$$;

-- Every day at 01:00 for the previous day
SELECT cron.schedule('refresh_daily_collections', '0 1 * * *',
                     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);         -- rerun: same result
SELECT * FROM daily_collections ORDER BY collection_date;
