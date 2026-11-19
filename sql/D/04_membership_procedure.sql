-- ④ 用户与会员运营：优惠活动试算存储过程
-- 适用环境：MySQL 8.0.46。
-- 本脚本只创建一个只读过程，不修改表数据，也不删除已有数据库对象。
-- 首次执行成功后不要重复 SOURCE；重复创建会返回 PROCEDURE already exists。

USE charging_platform;
SET NAMES utf8mb4;

DELIMITER $$

CREATE PROCEDURE sp_calculate_promotion_quote(
    IN p_promotion_id BIGINT UNSIGNED,
    IN p_order_amount DECIMAL(12,2),
    IN p_query_time DATETIME
)
SQL SECURITY INVOKER
READS SQL DATA
COMMENT '计算单个全场优惠活动的优惠金额和实付金额'
BEGIN
    DECLARE v_promotion_name VARCHAR(100);
    DECLARE v_discount_type VARCHAR(20);
    DECLARE v_discount_value DECIMAL(10,4);
    DECLARE v_minimum_spend DECIMAL(12,2);
    DECLARE v_max_discount_amount DECIMAL(12,2);
    DECLARE v_scope VARCHAR(20);
    DECLARE v_valid_from DATETIME;
    DECLARE v_valid_to DATETIME;
    DECLARE v_status VARCHAR(20);
    DECLARE v_query_time DATETIME;
    DECLARE v_eligible TINYINT DEFAULT 0;
    DECLARE v_discount_amount DECIMAL(12,2) DEFAULT 0.00;
    DECLARE v_payable_amount DECIMAL(12,2) DEFAULT 0.00;
    DECLARE v_reason VARCHAR(100) DEFAULT NULL;
    DECLARE v_not_found BOOLEAN DEFAULT FALSE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;

    IF p_promotion_id IS NULL OR p_promotion_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'promotion_id must be a positive integer';
    END IF;

    IF p_order_amount IS NULL OR p_order_amount < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'order_amount must be non-negative';
    END IF;

    SET v_query_time = COALESCE(p_query_time, CURRENT_TIMESTAMP);

    SELECT
        promotion_name,
        discount_type,
        discount_value,
        minimum_spend,
        max_discount_amount,
        applicability_scope,
        valid_from,
        valid_to,
        status
    INTO
        v_promotion_name,
        v_discount_type,
        v_discount_value,
        v_minimum_spend,
        v_max_discount_amount,
        v_scope,
        v_valid_from,
        v_valid_to,
        v_status
    FROM promotion
    WHERE promotion_id = p_promotion_id;

    IF v_not_found THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'promotion does not exist';
    END IF;

    IF v_status <> 'ACTIVE' THEN
        SET v_reason = '活动不是ACTIVE状态';
    ELSEIF v_scope <> 'ALL' THEN
        SET v_reason = '指定场站活动尚未联调';
    ELSEIF v_query_time < v_valid_from THEN
        SET v_reason = '活动尚未开始';
    ELSEIF v_query_time >= v_valid_to THEN
        SET v_reason = '活动已经结束';
    ELSEIF p_order_amount < v_minimum_spend THEN
        SET v_reason = '未达到最低消费门槛';
    ELSE
        SET v_eligible = 1;

        IF v_discount_type = 'FIXED' THEN
            SET v_discount_amount = LEAST(v_discount_value, p_order_amount);
        ELSEIF v_discount_type = 'PERCENTAGE' THEN
            -- discount_value 为实付比例；0.80 表示八折，优惠比例为 0.20。
            SET v_discount_amount = p_order_amount * (1 - v_discount_value);
            IF v_max_discount_amount IS NOT NULL THEN
                SET v_discount_amount = LEAST(
                    v_discount_amount,
                    v_max_discount_amount
                );
            END IF;
            SET v_discount_amount = LEAST(v_discount_amount, p_order_amount);
        ELSE
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'unsupported discount type';
        END IF;
    END IF;

    SET v_discount_amount = ROUND(v_discount_amount, 2);
    SET v_payable_amount = ROUND(p_order_amount - v_discount_amount, 2);

    SELECT
        p_promotion_id AS promotion_id,
        v_promotion_name AS promotion_name,
        v_discount_type AS discount_type,
        v_eligible AS eligible,
        p_order_amount AS order_amount,
        v_discount_amount AS discount_amount,
        v_payable_amount AS payable_amount,
        v_query_time AS query_time,
        v_reason AS reason;
END$$

DELIMITER ;
