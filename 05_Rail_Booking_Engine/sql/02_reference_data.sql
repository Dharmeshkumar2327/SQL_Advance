-- =============================================================================
-- 02_reference_data.sql
-- Master data: business rules, classes, quotas, 62 stations, 10 trains with
-- timetables, coach compositions and an auto-generated seat map with quota
-- earmarking (RAC side-lowers, Tatkal, Ladies, Senior/lower-berth).
--
-- Timetables, distances and rakes are illustrative (inspired by real services,
-- not an official timetable).
-- =============================================================================
\set ON_ERROR_STOP on
SET search_path = rail, public;

-- -----------------------------------------------------------------------------
-- Business rules
-- -----------------------------------------------------------------------------
INSERT INTO rules (rule_key, rule_value, note) VALUES
  ('arp_days',               '60',    'Advance Reservation Period, days before journey (excl. journey day)'),
  ('arp_open_time',          '08:00', 'General booking opens at this time on ARP day'),
  ('tatkal_ac_open',         '10:00', 'Tatkal for AC classes opens one day before boarding date'),
  ('tatkal_nonac_open',      '11:00', 'Tatkal for non-AC classes opens one day before boarding date'),
  ('chart_hours_before',     '4',     'Chart prepared N hours before departure from origin; booking closes'),
  ('clerkage',               '60',    'Per-passenger deduction when cancelling RAC/WL tickets'),
  ('wl_cancel_cutoff_min',   '30',    'RAC/WL refundable until N minutes before departure'),
  ('gst_ac_pct',             '5',     'GST on AC class fares');

-- -----------------------------------------------------------------------------
-- Train types
-- -----------------------------------------------------------------------------
INSERT INTO train_types VALUES
  ('RAJDHANI',      true,  1.35, true),
  ('SHATABDI',      true,  1.25, true),
  ('VANDE_BHARAT',  true,  1.40, true),
  ('SUPERFAST',     true,  1.00, false),
  ('MAIL_EXPRESS',  false, 1.00, false);

-- -----------------------------------------------------------------------------
-- Travel classes & fare components (simplified but shaped like IR fare tables)
-- -----------------------------------------------------------------------------
INSERT INTO travel_classes
 (class_code, class_name, is_ac, has_berths, display_order, seats_per_coach, rac_berths_per_coach, tatkal_per_coach,
  max_waitlist, fare_per_km, reservation_charge, superfast_charge, tatkal_pct, tatkal_min, tatkal_max, catering_charge, cancel_flat_charge)
VALUES
 ('1A', 'First AC',            true,  true,  1, 24,  0,  0,  20, 3.300, 60, 75, 30, 400, 500, 350, 240),
 ('EC', 'Executive Chair Car', true,  false, 2, 56,  0,  6,  30, 2.250, 60, 75, 30, 400, 500, 300, 240),
 ('2A', 'AC 2 Tier',           true,  true,  3, 48,  2,  8,  80, 1.950, 50, 45, 30, 400, 500, 300, 200),
 ('3A', 'AC 3 Tier',           true,  true,  4, 72,  4, 12, 150, 1.350, 40, 45, 30, 300, 400, 250, 180),
 ('CC', 'AC Chair Car',        true,  false, 5, 75,  0, 12, 100, 1.050, 40, 45, 30, 125, 225, 200, 180),
 ('SL', 'Sleeper',             false, true,  6, 72,  6, 16, 200, 0.480, 20, 30, 30, 100, 200,   0, 120),
 ('2S', 'Second Sitting',      false, false, 7, 108, 0, 18, 150, 0.300, 15, 15, 10,  10,  15,   0,  60);

INSERT INTO quotas VALUES
  ('GN', 'General',                          true,  true,  6),
  ('TQ', 'Tatkal',                           false, true,  4),
  ('LD', 'Ladies',                           false, false, 6),
  ('SS', 'Senior Citizen / Lower Berth',     false, false, 2);

