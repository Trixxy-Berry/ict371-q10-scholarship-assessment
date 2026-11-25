-- ============================================================================
-- ICT371 Advanced Database
-- Question 10: Scholarship Application Assessment (PostgreSQL / PL/pgSQL)
-- ============================================================================

-- (a) Database and seed data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(12) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(12) NOT NULL,
    new_status     VARCHAR(12) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('SCH-001', 'Mutale Chambwa'),
    ('SCH-002', 'Kondwani Phiri'),
    ('SCH-003', 'Zainab Banda');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 82.50, CURRENT_DATE - 6, 'PENDING'),
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 5, 'PENDING'),
    (2, 25, 3000.00, 70.00, CURRENT_DATE - 4, 'PENDING'),
    (2, 26, 2500.00, 85.00, CURRENT_DATE - 3, 'PENDING'),
    (3, 21, 3500.00, 90.00, CURRENT_DATE - 2, 'PENDING'),
    (3, 19, 1500.00, 69.50, CURRENT_DATE - 1, 'PENDING');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INT,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income, and mark must not be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income must be non-negative, got %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app      RECORD;
    v_eligible BOOLEAN;
    v_new_stat VARCHAR(12);
BEGIN
    SELECT application_id, age_at_application, monthly_income, average_mark, status
    INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
            p_application_id, v_app.status;
    END IF;

    v_eligible := fn_scholarship_eligible(
        v_app.age_at_application,
        v_app.monthly_income,
        v_app.average_mark
    );

    v_new_stat := CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications
    SET status = v_new_stat
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_log_decision_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_log_decision_change();

-- (e) View
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index, Query, and EXPLAIN
-- Justification: Composite index on (status, submitted_on) enables fast filtering by status and range scan by submission date.
CREATE INDEX idx_applications_status_submitted_on
ON applications (status, submitted_on);

EXPLAIN
SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_row RECORD;
BEGIN
    FOR v_row IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(v_row.application_id);
    END LOOP;
END;
$$;

-- Every Monday at 08:00 (pg_cron)
SELECT cron.schedule(
    'assess_pending_scholarships',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);
