-- 04_views.sql
CREATE OR REPLACE VIEW vw_admission_details AS
SELECT a.admission_id,a.patient_id,p.patient_name,p.gender,p.city,
       a.doctor_id,doc.doctor_name,dept.department_name,
       a.bed_id,b.ward_name,b.bed_type,
       a.admission_date,a.discharge_date,
       CASE WHEN a.discharge_date IS NOT NULL THEN a.discharge_date-a.admission_date END AS length_of_stay_days,
       a.admission_type,a.status,a.billed_amount
FROM admissions a
JOIN patients p USING(patient_id)
JOIN doctors doc USING(doctor_id)
JOIN departments dept USING(department_id)
LEFT JOIN beds b USING(bed_id);

CREATE OR REPLACE VIEW vw_patient_financial_summary AS
SELECT a.admission_id,a.patient_id,a.billed_amount,
       COALESCE(SUM(p.amount) FILTER (WHERE p.payment_status='Completed'),0)::numeric(12,2) AS amount_collected,
       (a.billed_amount-COALESCE(SUM(p.amount) FILTER (WHERE p.payment_status='Completed'),0))::numeric(12,2) AS outstanding_balance
FROM admissions a LEFT JOIN payments p USING(admission_id)
GROUP BY a.admission_id,a.patient_id,a.billed_amount;

CREATE OR REPLACE VIEW vw_monthly_hospital_kpis AS
SELECT DATE_TRUNC('month',admission_date)::date AS admission_month,
       COUNT(*) AS admissions,
       COUNT(DISTINCT patient_id) AS unique_patients,
       ROUND(AVG(discharge_date-admission_date) FILTER (WHERE discharge_date IS NOT NULL),2) AS avg_length_of_stay,
       ROUND(SUM(billed_amount),2) AS billed_revenue
FROM admissions GROUP BY 1;