-- -----------------------------------------------------------------------------
-- Stations
-- -----------------------------------------------------------------------------
INSERT INTO stations (station_code, station_name, city, state, zone) VALUES
 ('NDLS','New Delhi','New Delhi','Delhi','NR'),
 ('MMCT','Mumbai Central','Mumbai','Maharashtra','WR'),
 ('CSMT','Chhatrapati Shivaji Maharaj Terminus','Mumbai','Maharashtra','CR'),
 ('BVI','Borivali','Mumbai','Maharashtra','WR'),
 ('ST','Surat','Surat','Gujarat','WR'),
 ('BRC','Vadodara Junction','Vadodara','Gujarat','WR'),
 ('ADI','Ahmedabad Junction','Ahmedabad','Gujarat','WR'),
 ('VAPI','Vapi','Vapi','Gujarat','WR'),
 ('RTM','Ratlam Junction','Ratlam','Madhya Pradesh','WR'),
 ('KOTA','Kota Junction','Kota','Rajasthan','WCR'),
 ('HWH','Howrah Junction','Kolkata','West Bengal','ER'),
 ('ASN','Asansol Junction','Asansol','West Bengal','ER'),
 ('DHN','Dhanbad Junction','Dhanbad','Jharkhand','ECR'),
 ('GAYA','Gaya Junction','Gaya','Bihar','ECR'),
 ('DDU','Pt. Deen Dayal Upadhyaya Jn','Chandauli','Uttar Pradesh','ECR'),
 ('PRYJ','Prayagraj Junction','Prayagraj','Uttar Pradesh','NCR'),
 ('CNB','Kanpur Central','Kanpur','Uttar Pradesh','NCR'),
 ('SBC','KSR Bengaluru City','Bengaluru','Karnataka','SWR'),
 ('ATP','Anantapur','Anantapur','Andhra Pradesh','SCR'),
 ('GTL','Guntakal Junction','Guntakal','Andhra Pradesh','SCR'),
 ('RC','Raichur','Raichur','Karnataka','SCR'),
 ('WADI','Wadi Junction','Wadi','Karnataka','CR'),
 ('SUR','Solapur','Solapur','Maharashtra','CR'),
 ('DD','Daund Junction','Daund','Maharashtra','CR'),
 ('MMR','Manmad Junction','Manmad','Maharashtra','CR'),
 ('BSL','Bhusaval Junction','Bhusaval','Maharashtra','CR'),
 ('ET','Itarsi Junction','Itarsi','Madhya Pradesh','WCR'),
 ('BPL','Bhopal Junction','Bhopal','Madhya Pradesh','WCR'),
 ('JHS','Virangana Lakshmibai Jhansi','Jhansi','Uttar Pradesh','NCR'),
 ('AGC','Agra Cantt','Agra','Uttar Pradesh','NCR'),
 ('MTJ','Mathura Junction','Mathura','Uttar Pradesh','NCR'),
 ('GWL','Gwalior Junction','Gwalior','Madhya Pradesh','NCR'),
 ('MAS','MGR Chennai Central','Chennai','Tamil Nadu','SR'),
 ('VJA','Vijayawada Junction','Vijayawada','Andhra Pradesh','SCR'),
 ('WL','Warangal','Warangal','Telangana','SCR'),
 ('BPQ','Balharshah','Ballarpur','Maharashtra','CR'),
 ('NGP','Nagpur Junction','Nagpur','Maharashtra','CR'),
 ('UMB','Ambala Cantt','Ambala','Haryana','NR'),
 ('LDH','Ludhiana Junction','Ludhiana','Punjab','NR'),
 ('JAT','Jammu Tawi','Jammu','Jammu and Kashmir','NR'),
 ('SVDK','Shri Mata Vaishno Devi Katra','Katra','Jammu and Kashmir','NR'),
 ('KYN','Kalyan Junction','Kalyan','Maharashtra','CR'),
 ('NK','Nasik Road','Nashik','Maharashtra','CR'),
 ('AK','Akola Junction','Akola','Maharashtra','CR'),
 ('BD','Badnera Junction','Amravati','Maharashtra','CR'),
 ('R','Raipur Junction','Raipur','Chhattisgarh','SECR'),
 ('BSP','Bilaspur Junction','Bilaspur','Chhattisgarh','SECR'),
 ('ROU','Rourkela Junction','Rourkela','Odisha','SER'),
 ('TATA','Tatanagar Junction','Jamshedpur','Jharkhand','SER'),
 ('KGP','Kharagpur Junction','Kharagpur','West Bengal','SER'),
 ('BWT','Bangarapet Junction','Bangarapet','Karnataka','SWR'),
 ('JTJ','Jolarpettai Junction','Jolarpettai','Tamil Nadu','SR'),
 ('KPD','Katpadi Junction','Vellore','Tamil Nadu','SR'),
 ('AJJ','Arakkonam Junction','Arakkonam','Tamil Nadu','SR'),
 ('BLS','Balasore','Balasore','Odisha','SER'),
 ('CTC','Cuttack','Cuttack','Odisha','ECoR'),
 ('BBS','Bhubaneswar','Bhubaneswar','Odisha','ECoR'),
 ('BAM','Brahmapur','Berhampur','Odisha','ECoR'),
 ('VSKP','Visakhapatnam','Visakhapatnam','Andhra Pradesh','ECoR'),
 ('RJY','Rajahmundry','Rajahmundry','Andhra Pradesh','SCR'),
 ('OGL','Ongole','Ongole','Andhra Pradesh','SCR'),
 ('NLR','Nellore','Nellore','Andhra Pradesh','SCR');

