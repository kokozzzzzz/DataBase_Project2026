-- ④ 用户与会员运营：核心业务查询
-- 适用环境：MySQL 8.0.46。
-- 本脚本只执行 SELECT，不新增、修改或删除任何业务数据。

USE charging_platform;
SET NAMES utf8mb4;

-- Q01：用户会员档案。
-- 用于用户中心展示当前等级、余额和名下有效车辆数量。
SELECT
    u.user_id,
    u.real_name,
    u.real_name_status,
    u.user_status,
    ml.level_code,
    ml.level_name,
    u.balance,
    COUNT(v.vehicle_id) AS active_vehicle_count
FROM `user` AS u
JOIN membership_level AS ml
    ON ml.level_id = u.level_id
LEFT JOIN vehicle AS v
    ON v.user_id = u.user_id
   AND v.vehicle_status = 'ACTIVE'
GROUP BY
    u.user_id,
    u.real_name,
    u.real_name_status,
    u.user_status,
    ml.level_code,
    ml.level_name,
    u.balance
ORDER BY u.user_id;

-- Q02：会员等级变更历史。
-- 历史表保存变更后的等级，按生效时间倒序展示。
SELECT
    mr.membership_record_id,
    mr.user_id,
    u.real_name,
    ml.level_code,
    ml.level_name,
    mr.change_type,
    mr.effective_at,
    mr.change_reason
FROM membership_record AS mr
JOIN `user` AS u
    ON u.user_id = mr.user_id
JOIN membership_level AS ml
    ON ml.level_id = mr.level_id
ORDER BY mr.user_id, mr.effective_at DESC, mr.membership_record_id DESC;

-- Q03：企业车队概览。
-- LEFT JOIN 保证即使车队暂时没有有效车辆也仍然出现在结果中。
SELECT
    ec.enterprise_id,
    ec.enterprise_name,
    f.fleet_id,
    f.fleet_name,
    f.status AS fleet_status,
    COUNT(fv.fleet_vehicle_id) AS active_vehicle_count
FROM enterprise_customer AS ec
JOIN fleet AS f
    ON f.enterprise_id = ec.enterprise_id
LEFT JOIN fleet_vehicle AS fv
    ON fv.fleet_id = f.fleet_id
   AND fv.status = 'ACTIVE'
GROUP BY
    ec.enterprise_id,
    ec.enterprise_name,
    f.fleet_id,
    f.fleet_name,
    f.status
ORDER BY ec.enterprise_id, f.fleet_id;

-- Q04：当前车队车辆明细。
-- 只读取 ACTIVE 关联；LEFT 状态仍保留在历史表中，但不属于当前车辆清单。
SELECT
    f.fleet_id,
    f.fleet_name,
    fv.fleet_vehicle_id,
    v.vehicle_id,
    v.model,
    u.user_id,
    u.real_name AS vehicle_owner,
    fv.joined_at
FROM fleet_vehicle AS fv
JOIN fleet AS f
    ON f.fleet_id = fv.fleet_id
JOIN vehicle AS v
    ON v.vehicle_id = fv.vehicle_id
JOIN `user` AS u
    ON u.user_id = v.user_id
WHERE fv.status = 'ACTIVE'
ORDER BY f.fleet_id, fv.joined_at, v.vehicle_id;

-- Q05：额度设置明细。
-- 根据 quota_scope 选择对应的企业、车队或车辆名称，避免把三类对象混淆。
SELECT
    qr.quota_record_id,
    qr.quota_scope,
    CASE qr.quota_scope
        WHEN 'ENTERPRISE' THEN ec.enterprise_name
        WHEN 'FLEET' THEN f.fleet_name
        WHEN 'VEHICLE' THEN CONCAT('vehicle_id=', v.vehicle_id, ', ', COALESCE(v.model, '未填写车型'))
    END AS quota_target,
    qr.quota_type,
    qr.quota_limit,
    qr.period_start,
    qr.period_end,
    qr.change_reason
FROM fleet_quota_record AS qr
LEFT JOIN enterprise_customer AS ec
    ON ec.enterprise_id = qr.enterprise_id
