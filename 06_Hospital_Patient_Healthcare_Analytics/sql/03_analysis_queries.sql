-- 03_analysis_queries.sql
-- Run each query independently. These are operational analytics, not clinical advice.

-- Q01. Overall hospital KPI snapshot
SELECT COUNT(DISTINCT patient_id) AS unique_patients,
       COUNT(*) AS total_admissions,
       COUNT(*) FILTER (WHERE status='Admitted') AS currently_admitted,
       ROUND(AVG(discharge_date-admission_date) FILTER (WHERE discharge_date IS NOT NULL),2) AS avg_length_of_stay_days,
       ROUND(SUM(billed_amount),2) AS total_billed
FROM admissions;

-- Q02. Monthly admission trend
SELECT DATE_TRUNC('month', admission_date)::date AS admission_month, COUNT(*) AS admissions
FROM admissions GROUP BY 1 ORDER BY 1;

-- Q03. Monthly discharges
SELECT DATE_TRUNC('month', discharge_date)::date AS discharge_month, COUNT(*) AS discharges
FROM admissions WHERE discharge_date IS NOT NULL GROUP BY 1 ORDER BY 1;

-- Q04. Admission mix by type
SELECT admission_type, COUNT(*) AS admissions,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER(),2) AS pct_of_admissions
FROM admissions GROUP BY admission_type ORDER BY admissions DESC;

-- Q05. Patient age bands (age at admission)
SELECT CASE WHEN age_years < 18 THEN 'Under 18'
            WHEN age_years < 35 THEN '18-34'
            WHEN age_years < 50 THEN '35-49'
            WHEN age_years < 65 THEN '50-64' ELSE '65+' END AS age_band,
       COUNT(*) AS admission_count
FROM (
  SELECT a.admission_id,
         EXTRACT(YEAR FROM AGE(a.admission_date,p.date_of_birth))::int AS age_years
  FROM admissions a JOIN patients p USING(patient_id)
) s
GROUP BY 1
ORDER BY MIN(age_years);

-- Q06. Top 10 cities by unique patients
SELECT city, COUNT(DISTINCT patient_id) AS patients
FROM patients GROUP BY city ORDER BY patients DESC LIMIT 10;

-- Q07. Top diagnoses
SELECT diagnosis_name, diagnosis_category, COUNT(*) AS diagnosis_count
FROM diagnoses GROUP BY 1,2 ORDER BY diagnosis_count DESC LIMIT 10;

-- Q08. Department admission volume
SELECT d.department_name, COUNT(*) AS admissions
FROM admissions a JOIN doctors doc USING(doctor_id)
JOIN departments d USING(department_id)
GROUP BY d.department_name ORDER BY admissions DESC;

-- Q09. Doctor workload and average stay
SELECT doc.doctor_id, doc.doctor_name, d.department_name,
       COUNT(a.admission_id) AS admissions,
       ROUND(AVG(a.discharge_date-a.admission_date) FILTER (WHERE a.discharge_date IS NOT NULL),2) AS avg_stay_days
FROM doctors doc JOIN departments d USING(department_id)
LEFT JOIN admissions a USING(doctor_id)
GROUP BY doc.doctor_id, doc.doctor_name, d.department_name
ORDER BY admissions DESC;

-- Q10. Revenue by department
SELECT d.department_name, ROUND(SUM(a.billed_amount),2) AS billed_revenue
FROM admissions a JOIN doctors doc USING(doctor_id)
JOIN departments d USING(department_id)
GROUP BY d.department_name ORDER BY billed_revenue DESC;

-- Q11. Average length of stay by admission type
SELECT admission_type,
       ROUND(AVG(discharge_date-admission_date),2) AS avg_stay_days
FROM admissions WHERE discharge_date IS NOT NULL
GROUP BY admission_type ORDER BY avg_stay_days DESC;

-- Q12. Long-stay admissions (more than 10 days)
SELECT admission_id, patient_id, admission_date, discharge_date,
       discharge_date-admission_date AS stay_days
FROM admissions WHERE discharge_date-admission_date > 10
ORDER BY stay_days DESC;

