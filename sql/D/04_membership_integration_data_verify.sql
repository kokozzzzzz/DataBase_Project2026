-- ④ 用户与会员运营：跨模块正式数据只读验收
-- 前置：B-FORMAL-v1 已使用 --commit 提交。
-- 安全：本脚本只执行 SELECT，不创建、修改或删除任何对象和业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- DI01：三张跨模块表均达到课程设计建议的至少 20 行。
WITH table_count AS (
    SELECT 'promotion_station' AS table_name, COUNT(*) AS actual_count
    FROM promotion_station
    UNION ALL
    SELECT 'coupon', COUNT(*) FROM coupon
    UNION ALL
    SELECT 'coupon_redemption', COUNT(*) FROM coupon_redemption
)
SELECT
    table_name,
    actual_count,
    20 AS minimum_count,
    IF(actual_count >= 20, 'PASS', 'FAIL') AS result
FROM table_count
ORDER BY table_name;

-- DI02：B-FORMAL-v1 的 SELECTED 活动准确关联 20 个正式场站。
SELECT
    'DI02 formal_promotion_station_count' AS check_item,
    COUNT(*) AS actual_value,
    20 AS expected_value,
    IF(COUNT(*) = 20, 'PASS', 'FAIL') AS result
FROM promotion_station AS ps
JOIN promotion AS p
  ON p.promotion_id = ps.promotion_id
JOIN station AS s
  ON s.station_id = ps.station_id
WHERE p.promotion_id = 7200000
  AND p.promotion_name = 'B-FORMAL-v1'
  AND p.applicability_scope = 'SELECTED'
  AND s.station_id BETWEEN 7200001 AND 7200020;

-- DI03：20 张固定券均已锁定到订单并完成核销。
SELECT
    'DI03 formal_used_coupon_count' AS check_item,
    COUNT(*) AS actual_value,
    20 AS expected_value,
    IF(COUNT(*) = 20, 'PASS', 'FAIL') AS result
FROM coupon
WHERE coupon_code LIKE 'B-FORMAL-v1-%'
  AND promotion_id = 7200000
  AND status = 'USED'
  AND locked_order_id IS NOT NULL
  AND locked_at IS NOT NULL
  AND used_at IS NOT NULL;

-- DI04：固定券、订单用户、适用场站、优惠金额和核销时间全部一致。
SELECT
    'DI04 invalid_coupon_redemption_link' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM coupon AS c
JOIN coupon_redemption AS cr
  ON cr.coupon_id = c.coupon_id
JOIN charging_order AS o
  ON o.order_id = cr.order_id
JOIN charging_gun AS g
  ON g.gun_id = o.gun_id
LEFT JOIN promotion_station AS ps
  ON ps.promotion_id = c.promotion_id
 AND ps.station_id = g.station_id
WHERE c.coupon_code LIKE 'B-FORMAL-v1-%'
  AND (
      c.status <> 'USED'
      OR c.user_id <> o.user_id
      OR c.locked_order_id <> cr.order_id
      OR c.used_at <> cr.redeemed_at
      OR cr.discount_amount <> o.discount_amount
      OR ps.promotion_id IS NULL
  );

-- DI05：固定集应有 20 条不重复核销，优惠总额为 40.00 元。
SELECT
    'DI05 redemption_count_and_amount' AS check_item,
    COUNT(*) AS redemption_count,
    COUNT(DISTINCT cr.coupon_id) AS distinct_coupon_count,
    COUNT(DISTINCT cr.order_id) AS distinct_order_count,
    SUM(cr.discount_amount) AS total_discount_amount,
    IF(
        COUNT(*) = 20
        AND COUNT(DISTINCT cr.coupon_id) = 20
        AND COUNT(DISTINCT cr.order_id) = 20
        AND SUM(cr.discount_amount) = 40.00,
        'PASS',
        'FAIL'
    ) AS result
FROM coupon_redemption AS cr
JOIN coupon AS c
  ON c.coupon_id = cr.coupon_id
WHERE c.coupon_code LIKE 'B-FORMAL-v1-%';

-- DI06：三张表的固定联调数据摘要。
SELECT
    (SELECT COUNT(*)
       FROM promotion_station
      WHERE promotion_id = 7200000) AS formal_station_links,
    (SELECT COUNT(*)
       FROM coupon
      WHERE coupon_code LIKE 'B-FORMAL-v1-%') AS formal_coupons,
    (SELECT COUNT(*)
       FROM coupon_redemption AS cr
       JOIN coupon AS c ON c.coupon_id = cr.coupon_id
      WHERE c.coupon_code LIKE 'B-FORMAL-v1-%') AS formal_redemptions;