-- -----------------------------------------------------------------------------
-- Trains
-- -----------------------------------------------------------------------------
INSERT INTO trains (train_no, train_name, train_type, runs_on) VALUES
 ('12951','Mumbai Rajdhani Express',         'RAJDHANI',     '{1,2,3,4,5,6,7}'),
 ('12301','Howrah Rajdhani Express',         'RAJDHANI',     '{1,2,3,4,5,6,7}'),
 ('12627','Karnataka Express',               'SUPERFAST',    '{1,2,3,4,5,6,7}'),
 ('12621','Tamil Nadu Express',              'SUPERFAST',    '{1,2,3,4,5,6,7}'),
 ('12002','Bhopal Shatabdi Express',         'SHATABDI',     '{1,2,3,5,6,7}'),
 ('22439','New Delhi - Katra Vande Bharat',  'VANDE_BHARAT', '{1,3,4,5,6,7}'),
 ('12809','Mumbai - Howrah Mail (via Nagpur)','MAIL_EXPRESS','{1,2,3,4,5,6,7}'),
 ('12658','Chennai Mail',                    'MAIL_EXPRESS', '{1,2,3,4,5,6,7}'),
 ('12839','Howrah - Chennai Mail',           'MAIL_EXPRESS', '{1,2,3,4,5,6,7}'),
 ('12009','Mumbai - Ahmedabad Shatabdi',     'SHATABDI',     '{1,2,3,4,5,6}');

