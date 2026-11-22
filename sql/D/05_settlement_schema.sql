-- ⑤ 结算与对账：五张正式业务表
-- 适用环境：MySQL 8.0.46 / InnoDB / utf8mb4
-- 前置条件：
--   1. 数据库 charging_platform 已创建。
--   2. B 模块的 operator、station、charging_order、payment_record、refund_record 已创建。
--   3. 运行 sql/D/05_settlement_preflight.sql，确认 P01～P04 全部 PASS 且 P05 为空。
-- 安全说明：本脚本不包含 DROP、TRUNCATE 或 DELETE；仅用于首次建表。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- 结算单头：同一运营商、场站和半开账期 [period_start, period_end) 只能有一张。
CREATE TABLE settlement_statement (
    settlement_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '结算单编号',
    statement_no VARCHAR(50) NOT NULL COMMENT '对外展示的结算单号',
    operator_id BIGINT UNSIGNED NOT NULL COMMENT '生成结算单时的运营商归属快照',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '结算场站编号',
    period_start DATE NOT NULL COMMENT '账期起始日期，包含该日',
    period_end DATE NOT NULL COMMENT '账期结束日期，不包含该日',
    electricity_share_rate DECIMAL(7,6) NOT NULL COMMENT '电费分成率快照',
    service_share_rate DECIMAL(7,6) NOT NULL COMMENT '服务费分成率快照',
    platform_fee_rate DECIMAL(7,6) NOT NULL COMMENT '平台服务费率快照',
    operator_discount_rate DECIMAL(7,6) NOT NULL COMMENT '优惠中运营商承担比例快照',
    total_kwh DECIMAL(16,3) NOT NULL DEFAULT 0.000 COMMENT '基础订单充电电量合计，kWh',
    total_electricity_fee DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '基础订单电费合计，元',
    total_service_fee DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '基础订单服务费合计，元',
    total_discount_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '基础订单优惠金额合计，元',
    total_refund_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '本账期退款流水原始金额合计，元',
    total_adjustment_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '退款冲减及其他调整的净影响，元',
    electricity_share_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '电费分成金额合计，元',
    service_share_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '服务费分成金额合计，元',
    platform_service_fee DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '平台服务费合计，元',
    payable_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '最终净结算金额，正数为平台应付、负数为运营商应返还或结转，元',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/GENERATED/CONFIRMED/PAID/VOID',
    generated_at DATETIME NULL COMMENT '结算明细和汇总生成完成时间',
    confirmed_at DATETIME NULL COMMENT '结算单确认完成时间',
    paid_at DATETIME NULL COMMENT '正向付款或负向返还完成后的资金结清时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (settlement_id),
    UNIQUE KEY uk_settlement_statement_no (statement_no),
    UNIQUE KEY uk_settlement_period (operator_id, station_id, period_start, period_end),
    KEY idx_settlement_status_period (status, period_end),
    KEY idx_settlement_station_period (station_id, period_start, period_end),
    CONSTRAINT fk_settlement_operator
        FOREIGN KEY (operator_id) REFERENCES `operator` (operator_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_settlement_station
        FOREIGN KEY (station_id) REFERENCES station (station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_settlement_period
        CHECK (period_start < period_end),
    CONSTRAINT ck_settlement_rates
        CHECK (
            electricity_share_rate BETWEEN 0 AND 1
            AND service_share_rate BETWEEN 0 AND 1
            AND platform_fee_rate BETWEEN 0 AND 1
            AND operator_discount_rate BETWEEN 0 AND 1
        ),
    -- total_adjustment_amount 与 payable_amount 是有方向的净额，允许跨期退款账期为负。
    CONSTRAINT ck_settlement_totals_valid
        CHECK (
            total_kwh >= 0
            AND total_electricity_fee >= 0
            AND total_service_fee >= 0
            AND total_discount_amount >= 0
            AND total_refund_amount >= 0
            AND electricity_share_amount >= 0
            AND service_share_amount >= 0
            AND platform_service_fee >= 0
        ),
    CONSTRAINT ck_settlement_status
        CHECK (status IN ('DRAFT', 'GENERATED', 'CONFIRMED', 'PAID', 'VOID')),
    CONSTRAINT ck_settlement_status_time
        CHECK (
            (status = 'DRAFT'
                AND generated_at IS NULL
                AND confirmed_at IS NULL
                AND paid_at IS NULL)
            OR
            (status = 'GENERATED'
                AND generated_at IS NOT NULL
                AND confirmed_at IS NULL
                AND paid_at IS NULL)
            OR
            (status = 'CONFIRMED'
                AND generated_at IS NOT NULL
                AND confirmed_at IS NOT NULL
                AND confirmed_at >= generated_at
                AND paid_at IS NULL)
            OR
            (status = 'PAID'
                AND generated_at IS NOT NULL
                AND confirmed_at IS NOT NULL
                AND paid_at IS NOT NULL
                AND confirmed_at >= generated_at
                AND paid_at >= confirmed_at)
            OR
            (status = 'VOID'
                AND confirmed_at IS NULL
                AND paid_at IS NULL)
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='运营商场站账期结算单';

-- 结算明细：基础订单、跨期退款冲减和人工调整共用一张可追溯明细表。
CREATE TABLE settlement_detail (
    settlement_detail_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '结算明细编号',
    settlement_id BIGINT UNSIGNED NOT NULL COMMENT '所属结算单编号',
    order_id BIGINT UNSIGNED NOT NULL COMMENT '可追溯的充电订单编号',
    detail_type VARCHAR(30) NOT NULL DEFAULT 'ORDER' COMMENT 'ORDER/REFUND_ADJUSTMENT/OTHER_ADJUSTMENT',
    original_detail_id BIGINT UNSIGNED NULL COMMENT '退款冲减所引用的原基础明细编号',
    payment_id BIGINT UNSIGNED NULL COMMENT '使订单首次达到足额支付的成功支付记录',
    refund_id BIGINT UNSIGNED NULL COMMENT '跨期冲减所引用的退款流水',
    event_at DATETIME NOT NULL COMMENT '决定本明细归属账期的业务发生时间',
    charging_kwh DECIMAL(12,3) NOT NULL DEFAULT 0.000 COMMENT '基础订单充电电量，kWh',
    electricity_fee DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '订单分段电费合计，元',
    service_fee DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '订单分段服务费合计，元',
    minimum_fee_adjustment DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '订单原价减分段电费和服务费后的补差，元',
    discount_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '基础订单优惠金额，元',
    refund_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '退款流水原始金额，元',
    adjustment_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '本明细对结算金额的调整，元，可正可负',
    electricity_share_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '本明细电费分成金额，元',
    service_share_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '本明细服务费分成金额，元',
    platform_service_fee DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '本明细平台服务费，元',
    payable_amount DECIMAL(14,2) NOT NULL DEFAULT 0.00 COMMENT '本明细对应结算单应结金额的影响，元',
    description VARCHAR(255) NULL COMMENT '订单或调整说明',
    base_order_id BIGINT UNSIGNED
        GENERATED ALWAYS AS (IF(detail_type = 'ORDER', order_id, NULL)) STORED
        COMMENT '仅基础订单映射订单编号，用于唯一约束',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (settlement_detail_id),
    UNIQUE KEY uk_detail_payment (payment_id),
    UNIQUE KEY uk_detail_refund (refund_id),
    UNIQUE KEY uk_detail_base_order (base_order_id),
    KEY idx_detail_statement_type_event (settlement_id, detail_type, event_at),
    KEY idx_detail_order_event (order_id, event_at),
    KEY idx_detail_original (original_detail_id),
    CONSTRAINT fk_detail_statement
        FOREIGN KEY (settlement_id) REFERENCES settlement_statement (settlement_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_detail_order
        FOREIGN KEY (order_id) REFERENCES charging_order (order_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_detail_original
        FOREIGN KEY (original_detail_id) REFERENCES settlement_detail (settlement_detail_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_detail_payment
        FOREIGN KEY (payment_id) REFERENCES payment_record (payment_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_detail_refund
        FOREIGN KEY (refund_id) REFERENCES refund_record (refund_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_detail_type
        CHECK (detail_type IN ('ORDER', 'REFUND_ADJUSTMENT', 'OTHER_ADJUSTMENT')),
    CONSTRAINT ck_detail_nonnegative
        CHECK (
            charging_kwh >= 0
            AND electricity_fee >= 0
            AND service_fee >= 0
            AND minimum_fee_adjustment >= 0
            AND discount_amount >= 0
            AND refund_amount >= 0
            AND electricity_share_amount >= 0
            AND service_share_amount >= 0
            AND platform_service_fee >= 0
        ),
    CONSTRAINT ck_detail_original_usage
        CHECK (
            (detail_type = 'REFUND_ADJUSTMENT' AND original_detail_id IS NOT NULL)
            OR
            (detail_type <> 'REFUND_ADJUSTMENT' AND original_detail_id IS NULL)
        ),
    CONSTRAINT ck_detail_shape
        CHECK (
            (detail_type = 'ORDER'
                AND payment_id IS NOT NULL
                AND refund_id IS NULL
                AND refund_amount = 0
                AND adjustment_amount = 0
                AND payable_amount >= 0
                AND discount_amount <= electricity_fee + service_fee + minimum_fee_adjustment)
            OR
            (detail_type = 'REFUND_ADJUSTMENT'
                AND payment_id IS NULL
                AND refund_id IS NOT NULL
                AND refund_amount > 0
                AND charging_kwh = 0
                AND electricity_fee = 0
                AND service_fee = 0
                AND minimum_fee_adjustment = 0
                AND discount_amount = 0
                AND electricity_share_amount = 0
                AND service_share_amount = 0
                AND platform_service_fee = 0
                AND adjustment_amount < 0
                AND payable_amount = adjustment_amount)
            OR
            (detail_type = 'OTHER_ADJUSTMENT'
                AND payment_id IS NULL
                AND refund_id IS NULL
                AND refund_amount = 0
                AND charging_kwh = 0
                AND electricity_fee = 0
                AND service_fee = 0
                AND minimum_fee_adjustment = 0
                AND discount_amount = 0
                AND electricity_share_amount = 0
                AND service_share_amount = 0
                AND platform_service_fee = 0
                AND adjustment_amount <> 0
                AND payable_amount = adjustment_amount
                AND description IS NOT NULL
                AND CHAR_LENGTH(TRIM(description)) > 0)
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='逐订单结算及跨期调整明细';

-- 对账差异：每条差异必须回指订单；调整明细由双方确认后的事务创建。
CREATE TABLE reconciliation_difference (
    difference_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '对账差异编号',
    settlement_id BIGINT UNSIGNED NOT NULL COMMENT '差异所属结算单编号',
    order_id BIGINT UNSIGNED NOT NULL COMMENT '产生差异的具体订单编号',
    difference_type VARCHAR(30) NOT NULL COMMENT 'ENERGY/PRICE/PAYMENT/REFUND/OTHER',
    expected_value DECIMAL(14,4) NULL COMMENT '系统侧预期数值',
    actual_value DECIMAL(14,4) NULL COMMENT '运营商提供的实际数值',
    difference_value DECIMAL(14,4)
        GENERATED ALWAYS AS (actual_value - expected_value) STORED
        COMMENT '实际值减系统预期值',
    difference_unit VARCHAR(20) NULL COMMENT 'CNY/kWh/CNY_per_kWh等单位',
    description VARCHAR(500) NULL COMMENT '差异原因及核查依据',
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING/CONFIRMED/REJECTED/RESOLVED',
    resolution VARCHAR(500) NULL COMMENT '双方确认后的最终处理结论',
    adjustment_detail_id BIGINT UNSIGNED NULL COMMENT '差异处理生成的OTHER_ADJUSTMENT明细',
    discovered_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '差异发现时间',
    resolved_at DATETIME NULL COMMENT '差异解决时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (difference_id),
    UNIQUE KEY uk_difference_adjustment_detail (adjustment_detail_id),
    KEY idx_difference_statement_status_time (settlement_id, status, discovered_at),
    KEY idx_difference_order_type (order_id, difference_type),
    CONSTRAINT fk_difference_statement
        FOREIGN KEY (settlement_id) REFERENCES settlement_statement (settlement_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_difference_order
        FOREIGN KEY (order_id) REFERENCES charging_order (order_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_difference_adjustment_detail
        FOREIGN KEY (adjustment_detail_id) REFERENCES settlement_detail (settlement_detail_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_difference_type
        CHECK (difference_type IN ('ENERGY', 'PRICE', 'PAYMENT', 'REFUND', 'OTHER')),
    CONSTRAINT ck_difference_value_pair
        CHECK (
            (expected_value IS NULL AND actual_value IS NULL AND difference_unit IS NULL)
            OR
            (expected_value IS NOT NULL AND actual_value IS NOT NULL AND difference_unit IS NOT NULL)
        ),
    CONSTRAINT ck_difference_status
        CHECK (status IN ('PENDING', 'CONFIRMED', 'REJECTED', 'RESOLVED')),
    CONSTRAINT ck_difference_state_time
        CHECK (
            (status = 'PENDING'
                AND resolution IS NULL
                AND adjustment_detail_id IS NULL
                AND resolved_at IS NULL)
            OR
            (status IN ('CONFIRMED', 'REJECTED')
                AND resolution IS NOT NULL
                AND CHAR_LENGTH(TRIM(resolution)) > 0
                AND adjustment_detail_id IS NULL
                AND resolved_at IS NULL)
            OR
            (status = 'RESOLVED'
                AND resolution IS NOT NULL
                AND CHAR_LENGTH(TRIM(resolution)) > 0
                AND adjustment_detail_id IS NOT NULL
                AND resolved_at IS NOT NULL
                AND resolved_at >= discovered_at)
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='逐订单对账差异';

-- 确认历史：平台与运营商每次操作均追加记录，不覆盖旧结论。
CREATE TABLE reconciliation_confirmation (
    confirmation_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '差异确认记录编号',
    difference_id BIGINT UNSIGNED NOT NULL COMMENT '被确认的差异编号',
    confirming_party VARCHAR(20) NOT NULL COMMENT 'PLATFORM/OPERATOR',
    confirmer_name VARCHAR(100) NOT NULL COMMENT '确认人员姓名或业务标识，受权限控制',
    confirmation_result VARCHAR(20) NOT NULL COMMENT 'AGREE/REJECT',
    confirmation_note VARCHAR(500) NULL COMMENT '确认意见或拒绝原因',
    confirmed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '业务确认时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (confirmation_id),
    KEY idx_confirmation_difference_party_id
        (difference_id, confirming_party, confirmation_id),
    CONSTRAINT fk_confirmation_difference
        FOREIGN KEY (difference_id) REFERENCES reconciliation_difference (difference_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_confirmation_party
        CHECK (confirming_party IN ('PLATFORM', 'OPERATOR')),
    CONSTRAINT ck_confirmation_result
        CHECK (confirmation_result IN ('AGREE', 'REJECT'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='平台与运营商对账差异确认历史';

-- 发票记录：金额始终存正数，invoice_type 决定净开票额中的正负方向。
CREATE TABLE invoice_record (
    invoice_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '发票记录编号',
    settlement_id BIGINT UNSIGNED NOT NULL COMMENT '所属结算单编号',
    invoice_number VARCHAR(50) NULL COMMENT '正式开具后的发票号码',
    invoice_type VARCHAR(20) NOT NULL DEFAULT 'NORMAL' COMMENT 'NORMAL/RED_LETTER',
    invoice_title VARCHAR(200) NOT NULL COMMENT '发票抬头',
    tax_number_ciphertext VARBINARY(512) NULL COMMENT '加密保存的纳税人识别号',
    invoice_amount DECIMAL(14,2) NOT NULL COMMENT '发票金额，始终存正数，元',
    issued_at DATETIME NULL COMMENT '发票实际开具时间',
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING/ISSUED/RED_FLUSHED/CANCELLED',
    original_invoice_id BIGINT UNSIGNED NULL COMMENT '红字发票所对应的原普通发票记录',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (invoice_id),
    UNIQUE KEY uk_invoice_number (invoice_number),
    KEY idx_invoice_settlement_status_time (settlement_id, status, issued_at),
    KEY idx_invoice_original (original_invoice_id),
    CONSTRAINT fk_invoice_settlement
        FOREIGN KEY (settlement_id) REFERENCES settlement_statement (settlement_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_invoice_original
        FOREIGN KEY (original_invoice_id) REFERENCES invoice_record (invoice_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_invoice_type
        CHECK (invoice_type IN ('NORMAL', 'RED_LETTER')),
    CONSTRAINT ck_invoice_amount
        CHECK (invoice_amount > 0),
    CONSTRAINT ck_invoice_status
        CHECK (status IN ('PENDING', 'ISSUED', 'RED_FLUSHED', 'CANCELLED')),
    CONSTRAINT ck_invoice_reference
        CHECK (
            (invoice_type = 'NORMAL' AND original_invoice_id IS NULL)
            OR
            (invoice_type = 'RED_LETTER'
                AND original_invoice_id IS NOT NULL)
        ),
    CONSTRAINT ck_invoice_state_time
        CHECK (
            (status = 'PENDING'
                AND invoice_number IS NULL
                AND issued_at IS NULL)
            OR
            (status = 'ISSUED'
                AND invoice_number IS NOT NULL
                AND issued_at IS NOT NULL)
            OR
            (status = 'RED_FLUSHED'
                AND invoice_type = 'NORMAL'
                AND invoice_number IS NOT NULL
                AND issued_at IS NOT NULL)
            OR
            (status = 'CANCELLED'
                AND invoice_number IS NULL
                AND issued_at IS NULL)
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='结算单普通发票与红字发票记录';
