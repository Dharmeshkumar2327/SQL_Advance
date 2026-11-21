# Dashboard Plan

Build the dashboard in Power BI or Tableau after running the SQL scripts.

## Page 1 — Executive Overview
**KPI cards**
- Total admissions
- Unique admitted patients
- Average length of stay
- Total billed revenue
- Completed collections
- Collection percentage

**Visuals**
- Monthly admissions line chart
- Admissions by type donut chart
- Revenue by department bar chart

## Page 2 — Patient & Admission Trends
- Admissions by month
- Patients by city
- Patient age-band distribution
- Admission type by month
- Weekday vs weekend admissions

## Page 3 — Clinical & Stay Insights
- Top diagnosis categories
- Diagnosis count by admission type
- Average length of stay by admission type
- Long-stay admission table
- 30-day readmission candidate trend

## Page 4 — Hospital Operations
- Admissions by department
- Doctor workload ranking
- Bed occupancy snapshot by ward and bed type
- Current admitted patient count

## Page 5 — Financial Performance
- Billed amount by month
- Completed payments by method
- Outstanding balance by admission
- Department revenue contribution
- Payment delay distribution

## Recommended slicers
- Admission date
- Department
- Admission type
- City
- Gender
- Bed type
- Payment status

## Data model note
For a robust Power BI model, avoid directly joining multiple one-to-many child tables (diagnoses and payments) into one flat table, as that can multiply rows and inflate totals. Use separate fact tables or pre-aggregate each child table to admission grain before combining.
