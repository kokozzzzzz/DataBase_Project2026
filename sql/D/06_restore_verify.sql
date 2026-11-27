-- D 模块恢复库只读验收
-- 必须连接隔离恢复库后执行；本脚本不含 USE charging_platform，避免误查原库。
-- 安全：只读取 information_schema 和当前库，不创建、修改或删除对象与数据。

SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT
    VERSION() AS mysql_version,
    DATABASE() AS restore_database,
    @@session.time_zone AS session_time_zone;

-- B01：恢复库不能是正式开发库，防止把恢复演练误当成原库验收。
SELECT
    'B01 isolated_restore_database' AS check_item,
    DATABASE() AS actual_value,
    'not charging_platform' AS expected_value,
    IF(DATABASE() IS NOT NULL AND DATABASE() <> 'charging_platform',
       'PASS', 'FAIL') AS result;

-- B02：D的17张业务表全部恢复。
SELECT
    'B02 D table count' AS check_item,
    COUNT(*) AS actual_value,
    17 AS expected_value,
    IF(COUNT(*) = 17, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'membership_level', 'user', 'vehicle', 'membership_record',
      'enterprise_customer', 'fleet', 'fleet_vehicle', 'fleet_quota_record',
      'promotion', 'promotion_station', 'coupon', 'coupon_redemption',
      'settlement_statement', 'settlement_detail',
      'reconciliation_difference', 'reconciliation_confirmation',
      'invoice_record'
  );

-- B03：D的6个视图和2个过程全部恢复。
SELECT
    check_item,
    actual_value,
    expected_value,
    IF(actual_value = expected_value, 'PASS', 'FAIL') AS result
FROM (
    SELECT
        'B03 D view count' AS check_item,
        COUNT(*) AS actual_value,
        6 AS expected_value
    FROM information_schema.VIEWS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME IN (
          'v_user_membership_profile', 'v_fleet_active_vehicle',
          'v_active_global_promotion', 'v_settlement_statement_summary',
          'v_settlement_order_detail', 'v_reconciliation_pending'
      )
    UNION ALL
    SELECT
        'B03 D procedure count',
        COUNT(*),
        2
    FROM information_schema.ROUTINES
    WHERE ROUTINE_SCHEMA = DATABASE()
      AND ROUTINE_TYPE = 'PROCEDURE'
      AND ROUTINE_NAME IN (
          'sp_calculate_promotion_quote',
          'sp_generate_settlement_statement'
      )
) AS object_count;

-- B04：17张D表均应至少恢复20行正式测试数据。
WITH d_table_counts AS (
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
    'B04 D tables below 20 rows' AS check_item,
    SUM(row_count < 20) AS actual_value,
    0 AS expected_value,
    IF(SUM(row_count < 20) = 0, 'PASS', 'FAIL') AS result
FROM d_table_counts;

-- B05：恢复后的核心财务与运营不变量仍成立。
SELECT
    check_item,
    actual_value,
    expected_value,
    IF(actual_value = expected_value, 'PASS', 'FAIL') AS result
FROM (
    SELECT
        'B05 duplicate active fleet vehicle' AS check_item,
        COUNT(*) AS actual_value,
        0 AS expected_value
    FROM (
        SELECT vehicle_id
        FROM fleet_vehicle
        WHERE status = 'ACTIVE'
        GROUP BY vehicle_id
        HAVING COUNT(*) > 1
    ) AS duplicate_vehicle
    UNION ALL
    SELECT
        'B05 membership level mismatch',
        COUNT(*),
        0
    FROM `user` AS u
    JOIN membership_record AS mr
      ON mr.user_id = u.user_id
    LEFT JOIN membership_record AS newer
      ON newer.user_id = mr.user_id
     AND (
         newer.effective_at > mr.effective_at
         OR (newer.effective_at = mr.effective_at
             AND newer.membership_record_id > mr.membership_record_id)
     )
    WHERE newer.membership_record_id IS NULL
      AND NOT (u.level_id <=> mr.level_id)
    UNION ALL
    SELECT
        'B05 invalid net invoice amount',
        COUNT(*),
        0
    FROM v_settlement_statement_summary
    WHERE net_invoice_amount < 0
       OR net_invoice_amount > GREATEST(payable_amount, 0)
) AS invariant_check;

SELECT
    'RESTORE VERIFY COMPLETE: B01～B05 should all be PASS.'
        AS final_instruction;
