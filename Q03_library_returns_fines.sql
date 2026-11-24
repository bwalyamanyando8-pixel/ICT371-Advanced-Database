-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q03_library_returns_fines.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE,                                   -- NULL = still out
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE,
    new_returned_on  DATE,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Clean Code');

-- (b) Function ---------------------------------------------------------------
-- K2 per day after the due date. A return on the due date costs nothing.
-- Fines stop at the return date: LEAST(p_as_of, returned_on) ignores a NULL
-- returned_on, so an open loan is measured up to p_as_of.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    RETURN 2 * GREATEST(0, LEAST(p_as_of, v_returned) - v_due);
END;
$$;

-- (c) Procedure --------------------------------------------------------------
-- Return date and final fine are written in ONE UPDATE statement.
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);    -- loan is still open here

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- no row if unchanged
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a) continued: six loans ----------------------------------------------------
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mwale',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- open and overdue (16 days)
    (2, 'Mutale Banda',  CURRENT_DATE -  5, CURRENT_DATE +  9),  -- open, on time
    (3, 'Natasha Phiri', CURRENT_DATE - 25, CURRENT_DATE - 11),  -- returned late
    (1, 'Joseph Zulu',   CURRENT_DATE - 20, CURRENT_DATE -  6),  -- returned on the due date
    (2, 'Bwalya Tembo',  CURRENT_DATE - 18, CURRENT_DATE -  4),  -- open and overdue (4 days)
    (3, 'Mwila Chola',   CURRENT_DATE - 12, CURRENT_DATE +  2);  -- returned early

CALL pr_return_loan(3, CURRENT_DATE - 8);     -- 3 days late  -> K6
CALL pr_return_loan(4, CURRENT_DATE - 6);     -- on due date  -> K0
CALL pr_return_loan(6, CURRENT_DATE - 1);     -- early        -> K0

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
SELECT fn_loan_fine(3, CURRENT_DATE + 100) AS returned_loan_fine_stops;   -- still K6

DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END;
    BEGIN CALL pr_return_loan(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END;
    BEGIN CALL pr_return_loan(3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already returned): %', SQLERRM; END;
    BEGIN CALL pr_return_loan(2, CURRENT_DATE - 30);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (before borrowed_on): %', SQLERRM; END;
END $$;

-- Setting the same value again must NOT create an audit row
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;   -- 3 rows: loans 3, 4 and 6 only

-- (e) View -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title        AS book_title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;

-- (f) Index ------------------------------------------------------------------
-- Partial index: only unreturned loans are indexed, so it stays small as the
-- library's returned-loan history grows, and it matches the search exactly.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
-- "Overdue" = still unreturned as of p_as_of AND past its due date. A loan
-- returned after p_as_of still counts as unreturned on that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
    FROM loans l
    WHERE l.borrowed_on <= p_as_of
      AND l.due_on < p_as_of
      AND (l.returned_on IS NULL OR l.returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;       -- same date is replaced
END;
$$;

-- Every day at 00:10 for CURRENT_DATE
SELECT cron.schedule('refresh_overdue_summary', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                 -- rerun: still one row
SELECT * FROM overdue_summary ORDER BY snapshot_date;