LEFT JOIN fleet AS f
    ON f.fleet_id = qr.fleet_id
LEFT JOIN vehicle AS v
    ON v.vehicle_id = qr.vehicle_id
ORDER BY qr.period_start DESC, qr.quota_record_id;

-- Q06：指定时点可用的全场通用活动。
-- 使用固定测试时点保证每次执行结果一致；跨场站活动需等 promotion_station 建成后再联调。
SET @query_time = TIMESTAMP('2026-11-19 12:00:00');

SELECT
    p.promotion_id,
    p.promotion_name,
    p.discount_type,
    p.discount_value,
    p.minimum_spend,
    p.max_discount_amount,
    p.per_user_limit,
    p.valid_from,
    p.valid_to
FROM promotion AS p
WHERE p.status = 'ACTIVE'
  AND p.applicability_scope = 'ALL'
  AND @query_time >= p.valid_from
  AND @query_time < p.valid_to
ORDER BY p.promotion_id;

-- Q07：检查同一车辆是否同时属于多个有效车队。
-- 当前约束由业务事务保证；正常结果应为 0 行。
SELECT
    fv.vehicle_id,
    COUNT(*) AS active_fleet_count
FROM fleet_vehicle AS fv
WHERE fv.status = 'ACTIVE'
GROUP BY fv.vehicle_id
HAVING COUNT(*) > 1;

-- Q08：检查用户当前等级是否与最新一条会员历史一致。
-- 使用 MySQL 8 窗口函数找出每名用户最新的会员记录。
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
    u.user_id,
    u.level_id AS current_level_id,
    rm.level_id AS latest_history_level_id,
    IF(u.level_id <=> rm.level_id, 'MATCH', 'MISMATCH') AS result
FROM `user` AS u
LEFT JOIN ranked_membership AS rm
    ON rm.user_id = u.user_id
   AND rm.row_num = 1
ORDER BY u.user_id;

-- Q09：业务查询后的只读验收摘要。
SELECT
    (SELECT COUNT(*) FROM `user`) AS user_count,
    (SELECT COUNT(*) FROM vehicle) AS vehicle_count,
    (SELECT COUNT(*) FROM membership_record) AS membership_record_count,
    (SELECT COUNT(*) FROM promotion) AS promotion_count,
    (SELECT COUNT(*) FROM enterprise_customer) AS enterprise_count,
    (SELECT COUNT(*) FROM fleet) AS fleet_count,
    (SELECT COUNT(*) FROM fleet_vehicle WHERE status = 'ACTIVE') AS active_fleet_vehicle_count,
    (SELECT COUNT(*) FROM fleet_quota_record) AS quota_record_count;

-- Q10：企业车队月度充电明细。
-- 账期按订单确认时间 confirmed_at 归属左闭右开区间；
-- 车队归属按订单开始时间匹配加入/退出历史，调车后不会改写旧订单归属。
-- 支付与退款先各自按订单汇总，避免多笔支付与多笔退款连接后重复累计。
SET @fleet_id = 60001;
SET @fleet_period_start = TIMESTAMP('2026-11-01 00:00:00');
SET @fleet_period_end = TIMESTAMP('2026-12-01 00:00:00');

WITH successful_payment AS (
    SELECT
        order_id,
        SUM(amount) AS paid_amount
    FROM payment_record
    WHERE status = 'SUCCESS'
    GROUP BY order_id
),
successful_refund AS (
    SELECT
        pr.order_id,
        SUM(rr.amount) AS refund_amount
    FROM refund_record AS rr
    JOIN payment_record AS pr
        ON pr.payment_id = rr.payment_id
       AND pr.status = 'SUCCESS'
    GROUP BY pr.order_id
)
SELECT
    ec.enterprise_id,
    ec.enterprise_name,
    f.fleet_id,
    f.fleet_name,
    o.order_id,
    o.vehicle_id,
    v.model AS vehicle_model,
    u.user_id,
    u.real_name AS vehicle_owner,
    s.station_id,
    s.name AS station_name,
    o.starts_at,
    o.ends_at,
    o.confirmed_at,
    o.total_kwh,
    o.gross_amount,
    o.discount_amount,
    o.gross_amount - o.discount_amount AS payable_amount,
    COALESCE(sp.paid_amount, 0.00) AS paid_amount,
    COALESCE(sr.refund_amount, 0.00) AS refund_amount,
    COALESCE(sp.paid_amount, 0.00)
        - COALESCE(sr.refund_amount, 0.00) AS net_paid_amount
