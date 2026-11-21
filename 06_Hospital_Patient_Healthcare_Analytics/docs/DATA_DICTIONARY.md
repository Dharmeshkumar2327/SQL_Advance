# Data Dictionary

All records are synthetic and intended for SQL practice only.

## `departments`
| Column | Type | Description |
|---|---|---|
| department_id | integer, PK | Unique department identifier |
| department_name | varchar | Unique department name |
| floor_no | integer | Floor number; 0 represents ground/emergency level |

## `doctors`
| Column | Type | Description |
|---|---|---|
| doctor_id | integer, PK | Unique doctor identifier |
| doctor_name | varchar | Fictional doctor name |
| specialization | varchar | Doctor specialization |
| department_id | integer, FK | Department reference |
| hire_date | date | Fictional hire date |

## `patients`
| Column | Type | Description |
|---|---|---|
| patient_id | integer, PK | Synthetic patient identifier |
| patient_name | varchar | Fictional patient label |
| date_of_birth | date | Synthetic date of birth |
| gender | varchar | Synthetic demographic category |
| city | varchar | Synthetic city |
| registration_date | date | Registration date |

## `beds`
| Column | Type | Description |
|---|---|---|
| bed_id | integer, PK | Bed identifier |
| ward_name | varchar | Ward label |
| bed_type | varchar | General, Private, or ICU |
| is_active | boolean | Whether the bed is active |

## `admissions`
| Column | Type | Description |
|---|---|---|
| admission_id | integer, PK | Admission identifier |
| patient_id | integer, FK | Patient reference |
| doctor_id | integer, FK | Attending doctor reference |
| bed_id | integer, FK | Assigned bed reference |
| admission_date | date | Admission date |
| discharge_date | date, nullable | Discharge date; null for currently admitted records |
| admission_type | varchar | Emergency, Elective, or Urgent |
| status | varchar | Discharged, Admitted, or Transferred |
| billed_amount | numeric | Amount billed for the admission |

## `diagnoses`
| Column | Type | Description |
|---|---|---|
| diagnosis_id | integer, PK | Diagnosis row identifier |
| admission_id | integer, FK | Admission reference |
| diagnosis_code | varchar | Synthetic diagnosis code |
| diagnosis_name | varchar | Diagnosis label |
| diagnosis_category | varchar | Broad diagnosis category |
| is_primary | boolean | Whether it is the primary diagnosis |

## `payments`
| Column | Type | Description |
|---|---|---|
| payment_id | integer, PK | Payment row identifier |
| admission_id | integer, FK | Admission reference |
| payment_date | date | Payment date |
| payment_method | varchar | Cash, Card, UPI, Insurance, or Bank Transfer |
| amount | numeric | Payment amount |
| payment_status | varchar | Completed, Pending, or Refunded |

## Relationships
- One department can have many doctors.
- One patient can have many admissions.
- One doctor can manage many admissions.
- One bed can be associated with multiple admissions over time.
- One admission can have multiple diagnoses and payment records.
