-- D 模块最终只读综合验收：④ 用户与会员运营 + ⑤ 结算与对账
-- 适用环境：MySQL 8.0.46 / charging_platform / +08:00。
-- 前置：D 结构、B-FORMAL-v1 和 D ⑤正式结算数据均已提交。
-- 安全：只执行 SELECT、只读过程和信息模式检查，不创建、修改或删除对象与数据。
-- 运行：python -m app.run_sql --file sql/D/00_verify_d_all.sql

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT '=== D environment ===' AS section;
SELECT
    VERSION() AS mysql_version,
    DATABASE() AS database_name,
    @@session.time_zone AS session_time_zone,
    IF(VERSION() LIKE '8.0.%', 'PASS', 'CHECK') AS version_result,
    IF(DATABASE() = 'charging_platform', 'PASS', 'FAIL') AS database_result,
    IF(@@session.time_zone = '+08:00', 'PASS', 'FAIL') AS time_zone_result;

SELECT '=== D 04 core structure ===' AS section;
SOURCE sql/D/04_membership_verify.sql;

SELECT '=== D 04 cross-module structure ===' AS section;
SOURCE sql/D/04_membership_integration_verify.sql;

SELECT '=== D 04 cross-module formal data ===' AS section;
SOURCE sql/D/04_membership_integration_data_verify.sql;

SELECT '=== D 04 views ===' AS section;
SOURCE sql/D/04_membership_views_verify.sql;

SELECT '=== D 04 promotion quote procedure ===' AS section;
SOURCE sql/D/04_membership_procedure_verify.sql;

SELECT '=== D 05 settlement structure ===' AS section;
SOURCE sql/D/05_settlement_verify.sql;

SELECT '=== D 05 settlement views ===' AS section;
SOURCE sql/D/05_settlement_views_verify.sql;

SELECT '=== D 05 settlement procedure metadata ===' AS section;
SELECT
    'DFP01 settlement_procedure' AS check_item,
    COUNT(*) AS actual_value,
    1 AS expected_value,
    IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE()
  AND ROUTINE_TYPE = 'PROCEDURE'
  AND ROUTINE_NAME = 'sp_generate_settlement_statement'
  AND SECURITY_TYPE = 'INVOKER'
  AND SQL_DATA_ACCESS = 'MODIFIES SQL DATA';

SELECT
    'DFP02 settlement_parameter_count' AS check_item,
    COUNT(*) AS actual_value,
    10 AS expected_value,
    IF(COUNT(*) = 10, 'PASS', 'FAIL') AS result
FROM information_schema.PARAMETERS
WHERE SPECIFIC_SCHEMA = DATABASE()
  AND SPECIFIC_NAME = 'sp_generate_settlement_statement';

SELECT '=== D 05 formal settlement data ===' AS section;
SOURCE sql/D/05_settlement_seed_verify.sql;

SELECT '=== D 17-table data coverage ===' AS section;
WITH d_table_count AS (
    SELECT 'membership_level' AS table_name, COUNT(*) AS row_count FROM membership_level
    UNION ALL SELECT 'user', COUNT(*) FROM `user`
    UNION ALL SELECT 'vehicle', COUNT(*) FROM vehicle
    UNION ALL SELECT 'membership_record', COUNT(*) FROM membership_record
    UNION ALL SELECT 'enterprise_customer', COUNT(*) FROM enterprise_customer
    UNION ALL SELECT 'fleet', COUNT(*) FROM fleet
    UNION ALL SELECT 'fleet_vehicle', COUNT(*) FROM fleet_vehicle
    UNION ALL SELECT 'fleet_quota_record', COUNT(*) FROM fleet_quota_record
    UNION ALL SELECT 'promotion', COUNT(*) FROM promotion
    UNION ALL SELECT 'promotion_station', COUNT(*) FROM promotion_station
    UNION ALL SELECT 'coupon', COUNT(*) FROM coupon
    UNION ALL SELECT 'coupon_redemption', COUNT(*) FROM coupon_redemption
    UNION ALL SELECT 'settlement_statement', COUNT(*) FROM settlement_statement
    UNION ALL SELECT 'settlement_detail', COUNT(*) FROM settlement_detail
    UNION ALL SELECT 'reconciliation_difference', COUNT(*) FROM reconciliation_difference
    UNION ALL SELECT 'reconciliation_confirmation', COUNT(*) FROM reconciliation_confirmation
    UNION ALL SELECT 'invoice_record', COUNT(*) FROM invoice_record
)
SELECT
    table_name,
    row_count,
    20 AS minimum_count,
    IF(row_count >= 20, 'PASS', 'FAIL') AS result
FROM d_table_count
ORDER BY table_name;

