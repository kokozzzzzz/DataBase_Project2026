-- ④ 用户与会员运营：核心业务视图验收
-- 本脚本只读，不修改视图或表数据。

USE charging_platform;
SET NAMES utf8mb4;

-- C01：三个预期视图必须全部存在。
SELECT
    'membership_view_count' AS check_item,
    COUNT(*) AS actual_value,
    3 AS expected_value,
    IF(COUNT(*) = 3, 'PASS', 'FAIL') AS result
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_user_membership_profile',
      'v_fleet_active_vehicle',
      'v_active_global_promotion'
  );

-- C02：视图不得暴露手机号、车牌和企业信用代码的密文或摘要。
SELECT
    'sensitive_column_exposure' AS check_item,
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

-- C03：基于当前种子数据检查视图行数。
SELECT
    'v_user_membership_profile' AS view_name,
    COUNT(*) AS actual_count,
    20 AS expected_count,
    IF(COUNT(*) = 20, 'PASS', 'FAIL') AS result
FROM v_user_membership_profile
UNION ALL
SELECT
    'v_fleet_active_vehicle',
    COUNT(*),
    20,
    IF(COUNT(*) = 20, 'PASS', 'FAIL')
FROM v_fleet_active_vehicle
UNION ALL
SELECT
    'v_active_global_promotion',
    COUNT(*),
    20,
    IF(COUNT(*) = 20, 'PASS', 'FAIL')
FROM v_active_global_promotion;

-- C04：每个视图展示少量样例，便于人工检查字段含义。
SELECT *
FROM v_user_membership_profile
ORDER BY user_id
LIMIT 5;

SELECT *
FROM v_fleet_active_vehicle
ORDER BY fleet_id, vehicle_id
LIMIT 5;

SELECT *
FROM v_active_global_promotion
ORDER BY promotion_id
LIMIT 5;
