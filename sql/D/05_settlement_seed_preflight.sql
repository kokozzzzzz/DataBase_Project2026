-- ⑤ 结算与对账：测试数据依赖检查
-- 用途：确认数据库中是否已有足够的 B 订单、分段费用、成功支付和退款数据。
-- 本脚本只读，不创建、修改或删除任何数据库对象和业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT VERSION() AS mysql_version,
       DATABASE() AS database_name,
       @@session.time_zone AS session_time_zone;

-- DP01：⑤五张表当前行数。进入首次种子阶段前应全部为 0。
SELECT 'invoice_record' AS table_name, COUNT(*) AS row_count FROM invoice_record
UNION ALL SELECT 'reconciliation_confirmation', COUNT(*) FROM reconciliation_confirmation
UNION ALL SELECT 'reconciliation_difference', COUNT(*) FROM reconciliation_difference
UNION ALL SELECT 'settlement_detail', COUNT(*) FROM settlement_detail
UNION ALL SELECT 'settlement_statement', COUNT(*) FROM settlement_statement
ORDER BY table_name;

-- DP02：B 交易事实的当前可用规模。
SELECT
    (SELECT COUNT(*) FROM `operator`) AS operator_count,
    (SELECT COUNT(*) FROM station) AS station_count,
    (SELECT COUNT(*) FROM charging_order) AS order_count,
    (SELECT COUNT(*) FROM charging_order WHERE state = 'BILLED') AS billed_order_count,
    (SELECT COUNT(*) FROM order_fee_detail) AS fee_segment_count,
    (SELECT COUNT(*) FROM payment_record WHERE status = 'SUCCESS') AS success_payment_count,
    (SELECT COUNT(*) FROM refund_record) AS refund_count;

-- DP03：可直接生成基础结算明细的订单数量。
-- 条件：已出账、成功支付足额、至少一条费用分段、分段金额不超过订单原价。
WITH payment_summary AS (
    SELECT
        order_id,
        SUM(amount) AS paid_amount
    FROM payment_record
    WHERE status = 'SUCCESS'
    GROUP BY order_id
), fee_summary AS (
    SELECT
        order_id,
        COUNT(*) AS segment_count,
        SUM(energy_amount) AS electricity_fee,
        SUM(service_amount) AS service_fee
    FROM order_fee_detail
    GROUP BY order_id
)
SELECT
    'DP03 eligible_settlement_order_count' AS check_item,
    COUNT(*) AS actual_value,
    20 AS recommended_value,
    IF(COUNT(*) >= 20, 'PASS', 'INSUFFICIENT') AS result
FROM charging_order o
JOIN payment_summary p
  ON p.order_id = o.order_id
JOIN fee_summary f
  ON f.order_id = o.order_id
WHERE o.state = 'BILLED'
  AND o.gross_amount IS NOT NULL
  AND o.total_kwh IS NOT NULL
  AND p.paid_amount >= o.gross_amount - o.discount_amount
  AND f.segment_count > 0
  AND f.electricity_fee + f.service_fee <= o.gross_amount;

-- DP04：按运营商、场站统计可结算订单，便于规划结算单和账期。
WITH payment_summary AS (
    SELECT
        order_id,
        SUM(amount) AS paid_amount,
        MIN(occurred_at) AS first_payment_at,
        MAX(occurred_at) AS last_payment_at
    FROM payment_record
    WHERE status = 'SUCCESS'
    GROUP BY order_id
), fee_summary AS (
    SELECT
        order_id,
        COUNT(*) AS segment_count,
        SUM(energy_amount) AS electricity_fee,
        SUM(service_amount) AS service_fee
    FROM order_fee_detail
    GROUP BY order_id
)
SELECT
    s.operator_id,
    g.station_id,
    COUNT(*) AS eligible_order_count,
    MIN(p.first_payment_at) AS earliest_payment_at,
    MAX(p.last_payment_at) AS latest_payment_at
FROM charging_order o
JOIN charging_gun g
  ON g.gun_id = o.gun_id
JOIN station s
  ON s.station_id = g.station_id
JOIN payment_summary p
  ON p.order_id = o.order_id
JOIN fee_summary f
  ON f.order_id = o.order_id
WHERE o.state = 'BILLED'
  AND o.gross_amount IS NOT NULL
  AND o.total_kwh IS NOT NULL
  AND p.paid_amount >= o.gross_amount - o.discount_amount
  AND f.segment_count > 0
  AND f.electricity_fee + f.service_fee <= o.gross_amount
GROUP BY s.operator_id, g.station_id
ORDER BY s.operator_id, g.station_id;

-- DP05：最多列出 30 笔候选订单及其资金和费用分段情况。
WITH payment_summary AS (
    SELECT
        order_id,
        SUM(amount) AS paid_amount,
        MIN(occurred_at) AS first_payment_at,
        MAX(occurred_at) AS last_payment_at
    FROM payment_record
    WHERE status = 'SUCCESS'
    GROUP BY order_id
), refund_summary AS (
    SELECT
        p.order_id,
        COUNT(r.refund_id) AS refund_count,
        COALESCE(SUM(r.amount), 0.00) AS refunded_amount
    FROM payment_record p
    JOIN refund_record r
      ON r.payment_id = p.payment_id
    GROUP BY p.order_id
), fee_summary AS (
    SELECT
        order_id,
        COUNT(*) AS segment_count,
        SUM(energy_amount) AS electricity_fee,
        SUM(service_amount) AS service_fee
    FROM order_fee_detail
    GROUP BY order_id
)
SELECT
    o.order_id,
    s.operator_id,
    g.station_id,
    o.total_kwh,
    o.gross_amount,
    o.discount_amount,
    o.gross_amount - o.discount_amount AS order_payable,
    p.paid_amount,
    COALESCE(r.refund_count, 0) AS refund_count,
    COALESCE(r.refunded_amount, 0.00) AS refunded_amount,
    f.segment_count,
    f.electricity_fee,
    f.service_fee,
    o.gross_amount - f.electricity_fee - f.service_fee AS minimum_fee_adjustment,
    p.first_payment_at,
    p.last_payment_at
FROM charging_order o
JOIN charging_gun g
  ON g.gun_id = o.gun_id
JOIN station s
  ON s.station_id = g.station_id
JOIN payment_summary p
  ON p.order_id = o.order_id
JOIN fee_summary f
  ON f.order_id = o.order_id
LEFT JOIN refund_summary r
  ON r.order_id = o.order_id
WHERE o.state = 'BILLED'
  AND o.gross_amount IS NOT NULL
  AND o.total_kwh IS NOT NULL
  AND p.paid_amount >= o.gross_amount - o.discount_amount
  AND f.segment_count > 0
  AND f.electricity_fee + f.service_fee <= o.gross_amount
ORDER BY p.last_payment_at, o.order_id
LIMIT 30;

-- DP06：退款流水可用于构造跨期 REFUND_ADJUSTMENT 的数量。
SELECT
    'DP06 available_refund_count' AS check_item,
    COUNT(*) AS actual_value,
    1 AS recommended_value,
    IF(COUNT(*) >= 1, 'PASS', 'INSUFFICIENT') AS result
FROM refund_record r
JOIN payment_record p
  ON p.payment_id = r.payment_id
WHERE p.status = 'SUCCESS';