SELECT '=== D final invariant summary ===' AS section;
WITH d_table_count AS (
    SELECT COUNT(*) AS row_count FROM membership_level
    UNION ALL SELECT COUNT(*) FROM `user`
    UNION ALL SELECT COUNT(*) FROM vehicle
    UNION ALL SELECT COUNT(*) FROM membership_record
    UNION ALL SELECT COUNT(*) FROM enterprise_customer
    UNION ALL SELECT COUNT(*) FROM fleet
    UNION ALL SELECT COUNT(*) FROM fleet_vehicle
    UNION ALL SELECT COUNT(*) FROM fleet_quota_record
    UNION ALL SELECT COUNT(*) FROM promotion
    UNION ALL SELECT COUNT(*) FROM promotion_station
    UNION ALL SELECT COUNT(*) FROM coupon
    UNION ALL SELECT COUNT(*) FROM coupon_redemption
    UNION ALL SELECT COUNT(*) FROM settlement_statement
    UNION ALL SELECT COUNT(*) FROM settlement_detail
    UNION ALL SELECT COUNT(*) FROM reconciliation_difference
    UNION ALL SELECT COUNT(*) FROM reconciliation_confirmation
    UNION ALL SELECT COUNT(*) FROM invoice_record
), ranked_membership AS (
    SELECT
        mr.user_id,
        mr.level_id,
        ROW_NUMBER() OVER (
            PARTITION BY mr.user_id
            ORDER BY mr.effective_at DESC, mr.membership_record_id DESC
        ) AS row_num
    FROM membership_record AS mr
), final_check AS (
    SELECT
        'DF01 D table count' AS check_item,
        (
            SELECT COUNT(*)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_TYPE = 'BASE TABLE'
              AND TABLE_NAME IN (
                  'membership_level', 'user', 'vehicle', 'membership_record',
                  'enterprise_customer', 'fleet', 'fleet_vehicle',
                  'fleet_quota_record', 'promotion', 'promotion_station',
                  'coupon', 'coupon_redemption', 'settlement_statement',
                  'settlement_detail', 'reconciliation_difference',
                  'reconciliation_confirmation', 'invoice_record'
              )
        ) AS actual_value,
        17 AS expected_value
    UNION ALL
    SELECT
        'DF02 D view count',
        (
            SELECT COUNT(*)
            FROM information_schema.VIEWS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN (
                  'v_user_membership_profile', 'v_fleet_active_vehicle',
                  'v_active_global_promotion',
                  'v_settlement_statement_summary',
                  'v_settlement_order_detail', 'v_reconciliation_pending'
              )
        ),
        6
    UNION ALL
    SELECT
        'DF03 D procedure count',
        (
            SELECT COUNT(*)
            FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA = DATABASE()
              AND ROUTINE_TYPE = 'PROCEDURE'
              AND ROUTINE_NAME IN (
                  'sp_calculate_promotion_quote',
                  'sp_generate_settlement_statement'
              )
        ),
        2
    UNION ALL
    SELECT
        'DF04 D tables below 20 rows',
        (SELECT SUM(row_count < 20) FROM d_table_count),
        0
    UNION ALL
    SELECT
        'DF05 invalid engine or collation',
        (
            SELECT COUNT(*)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN (
                  'membership_level', 'user', 'vehicle', 'membership_record',
                  'enterprise_customer', 'fleet', 'fleet_vehicle',
                  'fleet_quota_record', 'promotion', 'promotion_station',
                  'coupon', 'coupon_redemption', 'settlement_statement',
                  'settlement_detail', 'reconciliation_difference',
                  'reconciliation_confirmation', 'invoice_record'
              )
              AND (ENGINE <> 'InnoDB' OR TABLE_COLLATION <> 'utf8mb4_0900_ai_ci')
        ),
        0
    UNION ALL
    SELECT
        'DF06 non-invoker D views',
        (
            SELECT COUNT(*)
            FROM information_schema.VIEWS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN (
                  'v_user_membership_profile', 'v_fleet_active_vehicle',
                  'v_active_global_promotion',
                  'v_settlement_statement_summary',
                  'v_settlement_order_detail', 'v_reconciliation_pending'
              )
              AND SECURITY_TYPE <> 'INVOKER'
        ),
        0
    UNION ALL
    SELECT
        'DF07 sensitive column exposure',
        (
            SELECT COUNT(*)
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN (
                  'v_user_membership_profile', 'v_fleet_active_vehicle',
                  'v_active_global_promotion',
                  'v_settlement_statement_summary',
                  'v_settlement_order_detail', 'v_reconciliation_pending'
              )
              AND COLUMN_NAME IN (
                  'phone_ciphertext', 'phone_hash',
                  'plate_ciphertext', 'plate_hash',
                  'credit_code_ciphertext', 'credit_code_hash',
                  'contact_phone_ciphertext', 'tax_number_ciphertext',
                  'confirmer_name'
              )
        ),
        0
    UNION ALL
    SELECT
        'DF08 duplicate active fleet vehicle',
        (
            SELECT COUNT(*)
            FROM (
                SELECT vehicle_id
                FROM fleet_vehicle
                WHERE status = 'ACTIVE'
                GROUP BY vehicle_id
                HAVING COUNT(*) > 1
            ) AS duplicate_vehicle
        ),
        0
    UNION ALL
    SELECT
        'DF09 membership level mismatch',
        (
            SELECT COUNT(*)
            FROM `user` AS u
            LEFT JOIN ranked_membership AS rm
              ON rm.user_id = u.user_id
             AND rm.row_num = 1
            WHERE (u.level_id IS NULL AND rm.level_id IS NOT NULL)
               OR (u.level_id IS NOT NULL AND (rm.level_id IS NULL OR u.level_id <> rm.level_id))
        ),
        0
    UNION ALL
    SELECT
        'DF10 invalid net invoice amount',
        (
            SELECT COUNT(*)
            FROM v_settlement_statement_summary
            WHERE net_invoice_amount < 0
               OR net_invoice_amount > GREATEST(payable_amount, 0)
        ),
        0
)
SELECT
    check_item,
    actual_value,
    expected_value,
    IF(actual_value = expected_value, 'PASS', 'FAIL') AS result
FROM final_check
ORDER BY check_item;

SELECT
    'D FINAL VERIFY COMPLETE: all displayed result columns should be PASS.'
        AS final_instruction;
