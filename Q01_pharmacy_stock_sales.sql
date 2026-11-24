-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q01_pharmacy_stock_sales.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Medicines are loaded now; the sales are loaded further down through
-- pr_record_sale (after the procedure and trigger exist).
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('ORS Sachet',        3.00,  12),
    ('Ibuprofen 400mg',   4.50,   9);

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure --------------------------------------------------------------
-- Any exception aborts the CALL, so an invalid sale leaves medicines and
-- sales exactly as they were. The row is locked so two sales cannot oversell.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
            p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity      -- deducted exactly once
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only real stock changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) continued: load six valid sales through the procedure -------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3,  4, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(4,  2, CURRENT_DATE);
CALL pr_record_sale(2,  3, CURRENT_DATE);

-- Tests for (b) and (c): invalid calls must be rejected and change nothing
SELECT fn_sale_value(1, 4) AS sale_value_4_paracetamol;      -- 10.00

DO $$
BEGIN
    BEGIN PERFORM fn_sale_value(999, 1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown medicine): %', SQLERRM; END;
    BEGIN PERFORM fn_sale_value(1, 0);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (bad quantity): %', SQLERRM; END;
    BEGIN CALL pr_record_sale(3, 500, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (oversell): %', SQLERRM; END;
END $$;

SELECT * FROM medicines ORDER BY medicine_id;     -- stock unchanged by the failed calls
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;      -- one row per deduction

-- (e) View -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(3, 3, CURRENT_DATE);          -- ORS drops from 8 to 5
SELECT * FROM v_low_stock ORDER BY medicine_name;

-- (f) Index ------------------------------------------------------------------
-- Equality on medicine_id first, then the range on sold_on: one B-tree scan
-- finds a single medicine's sales in a date range without reading the table.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;   -- the demo table is tiny, so force the planner to show the index
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
-- Delete-and-replace via UPSERT: rerunning overwrites the day, never adds to it.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Every day at 00:15 for the previous day
SELECT cron.schedule('refresh_daily_sales', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);

-- Demonstrate idempotence: run twice, totals stay the same
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;
