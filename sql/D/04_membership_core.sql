-- ④ 用户与会员运营：核心表
-- 适用环境：MySQL 8.0.46 / InnoDB / utf8mb4
-- 前置条件：数据库 charging_platform 已由全组公共脚本创建。
-- 本脚本只创建 D 模块内部依赖表，不依赖 B 模块的 station、charging_order。
-- 安全说明：本脚本不包含 DROP、TRUNCATE 或 DELETE。

USE charging_platform;
SET NAMES utf8mb4;

CREATE TABLE membership_level (
    level_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '会员等级编号',
    level_code VARCHAR(30) NOT NULL COMMENT '会员等级业务编码',
    level_name VARCHAR(50) NOT NULL COMMENT '会员等级名称',
    description VARCHAR(500) NULL COMMENT '等级权益或说明',
    sort_order INT UNSIGNED NOT NULL DEFAULT 0 COMMENT '展示顺序，数值越小越靠前',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'ACTIVE/INACTIVE',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (level_id),
    UNIQUE KEY uk_membership_level_code (level_code),
    UNIQUE KEY uk_membership_level_name (level_name),
    CONSTRAINT ck_membership_level_status
        CHECK (status IN ('ACTIVE', 'INACTIVE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='会员等级字典';

CREATE TABLE `user` (
    user_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '用户编号',
    phone_ciphertext VARBINARY(512) NOT NULL COMMENT '手机号密文',
    phone_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT '手机号HMAC-SHA256摘要',
    real_name VARCHAR(50) NULL COMMENT '用户真实姓名，受权限控制',
    real_name_status VARCHAR(20) NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING/VERIFIED/REJECTED',
    registration_channel VARCHAR(30) NULL COMMENT 'APP/WEB/WECHAT/OTHER',
    registered_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '注册时间',
    level_id BIGINT UNSIGNED NULL COMMENT '当前会员等级编号',
    balance DECIMAL(12,2) NOT NULL DEFAULT 0.00 COMMENT '账户余额，单位元',
    user_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'ACTIVE/DISABLED/CLOSED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uk_user_phone_hash (phone_hash),
    KEY idx_user_level_id (level_id),
    KEY idx_user_status_registered (user_status, registered_at),
    CONSTRAINT fk_user_membership_level
        FOREIGN KEY (level_id) REFERENCES membership_level (level_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_user_real_name_status
        CHECK (real_name_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    CONSTRAINT ck_user_status
        CHECK (user_status IN ('ACTIVE', 'DISABLED', 'CLOSED')),
    CONSTRAINT ck_user_balance
        CHECK (balance >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='车主用户主数据';

CREATE TABLE vehicle (
    vehicle_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '车辆编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '当前所属用户编号',
    plate_ciphertext VARBINARY(512) NOT NULL COMMENT '车牌号密文',
    plate_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT '车牌号HMAC-SHA256摘要',
    model VARCHAR(100) NULL COMMENT '车辆品牌及型号',
    battery_capacity_kwh DECIMAL(8,2) NULL COMMENT '电池容量，单位kWh',
    max_charging_power_kw DECIMAL(8,2) NULL COMMENT '最大充电功率，单位kW',
    fast_charge_supported TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否支持快充：0否1是',
    vehicle_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'ACTIVE/DISABLED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (vehicle_id),
    UNIQUE KEY uk_vehicle_plate_hash (plate_hash),
    KEY idx_vehicle_user_status (user_id, vehicle_status),
    CONSTRAINT fk_vehicle_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_vehicle_battery_capacity
        CHECK (battery_capacity_kwh IS NULL OR battery_capacity_kwh > 0),
    CONSTRAINT ck_vehicle_max_power
        CHECK (max_charging_power_kw IS NULL OR max_charging_power_kw > 0),
    CONSTRAINT ck_vehicle_fast_charge
        CHECK (fast_charge_supported IN (0, 1)),
    CONSTRAINT ck_vehicle_status
        CHECK (vehicle_status IN ('ACTIVE', 'DISABLED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='用户车辆主数据';

CREATE TABLE membership_record (
    membership_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '会员等级变更记录编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '用户编号',
    level_id BIGINT UNSIGNED NOT NULL COMMENT '变更后的会员等级编号',
    change_type VARCHAR(20) NOT NULL COMMENT 'INITIAL/UPGRADE/DOWNGRADE/ADJUST',
    effective_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '业务生效时间',
    change_reason VARCHAR(255) NULL COMMENT '等级变更原因',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (membership_record_id),
    KEY idx_membership_record_user_time (user_id, effective_at),
    KEY idx_membership_record_level (level_id),
    CONSTRAINT fk_membership_record_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_membership_record_level
        FOREIGN KEY (level_id) REFERENCES membership_level (level_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_membership_record_change_type
        CHECK (change_type IN ('INITIAL', 'UPGRADE', 'DOWNGRADE', 'ADJUST'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='用户会员等级变更历史';

CREATE TABLE promotion (
    promotion_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '优惠活动编号',
    promotion_name VARCHAR(100) NOT NULL COMMENT '优惠活动名称',
    description TEXT NULL COMMENT '活动规则说明',
    discount_type VARCHAR(20) NOT NULL DEFAULT 'FIXED' COMMENT 'FIXED/PERCENTAGE',
    discount_value DECIMAL(10,4) NOT NULL COMMENT '固定减免金额或实付比例；0.80表示八折',
    minimum_spend DECIMAL(12,2) NOT NULL DEFAULT 0.00 COMMENT '最低消费门槛，单位元',
    max_discount_amount DECIMAL(12,2) NULL COMMENT '百分比优惠封顶金额，单位元',
    applicability_scope VARCHAR(20) NOT NULL DEFAULT 'SELECTED' COMMENT 'ALL/SELECTED',
    total_quantity INT UNSIGNED NULL COMMENT '计划发放总量，NULL表示不限量',
    per_user_limit INT UNSIGNED NOT NULL DEFAULT 1 COMMENT '单用户限领数量',
    valid_from DATETIME NOT NULL COMMENT '活动开始时间',
    valid_to DATETIME NOT NULL COMMENT '活动结束时间',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/ACTIVE/PAUSED/ENDED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (promotion_id),
    KEY idx_promotion_status_time (status, valid_from, valid_to),
    CONSTRAINT ck_promotion_discount_type
        CHECK (discount_type IN ('FIXED', 'PERCENTAGE')),
    CONSTRAINT ck_promotion_discount_value
        CHECK (
            (discount_type = 'FIXED' AND discount_value > 0)
            OR
            (discount_type = 'PERCENTAGE' AND discount_value > 0 AND discount_value <= 1)
        ),
    CONSTRAINT ck_promotion_minimum_spend
        CHECK (minimum_spend >= 0),
    CONSTRAINT ck_promotion_max_discount
        CHECK (max_discount_amount IS NULL OR max_discount_amount > 0),
    CONSTRAINT ck_promotion_scope
        CHECK (applicability_scope IN ('ALL', 'SELECTED')),
    CONSTRAINT ck_promotion_total_quantity
        CHECK (total_quantity IS NULL OR total_quantity > 0),
    CONSTRAINT ck_promotion_per_user_limit
        CHECK (per_user_limit > 0),
    CONSTRAINT ck_promotion_valid_time
        CHECK (valid_from < valid_to),
    CONSTRAINT ck_promotion_status
        CHECK (status IN ('DRAFT', 'ACTIVE', 'PAUSED', 'ENDED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='优惠活动规则';

CREATE TABLE enterprise_customer (
    enterprise_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '企业客户编号',
    enterprise_name VARCHAR(150) NOT NULL COMMENT '企业客户名称',
    credit_code_ciphertext VARBINARY(512) NULL COMMENT '统一社会信用代码密文',
    credit_code_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL COMMENT '统一社会信用代码HMAC摘要',
    contact_name VARCHAR(50) NULL COMMENT '企业联系人',
    contact_phone_ciphertext VARBINARY(512) NULL COMMENT '联系人手机号密文',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'ACTIVE/DISABLED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (enterprise_id),
    UNIQUE KEY uk_enterprise_credit_code_hash (credit_code_hash),
    KEY idx_enterprise_status (status),
    CONSTRAINT ck_enterprise_status
        CHECK (status IN ('ACTIVE', 'DISABLED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='企业客户主数据';

CREATE TABLE fleet (
    fleet_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '车队编号',
    enterprise_id BIGINT UNSIGNED NOT NULL COMMENT '所属企业客户编号',
    fleet_name VARCHAR(100) NOT NULL COMMENT '车队名称',
    contact_name VARCHAR(50) NULL COMMENT '车队联系人',
    contact_phone_ciphertext VARBINARY(512) NULL COMMENT '联系人手机号密文',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'ACTIVE/DISABLED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (fleet_id),
    UNIQUE KEY uk_fleet_enterprise_name (enterprise_id, fleet_name),
    KEY idx_fleet_status (status),
    CONSTRAINT fk_fleet_enterprise
        FOREIGN KEY (enterprise_id) REFERENCES enterprise_customer (enterprise_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_fleet_status
        CHECK (status IN ('ACTIVE', 'DISABLED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='企业下属车队';

CREATE TABLE fleet_vehicle (
    fleet_vehicle_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '车队车辆关联记录编号',
    fleet_id BIGINT UNSIGNED NOT NULL COMMENT '车队编号',
    vehicle_id BIGINT UNSIGNED NOT NULL COMMENT '车辆编号',
    joined_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '加入车队时间',
    left_at DATETIME NULL COMMENT '退出车队时间',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'ACTIVE/LEFT',
    PRIMARY KEY (fleet_vehicle_id),
    UNIQUE KEY uk_fleet_vehicle_joined (fleet_id, vehicle_id, joined_at),
    KEY idx_fleet_vehicle_vehicle_time (vehicle_id, joined_at, left_at),
    KEY idx_fleet_vehicle_fleet_status (fleet_id, status),
    CONSTRAINT fk_fleet_vehicle_fleet
        FOREIGN KEY (fleet_id) REFERENCES fleet (fleet_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_fleet_vehicle_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_fleet_vehicle_status
        CHECK (status IN ('ACTIVE', 'LEFT')),
    CONSTRAINT ck_fleet_vehicle_state_time
        CHECK (
            (status = 'ACTIVE' AND left_at IS NULL)
            OR
            (status = 'LEFT' AND left_at IS NOT NULL AND left_at >= joined_at)
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='车队车辆历史关联；同一车辆ACTIVE唯一性由业务事务或触发器保证';

CREATE TABLE fleet_quota_record (
    quota_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '额度记录编号',
    quota_scope VARCHAR(20) NOT NULL COMMENT 'ENTERPRISE/FLEET/VEHICLE',
    enterprise_id BIGINT UNSIGNED NULL COMMENT '企业客户编号',
    fleet_id BIGINT UNSIGNED NULL COMMENT '车队编号',
    vehicle_id BIGINT UNSIGNED NULL COMMENT '车辆编号',
    quota_type VARCHAR(20) NOT NULL COMMENT 'AMOUNT/ENERGY/ORDER_COUNT',
    quota_limit DECIMAL(14,2) NOT NULL COMMENT '额度上限',
    period_start DATETIME NOT NULL COMMENT '额度周期开始时间',
    period_end DATETIME NOT NULL COMMENT '额度周期结束时间',
    change_reason VARCHAR(255) NULL COMMENT '额度设置或变更原因',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (quota_record_id),
    KEY idx_quota_enterprise_period (enterprise_id, period_start, period_end),
    KEY idx_quota_fleet_period (fleet_id, period_start, period_end),
    KEY idx_quota_vehicle_period (vehicle_id, period_start, period_end),
    CONSTRAINT fk_quota_enterprise
        FOREIGN KEY (enterprise_id) REFERENCES enterprise_customer (enterprise_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_quota_fleet
        FOREIGN KEY (fleet_id) REFERENCES fleet (fleet_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_quota_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_quota_scope
        CHECK (quota_scope IN ('ENTERPRISE', 'FLEET', 'VEHICLE')),
    CONSTRAINT ck_quota_scope_reference
        CHECK (
            (quota_scope = 'ENTERPRISE' AND enterprise_id IS NOT NULL AND fleet_id IS NULL AND vehicle_id IS NULL)
            OR
            (quota_scope = 'FLEET' AND enterprise_id IS NULL AND fleet_id IS NOT NULL AND vehicle_id IS NULL)
            OR
            (quota_scope = 'VEHICLE' AND enterprise_id IS NULL AND fleet_id IS NULL AND vehicle_id IS NOT NULL)
        ),
    CONSTRAINT ck_quota_type
        CHECK (quota_type IN ('AMOUNT', 'ENERGY', 'ORDER_COUNT')),
    CONSTRAINT ck_quota_limit
        CHECK (quota_limit >= 0),
    CONSTRAINT ck_quota_order_count_integer
        CHECK (quota_type <> 'ORDER_COUNT' OR quota_limit = FLOOR(quota_limit)),
    CONSTRAINT ck_quota_period
        CHECK (period_start < period_end)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='企业、车队或车辆额度设置历史';

