-- 全组只读综合验收：A/B/C/D 结构、D 结算对象、交易输入和正式结算数据
--
-- 前提：已执行 sql/00_install_all.sql 和所需模块种子。
-- D 结算数据验收还要求先提交 B-FORMAL-v1，再使用 --commit 执行
-- sql/D/05_settlement_seed.sql；未生成正式数据时 SD01～SD07 将按设计显示 FAIL。
-- 本脚本只查询，不创建、修改或删除任何对象和数据。
--
-- 运行方式（必须在仓库根目录，SOURCE 路径按客户端当前目录解析）：
--   mysql -h127.0.0.1 -P3306 -uroot -p --default-character-set=utf8mb4 < sql/00_verify_all.sql
-- 或在 mysql 客户端中：
--   SOURCE sql/00_verify_all.sql;
--
-- 说明：不在这里调用 sql/D/04_membership_final_verify.sql。
-- 该脚本按“仅 D 核心种子”校准了 user/vehicle/promotion 行数和会员等级一致性；
-- 执行 B 固定测试集后行数会超过 20，它会按设计报 FAIL。D 核心阶段可单独执行。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT '=== A 06/08 structure and data ===' AS section;
SOURCE sql/A/07_verify.sql;

SELECT '=== B 01/02 structure overview ===' AS section;
SOURCE sql/B/04_verify_structure.sql;

SELECT '=== D 04 core structure ===' AS section;
SOURCE sql/D/04_membership_verify.sql;

SELECT '=== D 04 cross-module structure ===' AS section;
SOURCE sql/D/04_membership_integration_verify.sql;

SELECT '=== D 04 views and procedure ===' AS section;
SOURCE sql/D/04_membership_views_verify.sql;
SOURCE sql/D/04_membership_procedure_verify.sql;

SELECT '=== D 05 settlement structure ===' AS section;
SOURCE sql/D/05_settlement_verify.sql;
SOURCE sql/D/05_settlement_views_verify.sql;

SELECT 'D settlement procedure' AS item,
       COUNT(*) AS actual_value,
       1 AS expected_value,
       IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE()
  AND ROUTINE_TYPE = 'PROCEDURE'
  AND ROUTINE_NAME = 'sp_generate_settlement_statement'
  AND SECURITY_TYPE = 'INVOKER'
  AND SQL_DATA_ACCESS = 'MODIFIES SQL DATA';

SELECT '=== D 05 settlement data readiness ===' AS section;
SOURCE sql/D/05_settlement_seed_preflight.sql;

SELECT '=== D 05 formal settlement data ===' AS section;
SOURCE sql/D/05_settlement_seed_verify.sql;

SELECT '=== C 03/07 structure and integrity ===' AS section;
SOURCE sql/C/07_verify.sql;

SELECT '=== summary ===' AS section;
SELECT 'A tables' AS item, COUNT(*) AS actual_value, 10 AS expected_value,
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
  )
UNION ALL
SELECT 'A views', COUNT(*), 8, IF(COUNT(*) = 8, 'PASS', 'FAIL')
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'v\_a\_%'
UNION ALL
SELECT 'A procedures', COUNT(*), 14, IF(COUNT(*) = 14, 'PASS', 'FAIL')
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_TYPE = 'PROCEDURE'
  AND ROUTINE_NAME IN (
      'sp_create_reservation', 'sp_cancel_reservation',
      'sp_reschedule_reservation', 'sp_check_in_reservation',
      'sp_join_queue', 'sp_call_next_queue', 'sp_check_in_queue',
      'sp_release_parking_space', 'sp_consume_admission',
      'sp_expire_overdue_admissions', 'sp_publish_notice',
      'sp_withdraw_notice', 'sp_update_notification_status',
      'sp_expire_notices'
  )
UNION ALL
SELECT 'A triggers', COUNT(*), 13, IF(COUNT(*) = 13, 'PASS', 'FAIL')
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME LIKE 'a\_%'
UNION ALL
SELECT 'D settlement tables', COUNT(*), 5, IF(COUNT(*) = 5, 'PASS', 'FAIL')
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'settlement_statement', 'settlement_detail',
      'reconciliation_difference', 'reconciliation_confirmation',
      'invoice_record'
  );