-- -----------------------------------------------------------------------------
-- Timetables: (train, seq, station, arr, dep, day_offset, km)
-- -----------------------------------------------------------------------------
INSERT INTO train_stops (train_no, stop_seq, station_code, arrival_time, departure_time, day_offset, distance_km) VALUES
 -- 12951 Mumbai Rajdhani
 ('12951',1,'MMCT',NULL,'17:00',0,0),   ('12951',2,'BVI','17:22','17:24',0,30),
 ('12951',3,'ST','19:43','19:48',0,263),('12951',4,'BRC','21:06','21:16',0,392),
 ('12951',5,'RTM','00:15','00:18',1,652),('12951',6,'KOTA','03:15','03:25',1,920),
 ('12951',7,'NDLS','08:32',NULL,1,1386),
 -- 12301 Howrah Rajdhani
 ('12301',1,'HWH',NULL,'16:50',0,0),    ('12301',2,'ASN','19:10','19:12',0,200),
 ('12301',3,'DHN','20:05','20:10',0,259),('12301',4,'GAYA','22:28','22:31',0,458),
 ('12301',5,'DDU','01:00','01:10',1,664),('12301',6,'PRYJ','03:10','03:12',1,816),
 ('12301',7,'CNB','05:05','05:10',1,1010),('12301',8,'NDLS','10:00',NULL,1,1450),
 -- 12627 Karnataka Express
 ('12627',1,'SBC',NULL,'19:20',0,0),    ('12627',2,'ATP','22:50','22:52',0,217),
 ('12627',3,'GTL','00:40','00:50',1,330),('12627',4,'RC','02:30','02:35',1,460),
 ('12627',5,'WADI','04:30','04:35',1,570),('12627',6,'SUR','06:40','06:45',1,765),
 ('12627',7,'DD','09:50','09:55',1,950), ('12627',8,'MMR','13:30','13:35',1,1240),
 ('12627',9,'BSL','16:00','16:05',1,1425),('12627',10,'ET','21:20','21:30',1,1730),
 ('12627',11,'BPL','23:10','23:20',1,1822),('12627',12,'JHS','03:25','03:35',2,2113),
 ('12627',13,'AGC','06:20','06:25',2,2328),('12627',14,'NDLS','09:40',NULL,2,2523),
 -- 12621 Tamil Nadu Express
 ('12621',1,'MAS',NULL,'22:00',0,0),    ('12621',2,'VJA','04:30','04:45',1,431),
 ('12621',3,'WL','07:40','07:42',1,640), ('12621',4,'BPQ','11:40','11:50',1,888),
 ('12621',5,'NGP','15:30','15:35',1,1095),('12621',6,'ET','22:00','22:10',1,1392),
 ('12621',7,'BPL','23:45','23:55',1,1484),('12621',8,'JHS','03:55','04:05',2,1775),
 ('12621',9,'AGC','06:35','06:40',2,1990),('12621',10,'NDLS','09:35',NULL,2,2182),
 -- 12002 Bhopal Shatabdi
 ('12002',1,'NDLS',NULL,'06:00',0,0),   ('12002',2,'MTJ','07:19','07:20',0,141),
 ('12002',3,'AGC','07:50','07:55',0,195),('12002',4,'GWL','09:23','09:28',0,313),
 ('12002',5,'JHS','10:38','10:46',0,411),('12002',6,'BPL','14:25',NULL,0,702),
 -- 22439 Vande Bharat
 ('22439',1,'NDLS',NULL,'06:00',0,0),   ('22439',2,'UMB','08:10','08:12',0,199),
 ('22439',3,'LDH','09:20','09:22',0,313),('22439',4,'JAT','12:38','12:40',0,577),
 ('22439',5,'SVDK','14:00',NULL,0,655),
 -- 12809 Mumbai - Howrah Mail
 ('12809',1,'CSMT',NULL,'21:00',0,0),   ('12809',2,'KYN','21:48','21:50',0,54),
 ('12809',3,'NK','00:15','00:20',1,187), ('12809',4,'BSL','03:55','04:05',1,443),
 ('12809',5,'AK','06:00','06:05',1,577), ('12809',6,'BD','07:45','07:50',1,657),
 ('12809',7,'NGP','10:00','10:10',1,837),('12809',8,'R','15:00','15:15',1,1130),
 ('12809',9,'BSP','17:05','17:20',1,1240),('12809',10,'ROU','22:50','22:58',1,1590),
 ('12809',11,'TATA','02:30','02:40',2,1765),('12809',12,'KGP','04:50','04:55',2,1895),
 ('12809',13,'HWH','06:45',NULL,2,1968),
 -- 12658 Chennai Mail
 ('12658',1,'SBC',NULL,'22:40',0,0),    ('12658',2,'BWT','23:45','23:47',0,70),
 ('12658',3,'JTJ','01:15','01:17',1,145),('12658',4,'KPD','02:20','02:25',1,229),
 ('12658',5,'AJJ','03:20','03:22',1,290),('12658',6,'MAS','04:55',NULL,1,359),
 -- 12839 Howrah - Chennai Mail
 ('12839',1,'HWH',NULL,'23:45',0,0),    ('12839',2,'KGP','01:40','01:45',1,116),
 ('12839',3,'BLS','03:20','03:22',1,232),('12839',4,'CTC','05:20','05:25',1,409),
 ('12839',5,'BBS','06:05','06:10',1,437),('12839',6,'BAM','08:30','08:35',1,604),
 ('12839',7,'VSKP','13:30','13:50',1,879),('12839',8,'RJY','17:00','17:02',1,1076),
 ('12839',9,'VJA','19:30','19:45',1,1225),('12839',10,'OGL','21:50','21:52',1,1357),
 ('12839',11,'NLR','23:15','23:17',1,1473),('12839',12,'MAS','02:15',NULL,2,1661),
 -- 12009 Mumbai - Ahmedabad Shatabdi
 ('12009',1,'MMCT',NULL,'06:20',0,0),   ('12009',2,'BVI','06:45','06:47',0,30),
 ('12009',3,'VAPI','08:10','08:12',0,170),('12009',4,'ST','09:10','09:15',0,263),
 ('12009',5,'BRC','10:45','10:50',0,392),('12009',6,'ADI','12:45',NULL,0,491);

-- -----------------------------------------------------------------------------
-- Rake composition: (train, class, coach prefix, number of coaches)
-- -----------------------------------------------------------------------------
WITH rake(train_no, class_code, prefix, n_coaches) AS (VALUES
   ('12951','1A','H',1), ('12951','2A','A',3), ('12951','3A','B',6),
   ('12301','1A','H',1), ('12301','2A','A',3), ('12301','3A','B',7),
   ('12627','2A','A',1), ('12627','3A','B',4), ('12627','SL','S',8),
   ('12621','1A','H',1), ('12621','2A','A',2), ('12621','3A','B',5), ('12621','SL','S',7),
   ('12002','EC','E',1), ('12002','CC','C',8),
   ('22439','EC','E',2), ('22439','CC','C',6),
   ('12809','2A','A',1), ('12809','3A','B',3), ('12809','SL','S',8),
   ('12658','2A','A',1), ('12658','3A','B',2), ('12658','SL','S',6), ('12658','2S','D',2),
   ('12839','2A','A',1), ('12839','3A','B',4), ('12839','SL','S',7),
   ('12009','EC','E',1), ('12009','CC','C',7)
)
INSERT INTO coaches (train_no, coach_no, class_code, position)
SELECT r.train_no,
       r.prefix || g.n,
       r.class_code,
       ROW_NUMBER() OVER (PARTITION BY r.train_no ORDER BY tc.display_order, g.n)
