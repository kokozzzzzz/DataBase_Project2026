-- ④ 用户与会员运营：优惠试算存储过程验收
-- 本脚本只读，不修改表数据。

USE charging_platform;
SET NAMES utf8mb4;

-- C01：过程必须存在，并声明为 READS SQL DATA / INVOKER。
SELECT
    'promotion_quote_procedure' AS check_item,
    COUNT(*) AS actual_value,
    1 AS expected_value,
    IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'charging_platform'
  AND ROUTINE_NAME = 'sp_calculate_promotion_quote'
  AND ROUTINE_TYPE = 'PROCEDURE'
  AND SQL_DATA_ACCESS = 'READS SQL DATA'
  AND SECURITY_TYPE = 'INVOKER';

-- C02：固定减免。活动 40019 对 100 元订单应优惠 24 元，实付 76 元。
CALL sp_calculate_promotion_quote(
    40019,
    100.00,
    '2026-11-19 12:00:00'
);

-- C03：百分比折扣。0.8020 表示实付 80.20 元，优惠 19.80 元。
CALL sp_calculate_promotion_quote(
    40002,
    100.00,
    '2026-11-19 12:00:00'
);

-- C04：未达到最低消费门槛时，不可用且优惠为 0。
CALL sp_calculate_promotion_quote(
    40001,
    10.00,
    '2026-11-19 12:00:00'
);

-- C05：过程执行前后核心表行数应保持不变。
SELECT
    'core_row_counts_after_procedure' AS check_item,
    (SELECT COUNT(*) FROM `user`) AS user_count,
    (SELECT COUNT(*) FROM vehicle) AS vehicle_count,
    (SELECT COUNT(*) FROM membership_record) AS membership_record_count,
    (SELECT COUNT(*) FROM promotion) AS promotion_count,
    (SELECT COUNT(*) FROM enterprise_customer) AS enterprise_count,
    (SELECT COUNT(*) FROM fleet) AS fleet_count,
    (SELECT COUNT(*) FROM fleet_vehicle) AS fleet_vehicle_count,
    (SELECT COUNT(*) FROM fleet_quota_record) AS quota_record_count;
