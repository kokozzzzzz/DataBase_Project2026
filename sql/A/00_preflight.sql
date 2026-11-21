-- A ⑥⑧ 安装前置检查（只读）
-- 用途：
--   1) 首次安装 A 前确认 D/B 依赖表及编号类型；
--   2) 当 sql/A/07_verify.sql 中 A03～A06 全为 0 时，定位是“未安装”还是“依赖缺失”。
-- 本脚本只查询 information_schema，不创建、修改或删除任何对象和数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT 'A00 current database' AS check_name,
       DATABASE() AS actual_value,
       IF(DATABASE() = 'charging_platform', 'PASS', 'FAIL') AS result;

-- A01：A 的 8 张直接依赖表必须存在。
SELECT 'A01 required dependency table' AS check_name,
       req.table_name AS actual_value,
       IF(t.TABLE_NAME IS NULL, 'MISSING', 'PASS') AS result
FROM (
              SELECT 'user' AS table_name
    UNION ALL SELECT 'vehicle'
    UNION ALL SELECT 'station'
    UNION ALL SELECT 'charging_pile'
    UNION ALL SELECT 'charging_gun'
    UNION ALL SELECT 'parking_space'
    UNION ALL SELECT 'equipment_outage_plan'
    UNION ALL SELECT 'charging_order'
) AS req
LEFT JOIN information_schema.TABLES AS t
       ON t.TABLE_SCHEMA = DATABASE()
      AND t.TABLE_NAME = req.table_name
      AND t.TABLE_TYPE = 'BASE TABLE'
ORDER BY req.table_name;

-- A02：依赖编号必须都是 BIGINT UNSIGNED。
SELECT 'A02 dependency id type' AS check_name,
       req.table_name AS actual_value,
       req.column_name AS id_column,
       COALESCE(c.COLUMN_TYPE, 'MISSING') AS actual_type,
       IF(c.COLUMN_TYPE = 'bigint unsigned', 'PASS', 'FAIL') AS result
FROM (
              SELECT 'user' AS table_name, 'user_id' AS column_name
    UNION ALL SELECT 'vehicle', 'vehicle_id'
    UNION ALL SELECT 'station', 'station_id'
    UNION ALL SELECT 'charging_pile', 'pile_id'
    UNION ALL SELECT 'charging_gun', 'gun_id'
    UNION ALL SELECT 'parking_space', 'parking_space_id'
    UNION ALL SELECT 'equipment_outage_plan', 'outage_plan_id'
    UNION ALL SELECT 'charging_order', 'order_id'
) AS req
LEFT JOIN information_schema.COLUMNS AS c
       ON c.TABLE_SCHEMA = DATABASE()
      AND c.TABLE_NAME = req.table_name
      AND c.COLUMN_NAME = req.column_name
ORDER BY req.table_name;

-- A03～A06：A 对象当前数量。
SELECT 'A03 A table count' AS check_name,
       COUNT(*) AS actual_value,
       IF(COUNT(*) = 10, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'charging_reservation', 'reservation_status_log',
      'queue_record', 'queue_status_log',
      'arrival_checkin', 'parking_occupancy',
      'station_notice', 'notice_revision',
      'notice_recipient', 'notification_record'
  );

SELECT 'A04 A view count' AS check_name,
       COUNT(*) AS actual_value,
       IF(COUNT(*) = 8, 'PASS', 'FAIL') AS result
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME LIKE 'v\_a\_%';

SELECT 'A05 A procedure count' AS check_name,
       COUNT(*) AS actual_value,
       IF(COUNT(*) = 14, 'PASS', 'FAIL') AS result
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE()
  AND ROUTINE_TYPE = 'PROCEDURE'
  AND ROUTINE_NAME IN (
      'sp_create_reservation', 'sp_cancel_reservation',
      'sp_reschedule_reservation', 'sp_check_in_reservation',
      'sp_join_queue', 'sp_call_next_queue', 'sp_check_in_queue',
      'sp_release_parking_space', 'sp_consume_admission',
      'sp_expire_overdue_admissions', 'sp_publish_notice',
      'sp_withdraw_notice', 'sp_update_notification_status',
      'sp_expire_notices'
  );

SELECT 'A06 A trigger count' AS check_name,
       COUNT(*) AS actual_value,
       IF(COUNT(*) = 13, 'PASS', 'FAIL') AS result
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = DATABASE()
  AND TRIGGER_NAME LIKE 'a\_%';

-- A07：把常见原因直接写进结果。
SELECT 'A07 diagnosis' AS check_name,
       CASE
           WHEN (
               SELECT COUNT(*)
               FROM information_schema.TABLES
               WHERE TABLE_SCHEMA = DATABASE()
                 AND TABLE_TYPE = 'BASE TABLE'
                 AND TABLE_NAME IN (
                     'charging_reservation', 'reservation_status_log',
                     'queue_record', 'queue_status_log',
                     'arrival_checkin', 'parking_occupancy',
                     'station_notice', 'notice_revision',
                     'notice_recipient', 'notification_record'
                 )
           ) = 0
           THEN 'A 对象未安装：07_verify.sql 只读，不会建对象。前置齐全时执行 sql/A/00_install_a.sql。'
           ELSE 'A 对象已安装：若 07_verify 仍 FAIL，请核对种子数据或具体约束错误。'
       END AS result;
