-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q10_scholarship_assessment.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('2023001', 'Chanda Mwale'),
    ('2023002', 'Mutale Banda'),
    ('2023003', 'Natasha Phiri');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 2500.00, 75.00, CURRENT_DATE - 14),   -- qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 12),   -- boundary: min age, max income, min mark -> qualifies
    (2, 25, 3000.00, 70.00, CURRENT_DATE - 10),   -- boundary: max age                      -> qualifies
    (2, 26, 1000.00, 90.00, CURRENT_DATE -  8),   -- too old                                -> rejected
    (3, 22, 3001.00, 85.00, CURRENT_DATE -  6),   -- income K1 over the limit               -> rejected
    (3, 19, 2000.00, 69.99, CURRENT_DATE -  4);   -- mark just under 70                     -> rejected

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- (c) Procedure --------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status   VARCHAR(10);
    v_age      INTEGER;
    v_income   NUMERIC;
    v_mark     NUMERIC;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;                                   -- stops two sessions assessing the same row

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
            p_application_id, v_status;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)     -- unchanged status: no audit row
EXECUTE FUNCTION trg_fn_decision_audit();

-- Tests: function
SELECT fn_scholarship_eligible(20, 2500, 75)    AS qualifying,
       fn_scholarship_eligible(18, 3000, 70)    AS lower_boundary,
       fn_scholarship_eligible(25, 3000, 70)    AS upper_boundary,
       fn_scholarship_eligible(26, 1000, 90)    AS too_old,
       fn_scholarship_eligible(22, 3000.01, 85) AS income_over,
       fn_scholarship_eligible(19, 2000, 69.99) AS mark_under;

DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL): %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative income): %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (non-positive age): %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (mark out of range): %', SQLERRM; END;
END $$;

-- Tests: procedure
CALL pr_assess_application(1);                    -- PENDING -> APPROVED

DO $$
BEGIN
    BEGIN CALL pr_assess_application(1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already assessed): %', SQLERRM; END;
    BEGIN CALL pr_assess_application(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown application): %', SQLERRM; END;
END $$;

UPDATE applications SET status = status WHERE application_id = 1;   -- same status: no audit row
SELECT * FROM decision_audit ORDER BY audit_id;                     -- exactly 1 row so far

-- (e) View -------------------------------------------------------------------
-- No income column and no IDs beyond what was asked for.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index ------------------------------------------------------------------
-- Equality on status first, then the submitted_on range: one scan returns the
-- applications of one status inside a date window, in date order.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

-- (g) Scheduled job ----------------------------------------------------------
-- Only PENDING rows are selected, so completed applications are never touched
-- and no duplicate audit entries can appear on a rerun.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id
             FROM applications
             WHERE status = 'PENDING'
             ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

-- Every Monday at 08:00
SELECT cron.schedule('assess_pending_applications', '0 8 * * 1', $$CALL pr_assess_pending()$$);

CALL pr_assess_pending();                          -- assesses applications 2 to 6
CALL pr_assess_pending();                          -- rerun: nothing pending, nothing changes

SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;    -- exactly 6 rows, one per application
SELECT * FROM v_approved_applicants ORDER BY student_number, average_mark;

-- (f) continued: query and plan for the index
ANALYZE applications;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
