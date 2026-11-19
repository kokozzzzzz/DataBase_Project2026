-- ④ 用户与会员运营：核心业务视图
-- 适用环境：MySQL 8.0.46。
-- 仅创建或更新 D 模块视图，不修改任何表数据。

USE charging_platform;
SET NAMES utf8mb4;

-- V01：用户会员档案。
-- 不暴露手机号密文、手机号摘要等认证/检索字段。
CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_user_membership_profile AS
SELECT
    u.user_id,
    u.real_name,
    u.real_name_status,
    u.user_status,
    u.registered_at,
    u.level_id,
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
    u.registered_at,
    u.level_id,
    ml.level_code,
    ml.level_name,
    u.balance;

-- V02：企业车队当前有效车辆。
-- 只展示 ACTIVE 关系，LEFT 历史仍保留在 fleet_vehicle 基表中。
-- 不暴露车牌密文、车牌摘要或联系人手机号密文。
CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_fleet_active_vehicle AS
SELECT
    ec.enterprise_id,
    ec.enterprise_name,
    f.fleet_id,
    f.fleet_name,
    fv.fleet_vehicle_id,
    fv.joined_at,
    v.vehicle_id,
    v.model,
    v.vehicle_status,
    u.user_id,
    u.real_name AS vehicle_owner
FROM enterprise_customer AS ec
JOIN fleet AS f
    ON f.enterprise_id = ec.enterprise_id
JOIN fleet_vehicle AS fv
    ON fv.fleet_id = f.fleet_id
   AND fv.status = 'ACTIVE'
JOIN vehicle AS v
    ON v.vehicle_id = fv.vehicle_id
JOIN `user` AS u
    ON u.user_id = v.user_id
WHERE ec.status = 'ACTIVE'
  AND f.status = 'ACTIVE';

-- V03：当前有效的全场活动。
-- SELECTED 活动依赖 promotion_station 与 B 的 station 表，暂不放入本视图。
-- 有效期采用左闭右开区间 [valid_from, valid_to)。
CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_active_global_promotion AS
SELECT
    p.promotion_id,
    p.promotion_name,
    p.description,
    p.discount_type,
    p.discount_value,
    p.minimum_spend,
    p.max_discount_amount,
    p.total_quantity,
    p.per_user_limit,
    p.valid_from,
    p.valid_to
FROM promotion AS p
WHERE p.status = 'ACTIVE'
  AND p.applicability_scope = 'ALL'
  AND CURRENT_TIMESTAMP >= p.valid_from
  AND CURRENT_TIMESTAMP < p.valid_to;
