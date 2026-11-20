-- C: device monitoring, maintenance and spare-part inventory.
-- Prerequisites: charging_platform and B's 16 tables already exist.
-- Device IDs are logical cross-module references as agreed in yX/README.md.
USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

CREATE TABLE device_telemetry (
    telemetry_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    pile_id BIGINT UNSIGNED NOT NULL,
    gun_id BIGINT UNSIGNED NULL,
    collect_time DATETIME(6) NOT NULL,
    voltage DECIMAL(8,2) NULL,
    current DECIMAL(8,2) NULL,
    power DECIMAL(10,2) NULL,
    module_temp DECIMAL(6,2) NULL,
    offline_duration_sec INT UNSIGNED NOT NULL DEFAULT 0,
    fault_code VARCHAR(50) NULL,
    quality_flag VARCHAR(20) NOT NULL DEFAULT 'NORMAL',
    PRIMARY KEY (telemetry_id),
    KEY ix_telemetry_pile_time (pile_id, collect_time),
    KEY ix_telemetry_gun_time (gun_id, collect_time),
    KEY ix_telemetry_fault_time (fault_code, collect_time),
    CONSTRAINT ck_telemetry_measurements CHECK (
        (voltage IS NULL OR voltage >= 0)
        AND (current IS NULL OR current >= 0)
        AND (power IS NULL OR power >= 0)
        AND (module_temp IS NULL OR module_temp BETWEEN -50 AND 200)
    ),
    CONSTRAINT ck_telemetry_quality CHECK (
        quality_flag IN ('NORMAL', 'ABNORMAL', 'RECOLLECT')
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='桩/枪运行数据；pile_id、gun_id 为 B 模块逻辑引用';

CREATE TABLE alarm (
    alarm_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    pile_id BIGINT UNSIGNED NOT NULL,
    gun_id BIGINT UNSIGNED NULL,
    alarm_code VARCHAR(50) NOT NULL,
    alarm_level VARCHAR(20) NOT NULL DEFAULT 'MEDIUM',
    alarm_desc VARCHAR(500) NULL,
    occur_time DATETIME(6) NOT NULL,
    recover_time DATETIME(6) NULL,
    alarm_status VARCHAR(20) NOT NULL DEFAULT 'OPEN',
    recover_verify_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    source_telemetry_id BIGINT UNSIGNED NULL,
    closed_time DATETIME(6) NULL,
    PRIMARY KEY (alarm_id),
    KEY ix_alarm_pile_status_time (pile_id, alarm_status, occur_time),
    KEY ix_alarm_gun_status_time (gun_id, alarm_status, occur_time),
    KEY ix_alarm_code_time (alarm_code, occur_time),
    KEY ix_alarm_source_telemetry (source_telemetry_id),
    CONSTRAINT fk_alarm_source_telemetry
        FOREIGN KEY (source_telemetry_id) REFERENCES device_telemetry (telemetry_id),
    CONSTRAINT ck_alarm_level CHECK (alarm_level IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    CONSTRAINT ck_alarm_status CHECK (
        alarm_status IN ('OPEN', 'ACKNOWLEDGED', 'RESOLVED', 'CLOSED')
    ),
    CONSTRAINT ck_alarm_verify CHECK (
        recover_verify_status IN ('PENDING', 'PASSED', 'FAILED', 'NOT_REQUIRED')
    ),
    CONSTRAINT ck_alarm_recovery_time CHECK (
        recover_time IS NULL OR recover_time >= occur_time
    ),
    CONSTRAINT ck_alarm_closed_pair CHECK (
        (alarm_status = 'CLOSED' AND closed_time IS NOT NULL)
        OR (alarm_status <> 'CLOSED' AND closed_time IS NULL)
    ),
    CONSTRAINT ck_alarm_resolved_pair CHECK (
        (alarm_status IN ('RESOLVED', 'CLOSED') AND recover_time IS NOT NULL
            AND recover_verify_status IN ('PASSED', 'NOT_REQUIRED'))
        OR (alarm_status IN ('OPEN', 'ACKNOWLEDGED') AND recover_time IS NULL)
        OR (alarm_status IN ('OPEN', 'ACKNOWLEDGED') AND recover_time IS NOT NULL
            AND recover_verify_status = 'FAILED')
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='设备告警；同一告警可关联多张维修工单';

CREATE TABLE maintenance_work_order (
    work_order_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    work_order_no VARCHAR(50) NOT NULL,
    alarm_id BIGINT UNSIGNED NOT NULL,
    work_order_type VARCHAR(20) NOT NULL DEFAULT 'REPAIR',
    maintainer_id BIGINT UNSIGNED NULL,
    dispatch_time DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    accept_time DATETIME(6) NULL,
    arrive_time DATETIME(6) NULL,
    repair_finish_time DATETIME(6) NULL,
    verify_time DATETIME(6) NULL,
    work_order_status VARCHAR(20) NOT NULL DEFAULT 'ASSIGNED',
    repair_result VARCHAR(500) NULL,
    verify_result VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    verify_remark VARCHAR(500) NULL,
    PRIMARY KEY (work_order_id),
    UNIQUE KEY uq_work_order_no (work_order_no),
    KEY ix_work_order_alarm_status (alarm_id, work_order_status, dispatch_time),
    KEY ix_work_order_maintainer_status (maintainer_id, work_order_status, dispatch_time),
    CONSTRAINT fk_work_order_alarm
        FOREIGN KEY (alarm_id) REFERENCES alarm (alarm_id),
    CONSTRAINT ck_work_order_type CHECK (
        work_order_type IN ('REPAIR', 'INSPECTION', 'PREVENTIVE')
    ),
    CONSTRAINT ck_work_order_status CHECK (
        work_order_status IN (
            'ASSIGNED', 'ACCEPTED', 'ARRIVED', 'REPAIR_REQUIRED',
            'REPAIRED', 'CLOSED', 'CANCELLED'
        )
    ),
    CONSTRAINT ck_work_order_verify CHECK (
        verify_result IN ('PENDING', 'PASS', 'FAIL')
    ),
    CONSTRAINT ck_work_order_milestones CHECK (
        (accept_time IS NULL OR accept_time >= dispatch_time)
        AND (arrive_time IS NULL OR (accept_time IS NOT NULL AND arrive_time >= accept_time))
        AND (repair_finish_time IS NULL OR (arrive_time IS NOT NULL AND repair_finish_time >= arrive_time))
        AND (verify_time IS NULL OR (repair_finish_time IS NOT NULL AND verify_time >= repair_finish_time))
    ),
    CONSTRAINT ck_work_order_state_fields CHECK (
        (work_order_status IN ('ASSIGNED', 'CANCELLED')
            AND accept_time IS NULL AND arrive_time IS NULL
            AND repair_finish_time IS NULL AND verify_time IS NULL)
        OR (work_order_status = 'ACCEPTED'
            AND accept_time IS NOT NULL AND arrive_time IS NULL
            AND repair_finish_time IS NULL AND verify_time IS NULL)
        OR (work_order_status IN ('ARRIVED', 'REPAIR_REQUIRED')
            AND accept_time IS NOT NULL AND arrive_time IS NOT NULL
            AND repair_finish_time IS NULL AND verify_time IS NULL)
        OR (work_order_status = 'REPAIRED'
            AND accept_time IS NOT NULL AND arrive_time IS NOT NULL
            AND repair_finish_time IS NOT NULL AND verify_time IS NULL
            AND verify_result = 'PENDING')
        OR (work_order_status = 'CLOSED'
            AND accept_time IS NOT NULL AND arrive_time IS NOT NULL
            AND repair_finish_time IS NOT NULL AND verify_time IS NOT NULL
            AND verify_result = 'PASS')
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='维修工单；一条告警可派发多次并保留工单记录';

CREATE TABLE spare_part (
    spare_part_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    part_code VARCHAR(50) NOT NULL,
    part_name VARCHAR(100) NOT NULL,
    model VARCHAR(100) NULL,
    spec VARCHAR(100) NULL,
    unit VARCHAR(20) NOT NULL,
    part_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    PRIMARY KEY (spare_part_id),
    UNIQUE KEY uq_spare_part_code (part_code),
    KEY ix_spare_part_name_status (part_name, part_status),
    CONSTRAINT ck_spare_part_status CHECK (part_status IN ('ACTIVE', 'INACTIVE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='备件档案';

CREATE TABLE warehouse (
    warehouse_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    warehouse_code VARCHAR(50) NOT NULL,
    warehouse_name VARCHAR(100) NOT NULL,
    location VARCHAR(200) NULL,
    warehouse_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    PRIMARY KEY (warehouse_id),
    UNIQUE KEY uq_warehouse_code (warehouse_code),
    CONSTRAINT ck_warehouse_status CHECK (warehouse_status IN ('ACTIVE', 'INACTIVE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='备件仓库';

CREATE TABLE inventory (
    inventory_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    warehouse_id BIGINT UNSIGNED NOT NULL,
    spare_part_id BIGINT UNSIGNED NOT NULL,
    quantity INT UNSIGNED NOT NULL DEFAULT 0,
    locked_quantity INT UNSIGNED NOT NULL DEFAULT 0,
    version_no INT UNSIGNED NOT NULL DEFAULT 0,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (inventory_id),
    UNIQUE KEY uq_inventory_warehouse_part (warehouse_id, spare_part_id),
    KEY ix_inventory_part_warehouse (spare_part_id, warehouse_id),
    CONSTRAINT fk_inventory_warehouse
        FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id),
    CONSTRAINT fk_inventory_spare_part
        FOREIGN KEY (spare_part_id) REFERENCES spare_part (spare_part_id),
    CONSTRAINT ck_inventory_available CHECK (locked_quantity <= quantity)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='分仓当前库存；quantity 与库存流水必须在同一事务中变化';

CREATE TABLE inventory_transaction (
    transaction_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    transaction_no VARCHAR(50) NOT NULL,
    warehouse_id BIGINT UNSIGNED NOT NULL,
    spare_part_id BIGINT UNSIGNED NOT NULL,
    work_order_id BIGINT UNSIGNED NULL,
    transaction_type VARCHAR(30) NOT NULL,
    quantity_change BIGINT NOT NULL,
    before_quantity INT UNSIGNED NOT NULL,
    after_quantity INT UNSIGNED NOT NULL,
    occurred_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    operator_id BIGINT UNSIGNED NULL,
    related_transaction_id BIGINT UNSIGNED NULL,
    PRIMARY KEY (transaction_id),
    UNIQUE KEY uq_inventory_transaction_no (transaction_no),
    UNIQUE KEY uq_inventory_reversal (related_transaction_id, transaction_type),
    KEY ix_inventory_txn_warehouse_part_time (warehouse_id, spare_part_id, occurred_at),
    KEY ix_inventory_txn_work_order (work_order_id, occurred_at),
    CONSTRAINT fk_inventory_txn_warehouse
        FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id),
    CONSTRAINT fk_inventory_txn_part
        FOREIGN KEY (spare_part_id) REFERENCES spare_part (spare_part_id),
    CONSTRAINT fk_inventory_txn_work_order
        FOREIGN KEY (work_order_id) REFERENCES maintenance_work_order (work_order_id),
    CONSTRAINT fk_inventory_txn_related
        FOREIGN KEY (related_transaction_id) REFERENCES inventory_transaction (transaction_id),
    CONSTRAINT ck_inventory_txn_type CHECK (
        transaction_type IN ('RECEIPT', 'ISSUE', 'RETURN', 'ADJUSTMENT', 'REVERSAL')
    ),
    CONSTRAINT ck_inventory_txn_delta CHECK (
        quantity_change <> 0
        AND after_quantity = before_quantity + quantity_change
        AND (
            (transaction_type IN ('RECEIPT', 'RETURN') AND quantity_change > 0)
            OR (transaction_type = 'ISSUE' AND quantity_change < 0)
            OR transaction_type IN ('ADJUSTMENT', 'REVERSAL')
        )
    ),
    CONSTRAINT ck_inventory_txn_reversal CHECK (
        (transaction_type = 'REVERSAL' AND related_transaction_id IS NOT NULL)
        OR (transaction_type <> 'REVERSAL' AND related_transaction_id IS NULL)
    ),
    CONSTRAINT ck_inventory_txn_work_order CHECK (
        (transaction_type IN ('ISSUE', 'RETURN') AND work_order_id IS NOT NULL)
        OR (transaction_type IN ('RECEIPT', 'ADJUSTMENT') AND work_order_id IS NULL)
        OR transaction_type = 'REVERSAL'
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='不可删除或修改的库存流水；更正使用冲正流水';

CREATE TABLE work_order_part (
    work_order_part_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    work_order_id BIGINT UNSIGNED NOT NULL,
    spare_part_id BIGINT UNSIGNED NOT NULL,
    warehouse_id BIGINT UNSIGNED NOT NULL,
    planned_qty INT UNSIGNED NOT NULL DEFAULT 0,
    issued_qty INT UNSIGNED NOT NULL DEFAULT 0,
    installed_qty INT UNSIGNED NOT NULL DEFAULT 0,
    returned_qty INT UNSIGNED NOT NULL DEFAULT 0,
    part_usage_status VARCHAR(20) NOT NULL DEFAULT 'PLANNED',
    remark VARCHAR(255) NULL,
    PRIMARY KEY (work_order_part_id),
    UNIQUE KEY uq_work_order_part_source (work_order_id, spare_part_id, warehouse_id),
    KEY ix_work_order_part_warehouse_part (warehouse_id, spare_part_id),
    CONSTRAINT fk_work_order_part_order
        FOREIGN KEY (work_order_id) REFERENCES maintenance_work_order (work_order_id),
    CONSTRAINT fk_work_order_part_spare
        FOREIGN KEY (spare_part_id) REFERENCES spare_part (spare_part_id),
    CONSTRAINT fk_work_order_part_warehouse
        FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id),
    CONSTRAINT ck_work_order_part_quantities CHECK (
        installed_qty + returned_qty <= issued_qty
        AND (planned_qty = 0 OR issued_qty <= planned_qty)
    ),
    CONSTRAINT ck_work_order_part_status CHECK (
        (part_usage_status = 'PLANNED'
            AND issued_qty = 0 AND installed_qty = 0 AND returned_qty = 0)
        OR (part_usage_status = 'ISSUED'
            AND issued_qty > installed_qty + returned_qty)
        OR (part_usage_status = 'COMPLETED'
            AND issued_qty > 0
            AND issued_qty = installed_qty + returned_qty)
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='工单备件计划、领用、安装和退回数量；退料不允许无记录损耗';