FROM rake r
JOIN travel_classes tc USING (class_code)
CROSS JOIN LATERAL generate_series(1, r.n_coaches) AS g(n);

-- -----------------------------------------------------------------------------
-- Seat map: berth types repeat per bay/row depending on class layout
-- -----------------------------------------------------------------------------
INSERT INTO seats (coach_id, berth_no, berth_type)
SELECT c.coach_id,
       b.berth_no,
       (CASE c.class_code
          WHEN '1A' THEN (ARRAY['LB','UB'])[1 + (b.berth_no - 1) % 2]
          WHEN '2A' THEN (ARRAY['LB','UB','LB','UB','SL','SU'])[1 + (b.berth_no - 1) % 6]
          WHEN '3A' THEN (ARRAY['LB','MB','UB','LB','MB','UB','SL','SU'])[1 + (b.berth_no - 1) % 8]
          WHEN 'SL' THEN (ARRAY['LB','MB','UB','LB','MB','UB','SL','SU'])[1 + (b.berth_no - 1) % 8]
          WHEN 'CC' THEN (ARRAY['WS','MS','AS','AS','WS'])[1 + (b.berth_no - 1) % 5]
          WHEN 'EC' THEN (ARRAY['WS','AS','AS','WS'])[1 + (b.berth_no - 1) % 4]
          WHEN '2S' THEN (ARRAY['WS','MS','AS','AS','MS','WS'])[1 + (b.berth_no - 1) % 6]
        END)::berth_type
FROM coaches c
JOIN travel_classes tc USING (class_code)
CROSS JOIN LATERAL generate_series(1, tc.seats_per_coach) AS b(berth_no);

-- 1) RAC berths: the last N side-lowers of every coach (shared by two passengers)
UPDATE seats s SET is_rac_berth = true
FROM (
  SELECT s.seat_id,
         ROW_NUMBER() OVER (PARTITION BY s.coach_id ORDER BY s.berth_no DESC) AS rn,
         tc.rac_berths_per_coach
  FROM seats s JOIN coaches c USING (coach_id) JOIN travel_classes tc USING (class_code)
  WHERE s.berth_type = 'SL'
) x
WHERE x.seat_id = s.seat_id AND x.rn <= x.rac_berths_per_coach;

-- 2) Tatkal: last N non-RAC berths of every coach
UPDATE seats s SET quota_code = 'TQ'
FROM (
  SELECT s.seat_id,
         ROW_NUMBER() OVER (PARTITION BY s.coach_id ORDER BY s.berth_no DESC) AS rn,
         tc.tatkal_per_coach
  FROM seats s JOIN coaches c USING (coach_id) JOIN travel_classes tc USING (class_code)
  WHERE NOT s.is_rac_berth
) x
WHERE x.seat_id = s.seat_id AND x.rn <= x.tatkal_per_coach;

-- 3) Ladies: first 6 berths of the first SL and first 3A coach of each train
UPDATE seats s SET quota_code = 'LD'
FROM (
  SELECT c.coach_id
  FROM (SELECT coach_id, ROW_NUMBER() OVER (PARTITION BY train_no, class_code ORDER BY position) AS rn
        FROM coaches WHERE class_code IN ('SL','3A')) c
  WHERE c.rn = 1
) first_coach
WHERE s.coach_id = first_coach.coach_id AND s.berth_no <= 6 AND s.quota_code = 'GN' AND NOT s.is_rac_berth;

-- 4) Senior citizen / lower-berth quota: first few GN lower berths of each sleeper-type coach
UPDATE seats s SET quota_code = 'SS'
FROM (
  SELECT s.seat_id, c.class_code,
         ROW_NUMBER() OVER (PARTITION BY s.coach_id ORDER BY s.berth_no) AS rn
  FROM seats s JOIN coaches c USING (coach_id)
  WHERE s.berth_type = 'LB' AND s.quota_code = 'GN' AND c.class_code IN ('SL','3A','2A')
) x
WHERE x.seat_id = s.seat_id
  AND x.rn <= CASE x.class_code WHEN 'SL' THEN 4 WHEN '3A' THEN 3 ELSE 2 END;