FROM fleet AS f
JOIN enterprise_customer AS ec
    ON ec.enterprise_id = f.enterprise_id
JOIN fleet_vehicle AS fv
    ON fv.fleet_id = f.fleet_id
JOIN charging_order AS o
    ON o.vehicle_id = fv.vehicle_id
   AND o.starts_at >= fv.joined_at
   AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
JOIN vehicle AS v
    ON v.vehicle_id = o.vehicle_id
JOIN `user` AS u
    ON u.user_id = o.user_id
JOIN charging_gun AS cg
    ON cg.gun_id = o.gun_id
JOIN station AS s
    ON s.station_id = cg.station_id
LEFT JOIN successful_payment AS sp
    ON sp.order_id = o.order_id
LEFT JOIN successful_refund AS sr
    ON sr.order_id = o.order_id
WHERE f.fleet_id = @fleet_id
  AND o.state = 'BILLED'
  AND o.confirmed_at >= @fleet_period_start
  AND o.confirmed_at < @fleet_period_end
ORDER BY o.confirmed_at, o.order_id;

-- Q11：企业车队月度账单动态汇总。
-- 不新增月结表；每次按最终订单、成功支付和退款事实重新聚合。
WITH successful_payment AS (
    SELECT
        order_id,
        SUM(amount) AS paid_amount
    FROM payment_record
    WHERE status = 'SUCCESS'
    GROUP BY order_id
),
successful_refund AS (
    SELECT
        pr.order_id,
        SUM(rr.amount) AS refund_amount
    FROM refund_record AS rr
    JOIN payment_record AS pr
        ON pr.payment_id = rr.payment_id
       AND pr.status = 'SUCCESS'
    GROUP BY pr.order_id
)
SELECT
    ec.enterprise_id,
    ec.enterprise_name,
    f.fleet_id,
    f.fleet_name,
    @fleet_period_start AS period_start,
    @fleet_period_end AS period_end,
    COUNT(o.order_id) AS order_count,
    COUNT(DISTINCT o.vehicle_id) AS vehicle_count,
    COALESCE(SUM(o.total_kwh), 0.000) AS total_kwh,
    COALESCE(SUM(o.gross_amount), 0.00) AS gross_amount,
    COALESCE(SUM(o.discount_amount), 0.00) AS discount_amount,
    COALESCE(SUM(o.gross_amount - o.discount_amount), 0.00) AS payable_amount,
    COALESCE(SUM(sp.paid_amount), 0.00) AS paid_amount,
    COALESCE(SUM(sr.refund_amount), 0.00) AS refund_amount,
    COALESCE(SUM(sp.paid_amount), 0.00)
        - COALESCE(SUM(sr.refund_amount), 0.00) AS net_paid_amount
FROM fleet AS f
JOIN enterprise_customer AS ec
    ON ec.enterprise_id = f.enterprise_id
LEFT JOIN fleet_vehicle AS fv
    ON fv.fleet_id = f.fleet_id
LEFT JOIN charging_order AS o
    ON o.vehicle_id = fv.vehicle_id
   AND o.starts_at >= fv.joined_at
   AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
   AND o.state = 'BILLED'
   AND o.confirmed_at >= @fleet_period_start
   AND o.confirmed_at < @fleet_period_end
LEFT JOIN successful_payment AS sp
    ON sp.order_id = o.order_id
LEFT JOIN successful_refund AS sr
    ON sr.order_id = o.order_id
WHERE f.fleet_id = @fleet_id
GROUP BY
    ec.enterprise_id,
    ec.enterprise_name,
    f.fleet_id,
    f.fleet_name;

