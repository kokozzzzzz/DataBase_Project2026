-- 只读复核。完整的正反例及回滚验证使用 tests/verify_b_structure.py。
USE charging_platform;
SELECT TABLE_NAME, ENGINE, TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA=DATABASE()
  AND TABLE_NAME IN ('operator','station','charging_pile','parking_space','charging_gun',
    'equipment_status_log','equipment_outage_plan','equipment_change_request',
    'equipment_offline_task','tariff_rule','tariff_band','charging_order','meter_reading',
    'order_fee_detail','payment_record','refund_record')
ORDER BY TABLE_NAME;
-- 应包含 user_id -> user.user_id、vehicle_id -> vehicle.vehicle_id、gun_id -> charging_gun.gun_id。
SELECT CONSTRAINT_NAME,COLUMN_NAME,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='charging_order'
  AND REFERENCED_TABLE_NAME IS NOT NULL;
-- 两个生成列的表达式与索引可直接查看。
SHOW CREATE TABLE charging_order;
SHOW CREATE TABLE charging_gun;
SHOW CREATE TABLE equipment_offline_task;
SHOW TRIGGERS WHERE `Trigger` LIKE 'b\_%';
SELECT TABLE_NAME,SECURITY_TYPE
FROM information_schema.VIEWS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'v\_b\_%';
SELECT * FROM v_b_order_funds ORDER BY order_id LIMIT 10;
