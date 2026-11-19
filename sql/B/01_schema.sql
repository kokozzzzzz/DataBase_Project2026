-- B 第二天正式结构，目标 MySQL 8.0.46+ / InnoDB。先创建 D 的 user、vehicle。
-- 用于首次建表；已有 B 表时先核对差异并制定迁移。DDL 会隐式提交。
USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

CREATE TABLE `operator` (
 operator_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 name VARCHAR(100) NOT NULL UNIQUE COMMENT '运营商名称'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='运营商档案';
CREATE TABLE station (
 station_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 operator_id BIGINT UNSIGNED NOT NULL,
 name VARCHAR(100) NOT NULL, address VARCHAR(255) NOT NULL,
 longitude DECIMAL(9,6) NOT NULL, latitude DECIMAL(8,6) NOT NULL,
 parking_fee_hour DECIMAL(9,2) NOT NULL DEFAULT 0,
 opens_minute SMALLINT UNSIGNED NOT NULL DEFAULT 0,
 closes_minute SMALLINT UNSIGNED NOT NULL DEFAULT 1440,
 status ENUM('OPEN','CLOSED') NOT NULL DEFAULT 'OPEN',
 UNIQUE KEY uq_station_operator_name(operator_id,name),
 FOREIGN KEY(operator_id) REFERENCES `operator`(operator_id),
 CHECK(longitude BETWEEN -180 AND 180 AND latitude BETWEEN -90 AND 90),
 CHECK(parking_fee_hour>=0 AND opens_minute<closes_minute AND closes_minute<=1440)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='场站档案。车位总数由车位记录统计';
CREATE TABLE charging_pile (
 pile_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 station_id BIGINT UNSIGNED NOT NULL,
 serial_no VARCHAR(64) NOT NULL UNIQUE, model VARCHAR(64) NOT NULL,
 protocol VARCHAR(40) NOT NULL, rated_kw DECIMAL(8,2) NOT NULL,
 accepted_at DATETIME NULL, acceptance_status ENUM('PENDING','PASSED','FAILED') NOT NULL DEFAULT 'PENDING',
 commissioned_on DATE NULL, warranty_until DATE NULL,
 last_heartbeat_at DATETIME NULL,
 status ENUM('READY','OFFLINE','FAULT') NOT NULL DEFAULT 'OFFLINE',
 UNIQUE KEY uq_pile_station(pile_id,station_id),
 KEY ix_pile_station_warranty(station_id,warranty_until),
 FOREIGN KEY(station_id) REFERENCES station(station_id),
 CHECK(rated_kw>0),
 CHECK(commissioned_on IS NULL OR acceptance_status='PASSED'),
 CHECK(warranty_until IS NULL OR commissioned_on IS NULL OR warranty_until>=commissioned_on)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='充电桩。枪数由所属枪明细统计';
CREATE TABLE parking_space (
 parking_space_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 station_id BIGINT UNSIGNED NOT NULL, code VARCHAR(30) NOT NULL,
 UNIQUE KEY uq_station_space_code(station_id,code),
 UNIQUE KEY uq_space_station(parking_space_id,station_id),
 FOREIGN KEY(station_id) REFERENCES station(station_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='车位档案。实际占用由A提供';
CREATE TABLE charging_gun (
 gun_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 pile_id BIGINT UNSIGNED NOT NULL, station_id BIGINT UNSIGNED NOT NULL,
 parking_space_id BIGINT UNSIGNED NOT NULL UNIQUE,
 gun_no SMALLINT UNSIGNED NOT NULL,
 gun_type ENUM('DC','AC') NOT NULL, interface_type VARCHAR(40) NOT NULL,
 max_kw DECIMAL(8,2) NOT NULL, status ENUM('READY','FAULT','DISABLED','OFFLINE') NOT NULL DEFAULT 'READY',
 UNIQUE KEY uq_pile_gun_no(pile_id,gun_no),
 UNIQUE KEY uq_gun_station(gun_id,station_id),
 FOREIGN KEY(pile_id,station_id) REFERENCES charging_pile(pile_id,station_id),
 FOREIGN KEY(parking_space_id,station_id) REFERENCES parking_space(parking_space_id,station_id),
 CHECK(max_kw>0 AND gun_no>0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='充电枪。站点列用于复合外键保证车位和桩同站';
CREATE TABLE equipment_status_log (
 log_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 pile_id BIGINT UNSIGNED NULL, gun_id BIGINT UNSIGNED NULL,
 old_status VARCHAR(20) NULL, new_status VARCHAR(20) NOT NULL,
 changed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
 KEY ix_log_pile_time(pile_id,changed_at), KEY ix_log_gun_time(gun_id,changed_at),
 FOREIGN KEY(pile_id) REFERENCES charging_pile(pile_id),
 FOREIGN KEY(gun_id) REFERENCES charging_gun(gun_id),
 CHECK((pile_id IS NULL) <> (gun_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='桩和枪设备状态日志。交易占用另由进行中订单推导';
CREATE TABLE equipment_outage_plan (
 outage_plan_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 station_id BIGINT UNSIGNED NOT NULL, gun_id BIGINT UNSIGNED NULL,
 starts_at DATETIME NOT NULL, ends_at DATETIME NOT NULL, reason VARCHAR(255) NOT NULL,
 status ENUM('SCHEDULED','CANCELLED','COMPLETED') NOT NULL DEFAULT 'SCHEDULED',
 KEY ix_outage_station_time(station_id,status,starts_at,ends_at),
 FOREIGN KEY(station_id) REFERENCES station(station_id),
 FOREIGN KEY(gun_id,station_id) REFERENCES charging_gun(gun_id,station_id),
 CHECK(starts_at<ends_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='共享停运计划。枪为空表示全站';
CREATE TABLE equipment_change_request (
 request_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 pile_id BIGINT UNSIGNED NOT NULL, requester_id BIGINT UNSIGNED NOT NULL,
 old_model VARCHAR(64) NOT NULL, proposed_model VARCHAR(64) NOT NULL,
 reason VARCHAR(255) NOT NULL, requested_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 state ENUM('PENDING','APPROVED','REJECTED') NOT NULL DEFAULT 'PENDING',
 reviewer_id BIGINT UNSIGNED NULL, reviewed_at DATETIME NULL,
 FOREIGN KEY(pile_id) REFERENCES charging_pile(pile_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='铭牌型号变更申请及审批';
CREATE TABLE equipment_offline_task (
 task_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 pile_id BIGINT UNSIGNED NOT NULL, created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 closed_at DATETIME NULL,
 active_pile_id BIGINT UNSIGNED GENERATED ALWAYS AS (IF(closed_at IS NULL,pile_id,NULL)) STORED,
 UNIQUE KEY uq_offline_open(active_pile_id),
 FOREIGN KEY(pile_id) REFERENCES charging_pile(pile_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='给C的设备离线待办。每桩最多一项未关闭';
CREATE TABLE tariff_rule (
 rule_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 station_id BIGINT UNSIGNED NOT NULL,
 valid_from DATE NOT NULL, valid_until DATE NOT NULL,
 free_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '只免服务费',
 minimum_fee DECIMAL(9,2) NOT NULL DEFAULT 0 COMMENT '优惠前最低费用',
 UNIQUE KEY uq_tariff_station_start(station_id,valid_from),
 FOREIGN KEY(station_id) REFERENCES station(station_id),
 CHECK(valid_from<valid_until AND minimum_fee>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='场站费率版本。日期区间左闭右开';
CREATE TABLE tariff_band (
 band_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT, rule_id BIGINT UNSIGNED NOT NULL,
 starts_minute SMALLINT UNSIGNED NOT NULL, ends_minute SMALLINT UNSIGNED NOT NULL,
 label ENUM('VALLEY','FLAT','PEAK') NOT NULL,
 energy_price DECIMAL(9,4) NOT NULL, service_price DECIMAL(9,4) NOT NULL,
 service_basis ENUM('KWH','MINUTE') NOT NULL DEFAULT 'KWH',
 UNIQUE KEY uq_band_rule_start(rule_id,starts_minute),
 FOREIGN KEY(rule_id) REFERENCES tariff_rule(rule_id),
 CHECK(starts_minute<ends_minute AND ends_minute<=1440 AND energy_price>=0 AND service_price>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='费率版本的日内分段';
CREATE TABLE charging_order (
 order_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 gun_id BIGINT UNSIGNED NOT NULL, user_id BIGINT UNSIGNED NOT NULL,
 vehicle_id BIGINT UNSIGNED NOT NULL,
 channel ENUM('DIRECT','RESERVATION','QUEUE') NOT NULL DEFAULT 'DIRECT',
 admission_id BIGINT UNSIGNED NULL,
 starts_at DATETIME NOT NULL, ends_at DATETIME NULL,
 start_soc TINYINT UNSIGNED NULL, end_soc TINYINT UNSIGNED NULL,
 state ENUM('ACTIVE','REVIEW','BILLED') NOT NULL DEFAULT 'ACTIVE',
 active_gun_id BIGINT UNSIGNED GENERATED ALWAYS AS (IF(state='ACTIVE',gun_id,NULL)) STORED,
 total_kwh DECIMAL(12,3) NULL, gross_amount DECIMAL(12,2) NULL,
 discount_amount DECIMAL(12,2) NOT NULL DEFAULT 0, confirmed_at DATETIME NULL,
 review_reason VARCHAR(255) NULL, review_note VARCHAR(255) NULL,
 UNIQUE KEY uq_one_active_order_per_gun(active_gun_id),
 UNIQUE KEY uq_admission_use(channel,admission_id),
 KEY ix_order_gun_time(gun_id,starts_at), KEY ix_order_user_time(user_id,starts_at,order_id),
 CONSTRAINT fk_b_order_user FOREIGN KEY(user_id) REFERENCES `user`(user_id),
 CONSTRAINT fk_b_order_vehicle FOREIGN KEY(vehicle_id) REFERENCES vehicle(vehicle_id),
 FOREIGN KEY(gun_id) REFERENCES charging_gun(gun_id),
 CHECK((channel='DIRECT')=(admission_id IS NULL)),
 CHECK(start_soc<=100 AND end_soc<=100),
 CHECK(ends_at>=starts_at),
 CHECK(confirmed_at IS NULL OR (state='BILLED' AND confirmed_at>=ends_at)),
 CHECK(total_kwh>=0 AND gross_amount>=0 AND discount_amount>=0 AND discount_amount<=gross_amount),
 CHECK((state='ACTIVE' AND ends_at IS NULL AND gross_amount IS NULL)
    OR (state='REVIEW' AND ends_at IS NOT NULL AND review_reason IS NOT NULL AND gross_amount IS NULL)
    OR (state='BILLED' AND ends_at IS NOT NULL AND gross_amount IS NOT NULL AND total_kwh IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='充电订单。用户车辆外键接D；A资格映射待接入';
CREATE TABLE meter_reading (
 order_id BIGINT UNSIGNED NOT NULL, read_at DATETIME NOT NULL,
 cumulative_kwh DECIMAL(12,3) NOT NULL,
 PRIMARY KEY(order_id,read_at),
 FOREIGN KEY(order_id) REFERENCES charging_order(order_id),
 CHECK(cumulative_kwh>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='订单累计表读数';
CREATE TABLE order_fee_detail (
 fee_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 order_id BIGINT UNSIGNED NOT NULL, band_id BIGINT UNSIGNED NOT NULL,
 starts_at DATETIME NOT NULL, ends_at DATETIME NOT NULL,
 kwh DECIMAL(12,3) NOT NULL, energy_price DECIMAL(9,4) NOT NULL,
 service_price DECIMAL(9,4) NOT NULL, service_basis ENUM('KWH','MINUTE') NOT NULL,
 service_units DECIMAL(13,6) NOT NULL,
 energy_amount DECIMAL(12,2) NOT NULL, service_amount DECIMAL(12,2) NOT NULL,
 UNIQUE KEY uq_order_segment(order_id,starts_at),
 FOREIGN KEY(order_id) REFERENCES charging_order(order_id),
 FOREIGN KEY(band_id) REFERENCES tariff_band(band_id),
 CHECK(energy_price>=0 AND service_price>=0),
 CHECK(starts_at<ends_at AND kwh>=0 AND service_units>=0 AND energy_amount>=0 AND service_amount>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='费用分段快照。起步补差由原价减分段合计取得';
CREATE TABLE payment_record (
 payment_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 order_id BIGINT UNSIGNED NOT NULL,
 channel VARCHAR(24) NOT NULL, trade_ref VARCHAR(64) COLLATE utf8mb4_bin NOT NULL,
 amount DECIMAL(12,2) NOT NULL, status ENUM('SUCCESS','FAILED') NOT NULL,
 occurred_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 UNIQUE KEY uq_trade(channel,trade_ref), KEY ix_payment_order_status(order_id,status),
 FOREIGN KEY(order_id) REFERENCES charging_order(order_id), CHECK(amount>0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='支付或失败凭证。多次支付允许补缴';
CREATE TABLE refund_record (
 refund_id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
 payment_id BIGINT UNSIGNED NOT NULL, refund_ref VARCHAR(64) COLLATE utf8mb4_bin NOT NULL UNIQUE,
 amount DECIMAL(12,2) NOT NULL, reason VARCHAR(255) NOT NULL,
 occurred_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY(payment_id) REFERENCES payment_record(payment_id), CHECK(amount>0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='成功退款流水。回指原成功支付';