-- Q12：企业、车队或车辆额度使用情况。
-- AMOUNT使用订单应付金额，ENERGY使用充电电量，ORDER_COUNT使用订单数。
-- 额度统计沿用confirmed_at账期和历史车队归属口径。
WITH quota_orders AS (
    SELECT
        qr.quota_record_id,
        o.order_id,
        o.total_kwh,
        o.gross_amount - o.discount_amount AS payable_amount
    FROM fleet_quota_record AS qr
    JOIN charging_order AS o
        ON qr.quota_scope = 'VEHICLE'
       AND o.vehicle_id = qr.vehicle_id
       AND o.state = 'BILLED'
       AND o.confirmed_at >= qr.period_start
       AND o.confirmed_at < qr.period_end
    UNION ALL
    SELECT
        qr.quota_record_id,
        o.order_id,
        o.total_kwh,
        o.gross_amount - o.discount_amount AS payable_amount
    FROM fleet_quota_record AS qr
    JOIN fleet_vehicle AS fv
        ON qr.quota_scope = 'FLEET'
       AND fv.fleet_id = qr.fleet_id
    JOIN charging_order AS o
        ON o.vehicle_id = fv.vehicle_id
       AND o.starts_at >= fv.joined_at
       AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
       AND o.state = 'BILLED'
       AND o.confirmed_at >= qr.period_start
       AND o.confirmed_at < qr.period_end
    UNION ALL
    SELECT
        qr.quota_record_id,
        o.order_id,
        o.total_kwh,
        o.gross_amount - o.discount_amount AS payable_amount
    FROM fleet_quota_record AS qr
    JOIN fleet AS f
        ON qr.quota_scope = 'ENTERPRISE'
       AND f.enterprise_id = qr.enterprise_id
    JOIN fleet_vehicle AS fv
        ON fv.fleet_id = f.fleet_id
    JOIN charging_order AS o
        ON o.vehicle_id = fv.vehicle_id
       AND o.starts_at >= fv.joined_at
       AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
       AND o.state = 'BILLED'
       AND o.confirmed_at >= qr.period_start
       AND o.confirmed_at < qr.period_end
),
aggregated_usage AS (
    SELECT
        quota_record_id,
        COUNT(*) AS order_count,
        SUM(total_kwh) AS energy_used,
        SUM(payable_amount) AS amount_used
    FROM quota_orders
    GROUP BY quota_record_id
)
SELECT
    qr.quota_record_id,
    qr.quota_scope,
    qr.enterprise_id,
    qr.fleet_id,
    qr.vehicle_id,
    qr.quota_type,
    qr.quota_limit,
    qr.period_start,
    qr.period_end,
    CASE qr.quota_type
        WHEN 'AMOUNT' THEN COALESCE(au.amount_used, 0.00)
        WHEN 'ENERGY' THEN COALESCE(au.energy_used, 0.000)
        WHEN 'ORDER_COUNT' THEN COALESCE(au.order_count, 0)
    END AS used_value,
    GREATEST(
        qr.quota_limit - CASE qr.quota_type
            WHEN 'AMOUNT' THEN COALESCE(au.amount_used, 0.00)
            WHEN 'ENERGY' THEN COALESCE(au.energy_used, 0.000)
            WHEN 'ORDER_COUNT' THEN COALESCE(au.order_count, 0)
        END,
        0
    ) AS remaining_value,
    CASE
        WHEN CASE qr.quota_type
            WHEN 'AMOUNT' THEN COALESCE(au.amount_used, 0.00)
            WHEN 'ENERGY' THEN COALESCE(au.energy_used, 0.000)
            WHEN 'ORDER_COUNT' THEN COALESCE(au.order_count, 0)
        END > qr.quota_limit
        THEN 'EXCEEDED'
        ELSE 'WITHIN_LIMIT'
    END AS quota_status
FROM fleet_quota_record AS qr
LEFT JOIN aggregated_usage AS au
    ON au.quota_record_id = qr.quota_record_id
ORDER BY qr.period_start DESC, qr.quota_record_id;
