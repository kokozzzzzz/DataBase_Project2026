-- ④ 用户与会员运营：独立核心部分最终回归检查
-- 适用环境：MySQL 8.0.46。
-- 全部为只读检查，不修改数据库对象或业务数据。

USE charging_platform;
SET NAMES utf8mb4;

-- F01：9 张核心表全部存在。
SELECT
    'F01 core_table_count' AS check_item,
    COUNT(*) AS actual_value,
    9 AS expected_value,
    IF(COUNT(*) = 9, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  );

-- F02：当前测试环境中 9 张核心表均应有 20 条数据。
SELECT
    table_name,
    row_count,
    20 AS expected_count,
    IF(row_count = 20, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'membership_level' AS table_name, COUNT(*) AS row_count FROM membership_level
    UNION ALL SELECT 'user', COUNT(*) FROM `user`
    UNION ALL SELECT 'vehicle', COUNT(*) FROM vehicle
    UNION ALL SELECT 'membership_record', COUNT(*) FROM membership_record
    UNION ALL SELECT 'promotion', COUNT(*) FROM promotion
    UNION ALL SELECT 'enterprise_customer', COUNT(*) FROM enterprise_customer
    UNION ALL SELECT 'fleet', COUNT(*) FROM fleet
    UNION ALL SELECT 'fleet_vehicle', COUNT(*) FROM fleet_vehicle
    UNION ALL SELECT 'fleet_quota_record', COUNT(*) FROM fleet_quota_record
) AS core_counts
ORDER BY table_name;

-- F03：主键、外键、唯一约束和 CHECK 约束数量保持不变。
SELECT
    CONSTRAINT_TYPE AS constraint_type,
    COUNT(*) AS actual_count,
    CASE CONSTRAINT_TYPE
        WHEN 'PRIMARY KEY' THEN 9
        WHEN 'FOREIGN KEY' THEN 10
        WHEN 'UNIQUE' THEN 7
        WHEN 'CHECK' THEN 28
    END AS expected_count,
    IF(
        COUNT(*) = CASE CONSTRAINT_TYPE
            WHEN 'PRIMARY KEY' THEN 9
            WHEN 'FOREIGN KEY' THEN 10
            WHEN 'UNIQUE' THEN 7
            WHEN 'CHECK' THEN 28
        END,
        'PASS',
        'FAIL'
    ) AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  )
GROUP BY CONSTRAINT_TYPE
ORDER BY FIELD(
    CONSTRAINT_TYPE,
    'PRIMARY KEY',
    'FOREIGN KEY',
    'UNIQUE',
    'CHECK'
);

-- F04：3 个业务视图和 1 个只读存储过程全部存在。
SELECT
    'F04 view_count' AS check_item,
    COUNT(*) AS actual_value,
    3 AS expected_value,
    IF(COUNT(*) = 3, 'PASS', 'FAIL') AS result
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_user_membership_profile',
      'v_fleet_active_vehicle',
      'v_active_global_promotion'
  )
UNION ALL
SELECT
    'F04 procedure_count',
    COUNT(*),
    1,
    IF(COUNT(*) = 1, 'PASS', 'FAIL')
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'charging_platform'
  AND ROUTINE_NAME = 'sp_calculate_promotion_quote'
  AND ROUTINE_TYPE = 'PROCEDURE'
  AND SQL_DATA_ACCESS = 'READS SQL DATA'
  AND SECURITY_TYPE = 'INVOKER';

-- F05：同一车辆不得同时存在多条 ACTIVE 车队关系。
SELECT
    'F05 duplicate_active_fleet_vehicle' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT vehicle_id
    FROM fleet_vehicle
    WHERE status = 'ACTIVE'
    GROUP BY vehicle_id
    HAVING COUNT(*) > 1
) AS duplicate_active_relation;

-- F06：用户当前等级必须与最新一条会员历史一致。
WITH ranked_membership AS (
    SELECT
        mr.user_id,
        mr.level_id,
        ROW_NUMBER() OVER (
            PARTITION BY mr.user_id
            ORDER BY mr.effective_at DESC, mr.membership_record_id DESC
        ) AS row_num
    FROM membership_record AS mr
)
SELECT
    'F06 membership_level_mismatch' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM `user` AS u
LEFT JOIN ranked_membership AS rm
    ON rm.user_id = u.user_id
   AND rm.row_num = 1
WHERE rm.user_id IS NULL
   OR rm.level_id <> u.level_id;

-- F07：业务视图不得暴露密文或检索摘要字段。
SELECT
    'F07 sensitive_column_exposure' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_user_membership_profile',
      'v_fleet_active_vehicle',
      'v_active_global_promotion'
  )
  AND COLUMN_NAME IN (
      'phone_ciphertext',
      'phone_hash',
      'plate_ciphertext',
      'plate_hash',
      'credit_code_ciphertext',
      'credit_code_hash',
      'contact_phone_ciphertext'
  );

-- F08：三个视图在当前测试数据和有效期下均应返回 20 行。
SELECT
    'F08 user_profile_view_rows' AS check_item,
    COUNT(*) AS actual_value,
    20 AS expected_value,
    IF(COUNT(*) = 20, 'PASS', 'FAIL') AS result
FROM v_user_membership_profile
UNION ALL
SELECT
    'F08 active_fleet_view_rows',
    COUNT(*),
    20,
    IF(COUNT(*) = 20, 'PASS', 'FAIL')
FROM v_fleet_active_vehicle
UNION ALL
SELECT
    'F08 active_promotion_view_rows',
    COUNT(*),
    20,
    IF(COUNT(*) = 20, 'PASS', 'FAIL')
FROM v_active_global_promotion;