-- Q13. 30-day readmission candidates (next admission within 30 days)
WITH ordered AS (
  SELECT patient_id, admission_id, admission_date, discharge_date,
         LEAD(admission_date) OVER(PARTITION BY patient_id ORDER BY admission_date, admission_id) AS next_admission
  FROM admissions WHERE discharge_date IS NOT NULL
)
SELECT *, next_admission-discharge_date AS days_to_readmission
FROM ordered
WHERE next_admission > discharge_date
  AND next_admission <= discharge_date + 30
ORDER BY days_to_readmission;

-- Q14. Readmission rate by discharge month (simple unadjusted operational indicator)
WITH patient_stays AS (
  SELECT patient_id, admission_id, discharge_date,
         LEAD(admission_date) OVER(PARTITION BY patient_id ORDER BY admission_date, admission_id) AS next_admission
  FROM admissions WHERE discharge_date IS NOT NULL
)
SELECT DATE_TRUNC('month',discharge_date)::date AS discharge_month,
       COUNT(*) AS eligible_discharges,
       COUNT(*) FILTER (WHERE next_admission BETWEEN discharge_date+1 AND discharge_date+30) AS readmissions_30d,
       ROUND(100.0*COUNT(*) FILTER (WHERE next_admission BETWEEN discharge_date+1 AND discharge_date+30)/NULLIF(COUNT(*),0),2) AS readmission_pct
FROM patient_stays GROUP BY 1 ORDER BY 1;

-- Q15. Payment collection by method
SELECT payment_method, payment_status, COUNT(*) AS transactions,
       ROUND(SUM(amount),2) AS payment_amount
FROM payments GROUP BY 1,2 ORDER BY payment_amount DESC;

-- Q16. Outstanding balance by admission
SELECT a.admission_id, a.patient_id, a.billed_amount,
       COALESCE(SUM(p.amount) FILTER (WHERE p.payment_status='Completed'),0) AS collected,
       a.billed_amount-COALESCE(SUM(p.amount) FILTER (WHERE p.payment_status='Completed'),0) AS outstanding
FROM admissions a LEFT JOIN payments p USING(admission_id)
GROUP BY a.admission_id ORDER BY outstanding DESC;

-- Q17. Overall collection rate
WITH payment_totals AS (
  SELECT admission_id,
         SUM(amount) FILTER (WHERE payment_status='Completed') AS collected
  FROM payments GROUP BY admission_id
)
SELECT ROUND(100.0*SUM(COALESCE(pt.collected,0))/NULLIF(SUM(a.billed_amount),0),2) AS collection_pct
FROM admissions a LEFT JOIN payment_totals pt USING(admission_id);

-- Q18. Patients with more than 3 admissions
SELECT p.patient_id,p.patient_name,COUNT(a.admission_id) AS admission_count
FROM patients p JOIN admissions a USING(patient_id)
GROUP BY p.patient_id,p.patient_name
HAVING COUNT(a.admission_id)>3 ORDER BY admission_count DESC;

-- Q19. Rank doctors by admissions within each department
SELECT department_name, doctor_name, admissions,
       DENSE_RANK() OVER(PARTITION BY department_name ORDER BY admissions DESC) AS department_rank
FROM (
  SELECT d.department_name, doc.doctor_name, COUNT(a.admission_id) AS admissions
  FROM doctors doc JOIN departments d USING(department_id)
  LEFT JOIN admissions a USING(doctor_id)
  GROUP BY d.department_name,doc.doctor_name
) x ORDER BY department_name,department_rank;

-- Q20. Running monthly billed revenue
WITH monthly AS (
  SELECT DATE_TRUNC('month',admission_date)::date AS month, SUM(billed_amount) AS revenue
  FROM admissions GROUP BY 1
)
SELECT month, ROUND(revenue,2) AS monthly_revenue,
       ROUND(SUM(revenue) OVER(ORDER BY month),2) AS running_revenue
FROM monthly ORDER BY month;

-- Q21. Month-over-month admission growth
WITH monthly AS (
  SELECT DATE_TRUNC('month',admission_date)::date AS month, COUNT(*) AS admissions
  FROM admissions GROUP BY 1
), lagged AS (
  SELECT month,admissions,LAG(admissions) OVER(ORDER BY month) AS previous_month
  FROM monthly
)
SELECT month,admissions,previous_month,
       ROUND(100.0*(admissions-previous_month)/NULLIF(previous_month,0),2) AS mom_growth_pct
