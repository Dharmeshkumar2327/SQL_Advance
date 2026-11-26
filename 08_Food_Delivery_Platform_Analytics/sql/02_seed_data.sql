-- 02_seed_data.sql
-- Small, deterministic synthetic dataset. Re-running this script after schema creation
-- is safe because the tables are cleared by 01_schema.sql.

INSERT INTO customers (customer_name,email,city,signup_date,customer_status) VALUES
('Aarav Shah','aarav@example.com','Bengaluru','2024-01-10','active'),
('Diya Patel','diya@example.com','Bengaluru','2024-02-14','active'),
('Rohan Mehta','rohan@example.com','Mumbai','2024-03-02','active'),
('Ananya Rao','ananya@example.com','Bengaluru','2024-04-18','active'),
('Kabir Singh','kabir@example.com','Delhi','2024-05-09','active'),
('Meera Nair','meera@example.com','Mumbai','2024-06-21','active'),
('Ishaan Gupta','ishaan@example.com','Delhi','2024-07-11','inactive'),
('Sara Khan','sara@example.com','Bengaluru','2024-08-01','active');

INSERT INTO restaurants (restaurant_name,city,cuisine,rating) VALUES
('Spice Route','Bengaluru','Indian',4.5),
('Pasta Corner','Bengaluru','Italian',4.2),
('Mumbai Tiffin','Mumbai','Indian',4.1),
('Wok Express','Delhi','Asian',4.4),
('Green Bowl','Mumbai','Healthy',4.6);

INSERT INTO menu_items (restaurant_id,item_name,category,list_price) VALUES
(1,'Paneer Biryani','Main Course',240),(1,'Masala Dosa','Main Course',120),
(1,'Gulab Jamun','Dessert',70),(2,'Penne Alfredo','Main Course',260),
(2,'Garlic Bread','Starter',110),(3,'Veg Thali','Main Course',190),
(3,'Pav Bhaji','Main Course',150),(4,'Veg Noodles','Main Course',180),
(4,'Spring Rolls','Starter',130),(5,'Quinoa Bowl','Main Course',280);

INSERT INTO delivery_partners (partner_name,city,joined_date,vehicle_type) VALUES
('Vikram Das','Bengaluru','2023-11-01','Bike'),
('Neha Joshi','Bengaluru','2024-01-15','Scooter'),
('Arjun Verma','Mumbai','2023-09-10','Bike'),
('Pooja Iyer','Delhi','2024-02-20','Scooter'),
('Rahul Roy','Mumbai','2024-03-05','Bicycle');

INSERT INTO orders
(customer_id,restaurant_id,partner_id,order_placed_at,promised_delivery_at,delivered_at,
 order_status,delivery_fee,discount_amount,cancellation_reason) VALUES
(1,1,1,'2025-01-05 12:00','2025-01-05 12:45','2025-01-05 12:40','delivered',30,20,NULL),
(2,2,2,'2025-01-07 19:00','2025-01-07 19:50','2025-01-07 20:05','delivered',25,0,NULL),
(3,3,3,'2025-01-10 13:00','2025-01-10 13:45','2025-01-10 13:38','delivered',20,15,NULL),
(1,1,1,'2025-02-02 20:00','2025-02-02 20:45','2025-02-02 20:42','delivered',30,10,NULL),
(4,2,2,'2025-02-08 14:00','2025-02-08 14:50','2025-02-08 15:10','delivered',25,30,NULL),
(5,4,4,'2025-02-11 19:00','2025-02-11 19:45',NULL,'cancelled',25,0,'Restaurant unavailable'),
(6,3,3,'2025-03-03 12:30','2025-03-03 13:15','2025-03-03 13:10','delivered',20,0,NULL),
(2,1,1,'2025-03-09 19:15','2025-03-09 20:00','2025-03-09 19:55','delivered',30,25,NULL),
(7,4,4,'2025-03-15 20:00','2025-03-15 20:45','2025-03-15 21:05','delivered',25,10,NULL),
(8,5,5,'2025-03-18 13:00','2025-03-18 13:50','2025-03-18 13:40','delivered',20,0,NULL),
(3,3,3,'2025-04-04 19:00','2025-04-04 19:45','2025-04-04 19:42','delivered',20,10,NULL),
(1,1,2,'2025-04-12 12:00','2025-04-12 12:45','2025-04-12 13:00','delivered',30,0,NULL),
(4,2,2,'2025-04-20 20:00','2025-04-20 20:50',NULL,'cancelled',25,0,'Customer cancelled'),
(6,5,5,'2025-04-25 13:00','2025-04-25 13:50','2025-04-25 13:45','delivered',20,15,NULL);

INSERT INTO order_items (order_id,item_id,quantity,unit_price) VALUES
(1,1,1,240),(1,3,2,70),(2,4,1,260),(2,5,1,110),
(3,6,2,190),(4,1,1,240),(4,2,1,120),(5,4,1,260),
(5,5,2,110),(6,8,1,180),(7,7,2,150),(8,1,1,240),
(8,3,1,70),(9,8,2,180),(9,9,1,130),(10,10,1,280),
(11,6,1,190),(11,7,1,150),(12,2,2,120),(13,4,1,260),
(14,10,1,280);

INSERT INTO payments (order_id,payment_method,payment_status,amount,paid_at) VALUES
(1,'UPI','success',390,'2025-01-05 12:01'),
(2,'Card','success',395,'2025-01-07 19:01'),
(3,'UPI','success',385,'2025-01-10 13:01'),
(4,'UPI','success',380,'2025-02-02 20:01'),
(5,'Wallet','success',475,'2025-02-08 14:01'),
(6,'UPI','refunded',0,'2025-02-11 19:02'),
(7,'Card','success',320,'2025-03-03 12:31'),
(8,'UPI','success',315,'2025-03-09 19:16'),
(9,'Card','success',505,'2025-03-15 20:01'),
(10,'UPI','success',300,'2025-03-18 13:01'),
(11,'Wallet','success',350,'2025-04-04 19:01'),
(12,'UPI','success',390,'2025-04-12 12:01'),
(13,'Card','failed',0,'2025-04-20 20:01'),
(14,'UPI','success',285,'2025-04-25 13:01');

INSERT INTO reviews (order_id,customer_id,restaurant_rating,delivery_rating,review_text,reviewed_at) VALUES
(1,1,5,5,'Great food and fast delivery','2025-01-05 13:00'),
(2,2,4,3,'Food was good, delivery was late','2025-01-07 21:00'),
(3,3,4,5,'Good value','2025-01-10 14:00'),
(4,1,5,5,'Excellent','2025-02-02 21:00'),
(5,4,4,3,'Tasty but arrived late','2025-02-08 16:00'),
(7,6,4,4,'Nice meal','2025-03-03 14:00'),
(8,2,5,5,'Loved it','2025-03-09 21:00'),
(10,8,5,4,'Fresh and healthy','2025-03-18 14:00'),
(11,3,4,4,'Good experience','2025-04-04 20:00'),
(12,1,4,3,'A little delayed','2025-04-12 14:00'),
(14,6,5,5,'Very good','2025-04-25 14:00');
