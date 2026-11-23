-- D 模块最小权限角色
-- 适用环境：MySQL 8.0.46 / charging_platform
-- 前置条件：D④⑤表、6个视图、2个过程以及B依赖对象均已安装。
-- 安全说明：
--   1. 本脚本只创建角色并授予必要权限，不创建具体用户，不保存密码。
--   2. 不授予 DELETE、DROP、ALTER、CREATE、TRIGGER、FILE 或 GRANT OPTION。
--   3. 角色分配给具体账号时必须由管理员在部署环境单独执行。

USE charging_platform;
SET NAMES utf8mb4;

CREATE ROLE IF NOT EXISTS
    'cp_d_reporting'@'%',
    'cp_d_membership_operator'@'%',
    'cp_d_settlement_operator'@'%';

-- 只读报表角色：只允许使用6个脱敏视图。
GRANT SELECT ON charging_platform.v_user_membership_profile
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.v_fleet_active_vehicle
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.v_active_global_promotion
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.v_settlement_statement_summary
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.v_settlement_order_detail
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.v_reconciliation_pending
    TO 'cp_d_reporting'@'%';

-- 视图采用 SQL SECURITY INVOKER，因此只授予视图实际读取的安全列。
GRANT SELECT (user_id, real_name, real_name_status, user_status,
              registered_at, level_id, balance)
    ON charging_platform.`user` TO 'cp_d_reporting'@'%';
GRANT SELECT (level_id, level_code, level_name)
    ON charging_platform.membership_level TO 'cp_d_reporting'@'%';
GRANT SELECT (vehicle_id, user_id, model, vehicle_status)
    ON charging_platform.vehicle TO 'cp_d_reporting'@'%';
GRANT SELECT (enterprise_id, enterprise_name, status)
    ON charging_platform.enterprise_customer TO 'cp_d_reporting'@'%';
GRANT SELECT (fleet_id, enterprise_id, fleet_name, status)
    ON charging_platform.fleet TO 'cp_d_reporting'@'%';
GRANT SELECT (fleet_vehicle_id, fleet_id, vehicle_id, joined_at, status)
    ON charging_platform.fleet_vehicle TO 'cp_d_reporting'@'%';
GRANT SELECT (promotion_id, promotion_name, description, discount_type,
              discount_value, minimum_spend, max_discount_amount,
              applicability_scope, total_quantity, per_user_limit,
              valid_from, valid_to, status)
    ON charging_platform.promotion TO 'cp_d_reporting'@'%';

GRANT SELECT ON charging_platform.settlement_statement
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.settlement_detail
    TO 'cp_d_reporting'@'%';
GRANT SELECT ON charging_platform.reconciliation_difference
    TO 'cp_d_reporting'@'%';
GRANT SELECT (confirmation_id, difference_id, confirming_party,
              confirmation_result, confirmed_at)
    ON charging_platform.reconciliation_confirmation TO 'cp_d_reporting'@'%';
GRANT SELECT (invoice_id, settlement_id, invoice_number, invoice_type,
              invoice_amount, issued_at, status, original_invoice_id)
    ON charging_platform.invoice_record TO 'cp_d_reporting'@'%';

-- 结算明细视图依赖B的资金视图；继续只开放所需事实列。
GRANT SELECT ON charging_platform.v_b_order_funds
    TO 'cp_d_reporting'@'%';
GRANT SELECT (operator_id, name)
    ON charging_platform.`operator` TO 'cp_d_reporting'@'%';
GRANT SELECT (station_id, operator_id, name)
    ON charging_platform.station TO 'cp_d_reporting'@'%';
GRANT SELECT (gun_id, station_id)
    ON charging_platform.charging_gun TO 'cp_d_reporting'@'%';
GRANT SELECT (order_id, user_id, gun_id, state, starts_at, ends_at,
              confirmed_at, total_kwh, gross_amount, discount_amount,
              review_reason)
    ON charging_platform.charging_order TO 'cp_d_reporting'@'%';
GRANT SELECT (payment_id, order_id, amount, status)
    ON charging_platform.payment_record TO 'cp_d_reporting'@'%';
GRANT SELECT (refund_id, payment_id, amount)
    ON charging_platform.refund_record TO 'cp_d_reporting'@'%';

-- ④运营角色：可信应用服务可维护D④表；不授予物理删除权限。
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.membership_level
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.`user`
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.vehicle
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.membership_record
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.enterprise_customer
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.fleet
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.fleet_vehicle
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.fleet_quota_record
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.promotion
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.promotion_station
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.coupon
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.coupon_redemption
    TO 'cp_d_membership_operator'@'%';

GRANT SELECT ON charging_platform.station
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT ON charging_platform.charging_gun
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT ON charging_platform.charging_order
    TO 'cp_d_membership_operator'@'%';
GRANT UPDATE (discount_amount, confirmed_at)
    ON charging_platform.charging_order
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT ON charging_platform.payment_record
    TO 'cp_d_membership_operator'@'%';
GRANT SELECT ON charging_platform.refund_record
    TO 'cp_d_membership_operator'@'%';
GRANT EXECUTE ON PROCEDURE charging_platform.sp_calculate_promotion_quote
    TO 'cp_d_membership_operator'@'%';

-- ⑤结算角色：只维护D⑤表，只读B交易事实；不具备④用户资料写权限。
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.settlement_statement
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.settlement_detail
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.reconciliation_difference
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.reconciliation_confirmation
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT, INSERT, UPDATE
    ON charging_platform.invoice_record
    TO 'cp_d_settlement_operator'@'%';

GRANT SELECT ON charging_platform.`operator`
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT ON charging_platform.station
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT ON charging_platform.charging_gun
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT ON charging_platform.charging_order
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT ON charging_platform.order_fee_detail
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT ON charging_platform.payment_record
    TO 'cp_d_settlement_operator'@'%';
GRANT SELECT ON charging_platform.refund_record
    TO 'cp_d_settlement_operator'@'%';
GRANT EXECUTE ON PROCEDURE charging_platform.sp_generate_settlement_statement
    TO 'cp_d_settlement_operator'@'%';

-- 账号绑定示例（仅说明，不要在仓库中提交真实账号或密码）：
-- GRANT 'cp_d_reporting'@'%' TO 'report_user'@'localhost';
-- SET DEFAULT ROLE 'cp_d_reporting'@'%' TO 'report_user'@'localhost';