FROM lagged ORDER BY month;

-- Q22. Bed occupancy snapshot (beds assigned to currently admitted records)
SELECT b.ward_name,b.bed_type,
       COUNT(DISTINCT a.bed_id) FILTER (WHERE a.status='Admitted') AS occupied_beds,
       COUNT(DISTINCT b.bed_id) AS total_beds,
       ROUND(100.0*COUNT(DISTINCT a.bed_id) FILTER (WHERE a.status='Admitted')/
             NULLIF(COUNT(DISTINCT b.bed_id),0),2) AS occupancy_pct
FROM beds b LEFT JOIN admissions a ON a.bed_id=b.bed_id AND a.status='Admitted'
WHERE b.is_active GROUP BY b.ward_name,b.bed_type ORDER BY occupancy_pct DESC;

-- Q23. Patients with multiple diagnoses during an admission
SELECT admission_id,COUNT(*) AS diagnosis_count,
       STRING_AGG(diagnosis_name,', ' ORDER BY diagnosis_name) AS diagnoses
FROM diagnoses GROUP BY admission_id HAVING COUNT(*)>1 ORDER BY diagnosis_count DESC;

-- Q24. Primary diagnosis category by admission type
SELECT a.admission_type,d.diagnosis_category,COUNT(*) AS cases
FROM admissions a JOIN diagnoses d USING(admission_id)
WHERE d.is_primary GROUP BY 1,2 ORDER BY 1,cases DESC;

-- Q25. Payment delays after discharge
SELECT a.admission_id,a.discharge_date,MIN(p.payment_date) AS first_payment_date,
       MIN(p.payment_date)-a.discharge_date AS days_to_first_payment
FROM admissions a JOIN payments p USING(admission_id)
WHERE a.discharge_date IS NOT NULL
GROUP BY a.admission_id,a.discharge_date ORDER BY days_to_first_payment DESC;

-- Q26. Weekend vs weekday admissions
SELECT CASE WHEN EXTRACT(ISODOW FROM admission_date) IN (6,7) THEN 'Weekend' ELSE 'Weekday' END AS day_type,
       COUNT(*) AS admissions
FROM admissions GROUP BY 1;

-- Q27. Department share of total billed revenue
WITH dept AS (
  SELECT d.department_name,SUM(a.billed_amount) AS revenue
  FROM admissions a JOIN doctors doc USING(doctor_id)
  JOIN departments d USING(department_id) GROUP BY 1
)
SELECT department_name,ROUND(revenue,2) AS revenue,
       ROUND(100.0*revenue/SUM(revenue) OVER(),2) AS revenue_share_pct
FROM dept ORDER BY revenue DESC;

-- Q28. First and most recent admission per patient
SELECT DISTINCT patient_id,
       FIRST_VALUE(admission_date) OVER(PARTITION BY patient_id ORDER BY admission_date) AS first_admission,
       FIRST_VALUE(admission_date) OVER(PARTITION BY patient_id ORDER BY admission_date DESC) AS latest_admission
FROM admissions ORDER BY patient_id;

-- Q29. Patients not admitted in the last 12 months of the data period
WITH max_date AS (SELECT MAX(admission_date) AS max_admission_date FROM admissions)
SELECT p.patient_id,p.patient_name
FROM patients p
WHERE NOT EXISTS (
  SELECT 1 FROM admissions a,max_date m
  WHERE a.patient_id=p.patient_id
    AND a.admission_date >= m.max_admission_date - INTERVAL '12 months'
);

-- Q30. Data quality checks: invalid date logic and negative balances
SELECT 'invalid_discharge_before_admission' AS check_name,COUNT(*) AS issue_count
FROM admissions WHERE discharge_date < admission_date
UNION ALL
SELECT 'negative_billed_amount',COUNT(*) FROM admissions WHERE billed_amount<0
UNION ALL
SELECT 'payments_after_current_date',COUNT(*) FROM payments WHERE payment_date>CURRENT_DATE;
