# Business Questions & Analysis Checklist

Use these questions to explain the project in a portfolio review or interview.

## Patient and admission analysis
1. How many unique patients and admissions are recorded?
2. How do admissions change month over month?
3. Which cities contribute the most unique patients?
4. What is the patient age-band distribution at admission?
5. What proportion of admissions are emergency, elective, and urgent?

## Clinical and operational analysis
6. Which diagnoses occur most frequently?
7. Which departments handle the highest admission volume?
8. Which doctors have the highest admission workload?
9. What is the average length of stay by admission type?
10. Which admissions have a stay longer than ten days?
11. Which discharged patients have another admission within 30 days?
12. How does diagnosis category vary by admission type?
13. What is the simplified bed occupancy snapshot by ward and bed type?

## Financial analysis
14. Which departments generate the highest billed amount?
15. What is the completed payment amount by payment method?
16. Which admissions have the largest outstanding balance?
17. What is the overall collection percentage?
18. How many days pass between discharge and first recorded payment?

## Data quality and engineering
19. Are there discharge dates earlier than admission dates?
20. Are there negative billed amounts or payment amounts?
21. Which indexes support the main date-range and patient-history queries?
22. How does the query plan change before and after indexing?

## Interpretation reminders
- A high admission count is not automatically a measure of quality.
- A simple 30-day readmission flag is not a risk-adjusted clinical quality metric.
- The bed query is a point-in-time simplified snapshot, not a bed-days occupancy measure.
- Revenue in this project means billed amount; collections are tracked separately.
