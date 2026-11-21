-- 02_generate_synthetic_data.sql
-- Re-runnable: clears existing data and creates fictional sample records.
TRUNCATE payments, diagnoses, admissions, beds, doctors, patients, departments RESTART IDENTITY CASCADE;

INSERT INTO departments (department_name, floor_no) VALUES
('Cardiology',2),('Neurology',3),('Orthopedics',1),('Pediatrics',4),
('Oncology',5),('General Medicine',1),('Emergency',0),('Pulmonology',3);

INSERT INTO doctors (doctor_name, specialization, department_id, hire_date)
SELECT 'Dr. ' || (ARRAY['Aarav','Diya','Kabir','Anaya','Vivaan','Meera','Arjun','Isha','Rohan','Sara'])[((g-1)%10)+1]
       || ' ' || (ARRAY['Sharma','Patel','Rao','Singh','Nair','Khan'])[((g-1)%6)+1],
       d.department_name, d.department_id,
       DATE '2015-01-01' + ((g*37)%3000)
FROM generate_series(1,32) g
JOIN departments d ON d.department_id = ((g-1)%8)+1;

INSERT INTO patients (patient_name, date_of_birth, gender, city, registration_date)
SELECT 'Patient_' || g,
       DATE '1945-01-01' + ((g*173)%24000),
       (ARRAY['Female','Male','Other','Prefer not to say'])[((g-1)%4)+1],
       (ARRAY['Bengaluru','Mumbai','Pune','Delhi','Chennai','Hyderabad','Kolkata'])[((g-1)%7)+1],
       DATE '2022-01-01' + ((g*19)%1400)
FROM generate_series(1,500) g;

INSERT INTO beds (ward_name, bed_type, is_active)
SELECT (ARRAY['Ward A','Ward B','Ward C','ICU','Private Wing'])[((g-1)%5)+1],
       CASE WHEN g%10=0 THEN 'ICU' WHEN g%4=0 THEN 'Private' ELSE 'General' END,
       TRUE
FROM generate_series(1,80) g;

INSERT INTO admissions
(patient_id, doctor_id, bed_id, admission_date, discharge_date, admission_type, status, billed_amount)
SELECT
    ((g*17)%500)+1,
    ((g*7)%32)+1,
    ((g*11)%80)+1,
    DATE '2023-01-01' + ((g*3)%1050),
    CASE WHEN g%13=0 THEN NULL
         ELSE DATE '2023-01-01' + ((g*3)%1050) + (1+(g%14)) END,
    (ARRAY['Emergency','Elective','Urgent'])[((g-1)%3)+1],
    CASE WHEN g%13=0 THEN 'Admitted' ELSE 'Discharged' END,
    ROUND((5000 + ((g*791)%95000))::numeric,2)
FROM generate_series(1,1200) g;

INSERT INTO diagnoses (admission_id, diagnosis_code, diagnosis_name, diagnosis_category, is_primary)
SELECT a.admission_id,
       'DX-' || LPAD(((a.admission_id*7)%999)::text,3,'0'),
       (ARRAY['Hypertension','Type 2 Diabetes','Pneumonia','Fracture','Migraine','Asthma','Coronary Artery Disease','Anemia','Gastroenteritis','Arthritis'])[((a.admission_id-1)%10)+1],
       (ARRAY['Cardiovascular','Endocrine','Respiratory','Musculoskeletal','Neurological','Respiratory','Cardiovascular','Hematology','Digestive','Musculoskeletal'])[((a.admission_id-1)%10)+1],
       TRUE
FROM admissions a;

-- Add a secondary diagnosis to every fifth admission.
INSERT INTO diagnoses (admission_id, diagnosis_code, diagnosis_name, diagnosis_category, is_primary)
SELECT admission_id, 'SEC-' || admission_id, 'Anemia', 'Hematology', FALSE
FROM admissions WHERE admission_id % 5 = 0;

INSERT INTO payments (admission_id, payment_date, payment_method, amount, payment_status)
SELECT a.admission_id,
       COALESCE(a.discharge_date, a.admission_date) + (g.n-1),
       (ARRAY['Cash','Card','UPI','Insurance','Bank Transfer'])[((a.admission_id+g.n-2)%5)+1],
       ROUND((a.billed_amount * CASE WHEN g.n=1 THEN 0.60 ELSE 0.25 END)::numeric,2),
       CASE WHEN a.admission_id%17=0 AND g.n=2 THEN 'Pending' ELSE 'Completed' END
FROM admissions a
CROSS JOIN generate_series(1,2) AS g(n)
WHERE (g.n=1 OR a.admission_id%3=0);
