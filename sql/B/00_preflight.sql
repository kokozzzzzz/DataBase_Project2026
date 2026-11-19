-- 在 MySQL 客户端只读检查环境及重复建表风险。
USE charging_platform;
SELECT VERSION() AS mysql_version, DATABASE() AS database_name,
       @@session.time_zone AS session_time_zone;
SELECT TABLE_NAME, ENGINE, TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('user','vehicle');
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA=DATABASE()
  AND ((TABLE_NAME='user' AND COLUMN_NAME='user_id')
       OR (TABLE_NAME='vehicle' AND COLUMN_NAME IN ('vehicle_id','user_id')));
-- 首次安装 B 时，下面结果应为空。有记录时先核对已有结构及执行进度。
SELECT TABLE_NAME
FROM information_schema.TABLES
WHERE TABLE_SCHEMA=DATABASE()
  AND TABLE_NAME IN ('operator','station','charging_pile','parking_space','charging_gun',
    'equipment_status_log','equipment_outage_plan','equipment_change_request',
    'equipment_offline_task','tariff_rule','tariff_band','charging_order','meter_reading',
    'order_fee_detail','payment_record','refund_record');
