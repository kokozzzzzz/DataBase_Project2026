-- ⑤ 结算与对账：生成账期结算单及逐单明细
-- 适用环境：MySQL 8.0.46 / InnoDB / utf8mb4
-- 前置：B-FORMAL-v1 交易数据已提交，D 五张结算表已创建并完成负净额升级。
--
-- 事务约定：
--   1. 过程不 COMMIT；调用方负责最终提交或回滚。
--   2. 过程使用保存点保证单次调用原子性，不回滚调用方在保存点之前的操作。
--   3. 同一运营商、场站、账期和费率重复调用时返回已有 GENERATED 结算单，
--      不重复生成明细；费率不同或状态已推进时拒绝覆盖。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

DROP PROCEDURE IF EXISTS sp_generate_settlement_statement;

DELIMITER $$

CREATE PROCEDURE sp_generate_settlement_statement(
    IN p_operator_id BIGINT UNSIGNED,
    IN p_station_id BIGINT UNSIGNED,
    IN p_period_start DATE,
    IN p_period_end DATE,
    IN p_electricity_share_rate DECIMAL(7,6),
    IN p_service_share_rate DECIMAL(7,6),
    IN p_platform_fee_rate DECIMAL(7,6),
    IN p_operator_discount_rate DECIMAL(7,6),
    IN p_generated_at DATETIME,
    OUT p_settlement_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
main: BEGIN
    DECLARE v_station_operator_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_existing_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_existing_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_existing_electricity_rate DECIMAL(7,6) DEFAULT NULL;
    DECLARE v_existing_service_rate DECIMAL(7,6) DEFAULT NULL;
    DECLARE v_existing_platform_rate DECIMAL(7,6) DEFAULT NULL;
    DECLARE v_existing_discount_rate DECIMAL(7,6) DEFAULT NULL;
    DECLARE v_statement_no VARCHAR(50);
    DECLARE v_invalid_detail_count INT DEFAULT 0;
    DECLARE v_detail_count INT DEFAULT 0;
    DECLARE v_savepoint_created TINYINT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        IF v_savepoint_created = 1 THEN
            ROLLBACK TO SAVEPOINT d_generate_settlement;
            RELEASE SAVEPOINT d_generate_settlement;
        END IF;
        RESIGNAL;
    END;

    SET p_settlement_id = NULL;

    IF p_operator_id IS NULL OR p_operator_id = 0
       OR p_station_id IS NULL OR p_station_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_OPERATOR_OR_STATION_INVALID';
    END IF;

    IF p_period_start IS NULL OR p_period_end IS NULL
       OR p_period_start >= p_period_end THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_PERIOD_INVALID';
    END IF;

    IF p_generated_at IS NULL OR DATE(p_generated_at) < p_period_end THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_GENERATED_AT_INVALID';
    END IF;

    IF p_electricity_share_rate IS NULL
       OR p_electricity_share_rate < 0
       OR p_electricity_share_rate > 1
       OR p_service_share_rate IS NULL
       OR p_service_share_rate < 0
       OR p_service_share_rate > 1
       OR p_platform_fee_rate IS NULL
       OR p_platform_fee_rate < 0
       OR p_platform_fee_rate > 1
       OR p_operator_discount_rate IS NULL
       OR p_operator_discount_rate < 0
       OR p_operator_discount_rate > 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_RATE_INVALID';
    END IF;

    SAVEPOINT d_generate_settlement;
    SET v_savepoint_created = 1;

    -- 固定先锁场站，所有并发生成调用使用相同锁顺序。
    SELECT operator_id
      INTO v_station_operator_id
      FROM station
     WHERE station_id = p_station_id
     FOR UPDATE;

    IF v_station_operator_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_STATION_NOT_FOUND';
    END IF;

    IF v_station_operator_id <> p_operator_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_OPERATOR_STATION_MISMATCH';
    END IF;

    -- 锁定同一业务唯一键；重复请求只有完全相同的 GENERATED 结果可以复用。
    SELECT
        settlement_id,
        status,
        electricity_share_rate,
        service_share_rate,
        platform_fee_rate,
        operator_discount_rate
      INTO
        v_existing_id,
        v_existing_status,
        v_existing_electricity_rate,
        v_existing_service_rate,
        v_existing_platform_rate,
        v_existing_discount_rate
      FROM settlement_statement
     WHERE operator_id = p_operator_id
       AND station_id = p_station_id
       AND period_start = p_period_start
       AND period_end = p_period_end
     LIMIT 1
     FOR UPDATE;

    IF v_existing_id IS NOT NULL THEN
        IF v_existing_status = 'GENERATED'
           AND v_existing_electricity_rate = p_electricity_share_rate
           AND v_existing_service_rate = p_service_share_rate
           AND v_existing_platform_rate = p_platform_fee_rate
           AND v_existing_discount_rate = p_operator_discount_rate THEN
            SET p_settlement_id = v_existing_id;
            RELEASE SAVEPOINT d_generate_settlement;
            SET v_savepoint_created = 0;
            LEAVE main;
        END IF;

        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_PERIOD_ALREADY_EXISTS';
    END IF;

    -- 在写入前验证本账期基础订单金额能够满足 ORDER 明细的非负约束。
    WITH successful_payment_running AS (
        SELECT
            payment_id,
            order_id,
            occurred_at,
            SUM(amount) OVER (
                PARTITION BY order_id
                ORDER BY occurred_at, payment_id
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cumulative_paid
        FROM payment_record
        WHERE status = 'SUCCESS'
    ), completion_candidate AS (
        SELECT
            running.payment_id,
            running.order_id,
            running.occurred_at,
            ROW_NUMBER() OVER (
                PARTITION BY running.order_id
                ORDER BY running.occurred_at, running.payment_id
            ) AS completion_rank
        FROM successful_payment_running AS running
        JOIN charging_order AS charged_order
          ON charged_order.order_id = running.order_id
        WHERE charged_order.state = 'BILLED'
          AND running.cumulative_paid
              >= charged_order.gross_amount - charged_order.discount_amount
    ), completion_payment AS (
        SELECT payment_id, order_id, occurred_at
        FROM completion_candidate
        WHERE completion_rank = 1
    ), fee_summary AS (
        SELECT
            order_id,
            SUM(energy_amount) AS electricity_fee,
            SUM(service_amount) AS service_fee
        FROM order_fee_detail
        GROUP BY order_id
    ), eligible_order AS (
        SELECT
            charged_order.order_id,
            charged_order.gross_amount,
            charged_order.discount_amount,
            COALESCE(fee.electricity_fee, 0.00) AS electricity_fee,
            COALESCE(fee.service_fee, 0.00) AS service_fee,
            charged_order.gross_amount
                - COALESCE(fee.electricity_fee, 0.00)
                - COALESCE(fee.service_fee, 0.00) AS minimum_fee_adjustment
        FROM completion_payment AS completion
        JOIN charging_order AS charged_order
          ON charged_order.order_id = completion.order_id
        JOIN charging_gun AS gun
          ON gun.gun_id = charged_order.gun_id
        LEFT JOIN fee_summary AS fee
          ON fee.order_id = charged_order.order_id
        LEFT JOIN settlement_detail AS existing_detail
          ON existing_detail.base_order_id = charged_order.order_id
        WHERE gun.station_id = p_station_id
          AND completion.occurred_at >= p_period_start
          AND completion.occurred_at < p_period_end
          AND existing_detail.settlement_detail_id IS NULL
    )
    SELECT COUNT(*)
      INTO v_invalid_detail_count
      FROM eligible_order
     WHERE minimum_fee_adjustment < 0
        OR ROUND(electricity_fee * p_electricity_share_rate, 2)
           + ROUND(
               (service_fee + minimum_fee_adjustment)
               * p_service_share_rate,
               2
           )
           - ROUND(gross_amount * p_platform_fee_rate, 2)
           - ROUND(discount_amount * p_operator_discount_rate, 2) < 0;

    IF v_invalid_detail_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_ORDER_AMOUNT_INVALID';
    END IF;

    -- 退款必须能回指已经存在的基础 ORDER 明细，并产生大于 0 的结算冲减额。
    SELECT COUNT(*)
      INTO v_invalid_detail_count
      FROM refund_record AS refund
      JOIN payment_record AS payment
        ON payment.payment_id = refund.payment_id
       AND payment.status = 'SUCCESS'
      JOIN charging_order AS charged_order
        ON charged_order.order_id = payment.order_id
      JOIN charging_gun AS gun
        ON gun.gun_id = charged_order.gun_id
      LEFT JOIN settlement_detail AS original_detail
        ON original_detail.order_id = charged_order.order_id
       AND original_detail.detail_type = 'ORDER'
      LEFT JOIN settlement_detail AS existing_refund
        ON existing_refund.refund_id = refund.refund_id
     WHERE gun.station_id = p_station_id
       AND refund.occurred_at >= p_period_start
       AND refund.occurred_at < p_period_end
       AND existing_refund.settlement_detail_id IS NULL
       AND (
           original_detail.settlement_detail_id IS NULL
           OR original_detail.payable_amount <= 0
           OR charged_order.gross_amount - charged_order.discount_amount <= 0
           OR ROUND(
               original_detail.payable_amount * refund.amount
               / (charged_order.gross_amount - charged_order.discount_amount),
               2
           ) <= 0
       );

    IF v_invalid_detail_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_REFUND_ORIGINAL_DETAIL_INVALID';
    END IF;

    SET v_statement_no = CONCAT(
        'STL-',
        DATE_FORMAT(p_period_start, '%Y%m%d'),
        '-',
        UPPER(LEFT(SHA2(CONCAT_WS(
            ':',
            p_operator_id,
            p_station_id,
            p_period_start,
            p_period_end
        ), 256), 24))
    );

    INSERT INTO settlement_statement (
        statement_no,
        operator_id,
        station_id,
        period_start,
        period_end,
        electricity_share_rate,
        service_share_rate,
        platform_fee_rate,
        operator_discount_rate,
        status
    ) VALUES (
        v_statement_no,
        p_operator_id,
        p_station_id,
        p_period_start,
        p_period_end,
        p_electricity_share_rate,
        p_service_share_rate,
        p_platform_fee_rate,
        p_operator_discount_rate,
        'DRAFT'
    );

    SET p_settlement_id = LAST_INSERT_ID();

    -- 生成足额支付基础订单明细；payment_id 取累计成功支付首次达到应付额的流水。
    INSERT INTO settlement_detail (
        settlement_id,
        order_id,
        detail_type,
        payment_id,
        event_at,
        charging_kwh,
        electricity_fee,
        service_fee,
        minimum_fee_adjustment,
        discount_amount,
        adjustment_amount,
        electricity_share_amount,
        service_share_amount,
        platform_service_fee,
        payable_amount,
        description
    )
    WITH successful_payment_running AS (
        SELECT
            payment_id,
            order_id,
            occurred_at,
            SUM(amount) OVER (
                PARTITION BY order_id
                ORDER BY occurred_at, payment_id
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cumulative_paid
        FROM payment_record
        WHERE status = 'SUCCESS'
    ), completion_candidate AS (
        SELECT
            running.payment_id,
            running.order_id,
            running.occurred_at,
            ROW_NUMBER() OVER (
                PARTITION BY running.order_id
                ORDER BY running.occurred_at, running.payment_id
            ) AS completion_rank
        FROM successful_payment_running AS running
        JOIN charging_order AS charged_order
          ON charged_order.order_id = running.order_id
        WHERE charged_order.state = 'BILLED'
          AND running.cumulative_paid
              >= charged_order.gross_amount - charged_order.discount_amount
    ), completion_payment AS (
        SELECT payment_id, order_id, occurred_at
        FROM completion_candidate
        WHERE completion_rank = 1
    ), fee_summary AS (
        SELECT
            order_id,
            SUM(energy_amount) AS electricity_fee,
            SUM(service_amount) AS service_fee
        FROM order_fee_detail
        GROUP BY order_id
    )
    SELECT
        p_settlement_id,
        charged_order.order_id,
        'ORDER',
        completion.payment_id,
        completion.occurred_at,
        charged_order.total_kwh,
        COALESCE(fee.electricity_fee, 0.00),
        COALESCE(fee.service_fee, 0.00),
        charged_order.gross_amount
            - COALESCE(fee.electricity_fee, 0.00)
            - COALESCE(fee.service_fee, 0.00),
        charged_order.discount_amount,
        0.00,
        ROUND(
            COALESCE(fee.electricity_fee, 0.00)
            * p_electricity_share_rate,
            2
        ),
        ROUND(
            (
                COALESCE(fee.service_fee, 0.00)
                + charged_order.gross_amount
                - COALESCE(fee.electricity_fee, 0.00)
                - COALESCE(fee.service_fee, 0.00)
            ) * p_service_share_rate,
            2
        ),
        ROUND(charged_order.gross_amount * p_platform_fee_rate, 2),
        ROUND(
            COALESCE(fee.electricity_fee, 0.00)
            * p_electricity_share_rate,
            2
        )
        + ROUND(
            (
                COALESCE(fee.service_fee, 0.00)
                + charged_order.gross_amount
                - COALESCE(fee.electricity_fee, 0.00)
                - COALESCE(fee.service_fee, 0.00)
            ) * p_service_share_rate,
            2
        )
        - ROUND(charged_order.gross_amount * p_platform_fee_rate, 2)
        - ROUND(
            charged_order.discount_amount * p_operator_discount_rate,
            2
        ),
        CONCAT('基础订单结算；完成支付流水=', completion.payment_id)
    FROM completion_payment AS completion
    JOIN charging_order AS charged_order
      ON charged_order.order_id = completion.order_id
    JOIN charging_gun AS gun
      ON gun.gun_id = charged_order.gun_id
    LEFT JOIN fee_summary AS fee
      ON fee.order_id = charged_order.order_id
    LEFT JOIN settlement_detail AS existing_detail
      ON existing_detail.base_order_id = charged_order.order_id
    WHERE gun.station_id = p_station_id
      AND completion.occurred_at >= p_period_start
      AND completion.occurred_at < p_period_end
      AND existing_detail.settlement_detail_id IS NULL;

    -- 生成退款发生账期的负向调整，不回写原账期。
    INSERT INTO settlement_detail (
        settlement_id,
        order_id,
        detail_type,
        original_detail_id,
        refund_id,
        event_at,
        refund_amount,
        adjustment_amount,
        payable_amount,
        description
    )
    SELECT
        p_settlement_id,
        charged_order.order_id,
        'REFUND_ADJUSTMENT',
        original_detail.settlement_detail_id,
        refund.refund_id,
        refund.occurred_at,
        refund.amount,
        -ROUND(
            original_detail.payable_amount * refund.amount
            / (charged_order.gross_amount - charged_order.discount_amount),
            2
        ),
        -ROUND(
            original_detail.payable_amount * refund.amount
            / (charged_order.gross_amount - charged_order.discount_amount),
            2
        ),
        CONCAT('跨期退款冲减；退款流水=', refund.refund_id)
    FROM refund_record AS refund
    JOIN payment_record AS payment
      ON payment.payment_id = refund.payment_id
     AND payment.status = 'SUCCESS'
    JOIN charging_order AS charged_order
      ON charged_order.order_id = payment.order_id
    JOIN charging_gun AS gun
      ON gun.gun_id = charged_order.gun_id
    JOIN settlement_detail AS original_detail
      ON original_detail.order_id = charged_order.order_id
     AND original_detail.detail_type = 'ORDER'
    LEFT JOIN settlement_detail AS existing_refund
      ON existing_refund.refund_id = refund.refund_id
    WHERE gun.station_id = p_station_id
      AND refund.occurred_at >= p_period_start
      AND refund.occurred_at < p_period_end
      AND existing_refund.settlement_detail_id IS NULL;

    SELECT COUNT(*)
      INTO v_detail_count
      FROM settlement_detail
     WHERE settlement_id = p_settlement_id;

    IF v_detail_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'SETTLEMENT_NO_ELIGIBLE_DATA';
    END IF;

    UPDATE settlement_statement AS statement
    JOIN (
        SELECT
            settlement_id,
            COALESCE(SUM(charging_kwh), 0.000) AS total_kwh,
            COALESCE(SUM(electricity_fee), 0.00) AS total_electricity_fee,
            COALESCE(SUM(service_fee), 0.00) AS total_service_fee,
            COALESCE(SUM(discount_amount), 0.00) AS total_discount_amount,
            COALESCE(SUM(refund_amount), 0.00) AS total_refund_amount,
            COALESCE(SUM(adjustment_amount), 0.00) AS total_adjustment_amount,
            COALESCE(SUM(electricity_share_amount), 0.00)
                AS electricity_share_amount,
            COALESCE(SUM(service_share_amount), 0.00)
                AS service_share_amount,
            COALESCE(SUM(platform_service_fee), 0.00)
                AS platform_service_fee,
            COALESCE(SUM(payable_amount), 0.00) AS payable_amount
        FROM settlement_detail
        WHERE settlement_id = p_settlement_id
        GROUP BY settlement_id
    ) AS total
      ON total.settlement_id = statement.settlement_id
       SET statement.total_kwh = total.total_kwh,
           statement.total_electricity_fee = total.total_electricity_fee,
           statement.total_service_fee = total.total_service_fee,
           statement.total_discount_amount = total.total_discount_amount,
           statement.total_refund_amount = total.total_refund_amount,
           statement.total_adjustment_amount = total.total_adjustment_amount,
           statement.electricity_share_amount = total.electricity_share_amount,
           statement.service_share_amount = total.service_share_amount,
           statement.platform_service_fee = total.platform_service_fee,
           statement.payable_amount = total.payable_amount,
           statement.status = 'GENERATED',
           statement.generated_at = p_generated_at
     WHERE statement.settlement_id = p_settlement_id;

    RELEASE SAVEPOINT d_generate_settlement;
    SET v_savepoint_created = 0;
END$$

DELIMITER ;

