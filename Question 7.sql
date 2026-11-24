-- Q7(a) Tables & Seed Data
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10, 2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_amount_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_due >= 0)
);

-- Q7(d) Trigger: BEFORE INSERT OR UPDATE reject current_reading < previous_reading
CREATE OR REPLACE FUNCTION fn_trg_readings_check_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%.2f) cannot be less than previous_reading (%.2f)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check_order
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_trg_readings_check_order();

-- Q7(b) Function: fn_water_charge (first 10 units @ K5, above 10 @ K8)
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(10, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units must be non-negative, got %', p_units;
    END IF;

    IF p_units = 0 THEN
        v_charge := 0.00;
    ELSIF p_units <= 10 THEN
        v_charge := p_units * 5.00;
    ELSE
        v_charge := (10 * 5.00) + ((p_units - 10) * 8.00);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

-- Q7(c) Procedure: pr_generate_bill
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_units  NUMERIC(10, 2);
    v_charge NUMERIC(10, 2);
BEGIN
    SELECT (current_reading - previous_reading) INTO v_units
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Bill already exists for reading_id %', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- Seed 3 customers & 6 readings (0 units, 10 units, >10 units across 2 months)
INSERT INTO customers (full_name) VALUES ('Chomba Mulenga'), ('Bupe Nkonde'), ('Tisa Mwamba');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00), -- 0 units
    (2, DATE '2026-09-01', 200.00, 210.00), -- 10 units
    (3, DATE '2026-09-01', 50.00,  65.00),  -- 15 units
    (1, DATE '2026-10-01', 100.00, 112.00), -- 12 units
    (2, DATE '2026-10-01', 210.00, 210.00), -- 0 units
    (3, DATE '2026-10-01', 65.00,  75.00);  -- 10 units

CALL pr_generate_bill(1, CURRENT_DATE - 10);
CALL pr_generate_bill(2, CURRENT_DATE - 8);
CALL pr_generate_bill(3, CURRENT_DATE - 5);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

UPDATE bills SET amount_paid = charge WHERE bill_id = 1; -- Settled overdue bill

-- Q7(e) View: v_overdue_bills
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- Q7(f) Partial Index on due_on for unpaid bills & EXPLAIN
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN (ANALYZE, BUFFERS)
SELECT bill_id, charge, amount_paid, due_on
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
-- Expected plan node: Index Scan using idx_bills_unpaid_due_on on bills

-- Q7(g) Procedure & Scheduled Job (00:30 daily)
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
    v_total NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00) INTO v_total
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (v_today, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule(
    'refresh_water_receivables',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);