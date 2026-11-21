-- 05_indexes_and_performance.sql
-- Indexes for common filtering, joins, and reporting patterns.
CREATE INDEX IF NOT EXISTS idx_admissions_admission_date ON admissions(admission_date);
CREATE INDEX IF NOT EXISTS idx_admissions_discharge_date ON admissions(discharge_date);
CREATE INDEX IF NOT EXISTS idx_admissions_patient_date ON admissions(patient_id,admission_date);
CREATE INDEX IF NOT EXISTS idx_admissions_doctor_date ON admissions(doctor_id,admission_date);
CREATE INDEX IF NOT EXISTS idx_diagnoses_admission ON diagnoses(admission_id);
CREATE INDEX IF NOT EXISTS idx_diagnoses_category ON diagnoses(diagnosis_category);
CREATE INDEX IF NOT EXISTS idx_payments_admission_status ON payments(admission_id,payment_status);
CREATE INDEX IF NOT EXISTS idx_payments_date ON payments(payment_date);

ANALYZE admissions;
ANALYZE patients;
ANALYZE payments;

-- Compare plans before and after indexes:
EXPLAIN (ANALYZE, BUFFERS)
SELECT admission_id,patient_id,admission_date,discharge_date
FROM admissions
WHERE patient_id=42
  AND admission_date >= DATE '2024-01-01'
ORDER BY admission_date;

-- Note: For a tiny synthetic dataset, a sequential scan may be faster.
-- Index benefits become clearer with larger production-scale data.
