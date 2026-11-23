-- ⑤ 结算与对账：允许退款-only账期形成负净结算额
-- 适用场景：已执行旧版 05_settlement_schema.sql，且存在
--           ck_settlement_totals_nonnegative 的数据库。
--
-- 业务原因：基础订单按足额支付时间进入原账期，跨期退款必须进入退款发生账期。
-- 如果退款账期没有新的正向订单，结算单净额应允许为负，表示运营商返还平台
-- 或将该金额结转到后续账期，而不是伪造一条正向调整抵消退款。
--
-- 安全说明：
--   1. 不删除表或业务数据；只修改两个字段注释并原子替换一个 CHECK 约束。
--   2. ALTER TABLE 是 DDL，会隐式提交；执行前应已完成数据库备份。
--   3. 本脚本只执行一次；重复执行会因旧约束已不存在而失败，不会重复修改数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

ALTER TABLE settlement_statement
    MODIFY COLUMN payable_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00
        COMMENT '最终净结算金额，正数为平台应付、负数为运营商应返还或结转，元',
    MODIFY COLUMN paid_at DATETIME NULL
        COMMENT '正向付款或负向返还完成后的资金结清时间',
    DROP CHECK ck_settlement_totals_nonnegative,
    ADD CONSTRAINT ck_settlement_totals_valid
        CHECK (
            total_kwh >= 0
            AND total_electricity_fee >= 0
            AND total_service_fee >= 0
            AND total_discount_amount >= 0
            AND total_refund_amount >= 0
            AND electricity_share_amount >= 0
            AND service_share_amount >= 0
            AND platform_service_fee >= 0
        );

SELECT
    'U01 signed_payable_constraint' AS check_item,
    COUNT(*) AS actual_value,
    1 AS expected_value,
    IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result
FROM information_schema.CHECK_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_NAME = 'ck_settlement_totals_valid'
  AND CHECK_CLAUSE NOT LIKE '%payable_amount%';

SELECT
    'U02 old_constraint_removed' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.CHECK_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_NAME = 'ck_settlement_totals_nonnegative';
