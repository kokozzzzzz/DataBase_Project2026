-- ④ 用户与会员运营：跨模块关联表
-- 适用环境：MySQL 8.0.46 / InnoDB / utf8mb4
-- 执行顺序：
--   1. 先执行 sql/D/04_membership_core.sql。
--   2. B 模块创建 station、charging_order 后，再执行本脚本。
-- 安全说明：本脚本不包含 DROP、TRUNCATE 或 DELETE。

USE charging_platform;
SET NAMES utf8mb4;

CREATE TABLE promotion_station (
    promotion_id BIGINT UNSIGNED NOT NULL COMMENT '优惠活动编号',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '适用场站编号，由B模块维护',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (promotion_id, station_id),
    KEY idx_promotion_station_station (station_id, promotion_id),
    CONSTRAINT fk_promotion_station_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotion (promotion_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_promotion_station_station
        FOREIGN KEY (station_id) REFERENCES station (station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='优惠活动适用场站关联';

CREATE TABLE coupon (
    coupon_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '优惠券实例编号',
    coupon_code VARCHAR(64) COLLATE utf8mb4_bin NOT NULL COMMENT '优惠券业务识别码',
    promotion_id BIGINT UNSIGNED NOT NULL COMMENT '来源活动编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '持券用户编号',
    issued_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '实际发放时间',
    valid_from DATETIME NOT NULL COMMENT '券有效开始时间',
    valid_to DATETIME NOT NULL COMMENT '券有效结束时间',
    status VARCHAR(20) NOT NULL DEFAULT 'AVAILABLE' COMMENT 'AVAILABLE/LOCKED/USED/EXPIRED/CANCELLED',
    locked_order_id BIGINT UNSIGNED NULL COMMENT '当前锁定订单编号',
    locked_at DATETIME NULL COMMENT '锁券时间',
    used_at DATETIME NULL COMMENT '成功核销时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (coupon_id),
    UNIQUE KEY uk_coupon_code (coupon_code),
    KEY idx_coupon_promotion (promotion_id),
    KEY idx_coupon_user_status_time (user_id, status, valid_to),
    KEY idx_coupon_locked_order (locked_order_id),
    CONSTRAINT fk_coupon_promotion
        FOREIGN KEY (promotion_id) REFERENCES promotion (promotion_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_coupon_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_coupon_locked_order
        FOREIGN KEY (locked_order_id) REFERENCES charging_order (order_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_coupon_valid_time
        CHECK (valid_from < valid_to),
    CONSTRAINT ck_coupon_issue_time
        CHECK (issued_at <= valid_to),
    CONSTRAINT ck_coupon_status
        CHECK (status IN ('AVAILABLE', 'LOCKED', 'USED', 'EXPIRED', 'CANCELLED')),
    CONSTRAINT ck_coupon_status_time
        CHECK (
            (status = 'AVAILABLE' AND locked_order_id IS NULL AND locked_at IS NULL AND used_at IS NULL)
            OR
            (status = 'LOCKED' AND locked_order_id IS NOT NULL AND locked_at IS NOT NULL AND used_at IS NULL)
            OR
            (status = 'USED' AND used_at IS NOT NULL)
            OR
            (status IN ('EXPIRED', 'CANCELLED') AND used_at IS NULL)
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='用户持有的优惠券实例';

CREATE TABLE coupon_redemption (
    redemption_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '核销记录编号',
    coupon_id BIGINT UNSIGNED NOT NULL COMMENT '优惠券编号',
    order_id BIGINT UNSIGNED NOT NULL COMMENT '充电订单编号，由B模块维护',
    discount_amount DECIMAL(12,2) NOT NULL COMMENT '实际优惠金额，单位元',
    redeemed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '成功核销时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (redemption_id),
    UNIQUE KEY uk_redemption_coupon (coupon_id),
    UNIQUE KEY uk_redemption_order (order_id),
    KEY idx_redemption_time (redeemed_at),
    CONSTRAINT fk_redemption_coupon
        FOREIGN KEY (coupon_id) REFERENCES coupon (coupon_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_redemption_order
        FOREIGN KEY (order_id) REFERENCES charging_order (order_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_redemption_discount
        CHECK (discount_amount >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='优惠券成功核销记录';

