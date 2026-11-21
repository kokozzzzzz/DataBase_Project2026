-- A ⑥⑧ 只读结构与数据验收
-- 目标环境：MySQL 8.0.46。
-- 本脚本只查询，不修改任何数据或对象。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT
    'A01 MySQL version' AS check_name,
    VERSION() AS actual_value,
    IF(VERSION() LIKE '8.0.%', 'PASS', 'WARN') AS result;

SELECT
    'A02 database collation' AS check_name,
    @@collation_database AS actual_value,
    IF(@@collation_database = 'utf8mb4_0900_ai_ci', 'PASS', 'FAIL') AS result;

SELECT
    'A03 A table count' AS check_name,
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

SELECT
    'A04 A view count' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 8, 'PASS', 'FAIL') AS result
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME LIKE 'v\_a\_%';

SELECT
    'A05 A procedure count' AS check_name,
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

SELECT
    'A06 A trigger count' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 13, 'PASS', 'FAIL') AS result
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = DATABASE()
  AND TRIGGER_NAME LIKE 'a\_%';

SELECT 'A07 row counts' AS check_name, table_name, row_count,
       IF(row_count >= 20, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'charging_reservation' AS table_name, COUNT(*) AS row_count FROM charging_reservation
    UNION ALL SELECT 'reservation_status_log', COUNT(*) FROM reservation_status_log
    UNION ALL SELECT 'queue_record', COUNT(*) FROM queue_record
    UNION ALL SELECT 'queue_status_log', COUNT(*) FROM queue_status_log
    UNION ALL SELECT 'arrival_checkin', COUNT(*) FROM arrival_checkin
    UNION ALL SELECT 'parking_occupancy', COUNT(*) FROM parking_occupancy
    UNION ALL SELECT 'station_notice', COUNT(*) FROM station_notice
    UNION ALL SELECT 'notice_revision', COUNT(*) FROM notice_revision
    UNION ALL SELECT 'notice_recipient', COUNT(*) FROM notice_recipient
    UNION ALL SELECT 'notification_record', COUNT(*) FROM notification_record
) AS counts;

SELECT
    'A08 reservation overlap conflicts' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM charging_reservation AS a
JOIN charging_reservation AS b
    ON b.gun_id = a.gun_id
   AND b.reservation_id > a.reservation_id
   AND a.status IN ('BOOKED', 'CHECKED_IN')
   AND b.status IN ('BOOKED', 'CHECKED_IN')
   AND a.starts_at < b.ends_at
   AND b.starts_at < a.ends_at;

SELECT
    'A09 duplicate active space occupancy' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT parking_space_id
    FROM parking_occupancy
    WHERE released_at IS NULL
    GROUP BY parking_space_id
    HAVING COUNT(*) > 1
) AS duplicates;

SELECT
    'A10 duplicate active vehicle occupancy' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT vehicle_id
    FROM parking_occupancy
    WHERE released_at IS NULL
    GROUP BY vehicle_id
    HAVING COUNT(*) > 1
) AS duplicates;

SELECT
    'A11 duplicate active queue user' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT user_id
    FROM queue_record
    WHERE status IN ('WAITING', 'CALLED', 'CHECKED_IN')
    GROUP BY user_id
    HAVING COUNT(*) > 1
) AS duplicates;

SELECT
    'A12 invalid notification state' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM notification_record
WHERE (status IN ('PENDING', 'FAILED')) <> (sent_at IS NULL)
   OR (status = 'READ') <> (read_at IS NOT NULL)
   OR (status = 'READ' AND sent_at IS NULL)
   OR (status = 'FAILED') <> (failure_reason IS NOT NULL);

SELECT
    'A13 invalid reservation consume state' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM charging_reservation
WHERE (status = 'CONSUMED') <> (consumed_at IS NOT NULL AND consumed_order_id IS NOT NULL);

SELECT
    'A14 invalid queue consume state' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM queue_record
WHERE (status = 'CONSUMED') <> (consumed_at IS NOT NULL AND consumed_order_id IS NOT NULL);

SELECT
    'A15 A table engine/collation' AS check_name,
    COUNT(*) AS nonconforming_tables,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN (
      'charging_reservation', 'reservation_status_log',
      'queue_record', 'queue_status_log',
      'arrival_checkin', 'parking_occupancy',
      'station_notice', 'notice_revision',
      'notice_recipient', 'notification_record'
  )
  AND (ENGINE <> 'InnoDB' OR TABLE_COLLATION <> 'utf8mb4_0900_ai_ci');

SELECT
    'A16 A foreign key count' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) >= 20, 'PASS', 'FAIL') AS result
FROM information_schema.REFERENTIAL_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = DATABASE()
  AND TABLE_NAME IN (
      'charging_reservation', 'reservation_status_log',
      'queue_record', 'queue_status_log',
      'arrival_checkin', 'parking_occupancy',
      'station_notice', 'notice_revision',
      'notice_recipient', 'notification_record'
  );

SELECT
    'A17 A CHECK constraint count' AS check_name,
    COUNT(*) AS actual_value,
    IF(COUNT(*) >= 25, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = DATABASE()
  AND CONSTRAINT_TYPE = 'CHECK'
  AND TABLE_NAME IN (
      'charging_reservation', 'reservation_status_log',
      'queue_record', 'queue_status_log',
      'arrival_checkin', 'parking_occupancy',
      'station_notice', 'notice_revision',
      'notice_recipient', 'notification_record'
  );
