-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Student name: ____________________   Student number: ____________________
-- DBMS: PostgreSQL 14+ (scheduling uses the pg_cron extension)
-- Run with:  psql -d your_db -f Q06_monthly_payroll.sql

CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Database ---------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL
        CONSTRAINT ck_pay_month_is_first CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mwale',   8000.00, 1500.00, 1200.00, TRUE),
    ('Mutale Banda',   6500.00, 1000.00,  900.00, TRUE),
    ('Natasha Phiri',  7200.00,  800.00, 1000.00, TRUE),
    ('Joseph Zulu',    5000.00,  500.00,  700.00, TRUE),    -- becomes inactive below
    ('Bwalya Tembo',   4000.00,  300.00,  600.00, TRUE);    -- becomes inactive below

-- (b) Function ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$;

-- (c) Procedure --------------------------------------------------------------
-- Existing employee/month rows are left alone (ON CONFLICT DO NOTHING). If any
-- employee's calculation fails, the exception aborts the whole CALL, so no
-- partial payroll is ever saved.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r       RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees
             WHERE active
             ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(r.employee_id);              -- raises on an invalid result
        v_gross := r.basic_salary + r.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- retained unchanged
    END LOOP;
END;
$$;

-- (d) Trigger ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)   -- only real salary changes
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) continued: two payroll months, then later changes -----------------------
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Two employees leave afterwards; their history must remain visible.
UPDATE employees SET active = FALSE WHERE employee_id IN (4, 5);

-- Tests
SELECT employee_id, fn_net_pay(employee_id) AS net_pay FROM employees ORDER BY employee_id;

DO $$
BEGIN
    BEGIN PERFORM fn_net_pay(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown employee): %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(DATE '2026-11-15');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (not month start): %', SQLERRM; END;
END $$;

-- A salary change is audited; an update that keeps the same salary is not
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;   -- unchanged: no audit row
UPDATE employees SET allowance   = 1500.00 WHERE employee_id = 2;    -- other column: no audit row
SELECT * FROM salary_audit ORDER BY audit_id;                        -- exactly 1 row

-- Reprocessing an existing month leaves old rows untouched (employee 1 keeps 8000+1500)
CALL pr_process_payroll(DATE '2026-10-01');
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;

-- A failing calculation fails the WHOLE call: make employee 3's net negative
DO $$
BEGIN
    UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
    BEGIN
        CALL pr_process_payroll(DATE '2026-11-01');
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Whole call failed as required: %', SQLERRM;
    END;
    RAISE NOTICE 'Rows for 2026-11: %', (SELECT COUNT(*) FROM payroll WHERE pay_month = DATE '2026-11-01');
    UPDATE employees SET deduction = 1000.00 WHERE employee_id = 3;   -- restore
END $$;

-- (e) View -------------------------------------------------------------------
-- Inner join on payroll keeps historical rows of employees who became inactive.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index ------------------------------------------------------------------
-- The existing UNIQUE (employee_id, pay_month) index starts with employee_id,
-- so it cannot efficiently answer "all employees for one month". An index on
-- pay_month alone serves that report and does not duplicate the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------
-- 02:00 on the 1st of every month, passing the first day of the PREVIOUS month
SELECT cron.schedule(
    'monthly_payroll',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll';

SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll')
ORDER BY start_time DESC;
