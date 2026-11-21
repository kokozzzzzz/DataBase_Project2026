-- 所有C过程参与调用方事务，不自行提交。Python使用公共transaction(connection)。
-- MySQL手工调用先START TRANSACTION，成功后COMMIT，异常ROLLBACK。
USE charging_platform;
SET SESSION time_zone = '+08:00';
DELIMITER $$

CREATE PROCEDURE sp_c_ingest_telemetry(
    IN p_pile_id BIGINT UNSIGNED,
    IN p_gun_id BIGINT UNSIGNED,
    IN p_collect_time DATETIME(6),
    IN p_voltage DECIMAL(8,2),
    IN p_current DECIMAL(8,2),
    IN p_power DECIMAL(10,2),
    IN p_module_temp DECIMAL(6,2),
    IN p_offline_duration_sec INT UNSIGNED,
    IN p_fault_code VARCHAR(50),
    IN p_quality_flag VARCHAR(20),
    IN p_offline_threshold_sec INT UNSIGNED,
    OUT p_telemetry_id BIGINT UNSIGNED,
    OUT p_alarm_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_pile_status VARCHAR(20);
    DECLARE v_gun_status VARCHAR(20);
    DECLARE v_existing_alarm_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_has_alarm BOOLEAN DEFAULT FALSE;
    DECLARE v_latest_time DATETIME(6);
    DECLARE v_heartbeat DATETIME(6);

    IF p_pile_id IS NULL OR p_pile_id = 0 OR p_collect_time IS NULL
       OR p_offline_threshold_sec IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_TELEMETRY_INPUT';
    END IF;

    SET p_telemetry_id = NULL;
    SET p_alarm_id = NULL;

    SELECT status INTO v_pile_status
    FROM charging_pile
    WHERE pile_id = p_pile_id
    FOR UPDATE;

    IF p_gun_id IS NOT NULL THEN
        SELECT status INTO v_gun_status
        FROM charging_gun
        WHERE gun_id = p_gun_id AND pile_id = p_pile_id
        FOR UPDATE;
    END IF;

    IF v_pile_status IS NULL OR (p_gun_id IS NOT NULL AND v_gun_status IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='C_DEVICE_NOT_FOUND';
    END IF;
    SELECT MAX(collect_time) INTO v_latest_time FROM device_telemetry
    WHERE pile_id=p_pile_id AND (gun_id <=> p_gun_id) FOR UPDATE;
    INSERT INTO device_telemetry (
        pile_id, gun_id, collect_time, voltage, current, power, module_temp,
        offline_duration_sec, fault_code, quality_flag
    ) VALUES (
        p_pile_id, p_gun_id, p_collect_time, p_voltage, p_current, p_power,
        p_module_temp, p_offline_duration_sec, NULLIF(p_fault_code, ''),
        p_quality_flag
    );
    SET p_telemetry_id = LAST_INSERT_ID();
    -- 旧报文只留遥测事实，避免覆盖新状态或重新触发已修复告警。
    IF v_latest_time IS NULL OR p_collect_time >= v_latest_time THEN
    SET v_heartbeat=TIMESTAMPADD(SECOND,-p_offline_duration_sec,p_collect_time);
    UPDATE charging_pile SET last_heartbeat_at=v_heartbeat
    WHERE pile_id=p_pile_id AND (last_heartbeat_at IS NULL OR last_heartbeat_at<v_heartbeat);


    IF p_fault_code IS NOT NULL AND p_fault_code <> '' THEN
        SET v_existing_alarm_id = NULL;
        IF p_gun_id IS NULL THEN
            SELECT alarm_id INTO v_existing_alarm_id
            FROM alarm
            WHERE pile_id = p_pile_id
              AND gun_id IS NULL
              AND alarm_code = p_fault_code
              AND alarm_status IN ('OPEN', 'ACKNOWLEDGED')
            ORDER BY alarm_id DESC
            LIMIT 1
            FOR UPDATE;
        ELSE
            SELECT alarm_id INTO v_existing_alarm_id
            FROM alarm
            WHERE gun_id = p_gun_id
              AND alarm_code = p_fault_code
              AND alarm_status IN ('OPEN', 'ACKNOWLEDGED')
            ORDER BY alarm_id DESC
            LIMIT 1
            FOR UPDATE;
        END IF;

        IF v_existing_alarm_id IS NULL THEN
            INSERT INTO alarm (
                pile_id, gun_id, alarm_code, alarm_level, alarm_desc,
                occur_time, source_telemetry_id
            ) VALUES (
                p_pile_id, p_gun_id, p_fault_code,
                CASE
                    WHEN LEFT(p_fault_code, 5) = 'CRIT_' THEN 'CRITICAL'
                    WHEN LEFT(p_fault_code, 5) = 'HIGH_' THEN 'HIGH'
                    ELSE 'MEDIUM'
                END,
                CONCAT('由运行数据 ', p_telemetry_id, ' 触发'),
                p_collect_time, p_telemetry_id
            );
            SET p_alarm_id = LAST_INSERT_ID();
        ELSE
            SET p_alarm_id = v_existing_alarm_id;
        END IF;

        IF p_gun_id IS NULL THEN
            UPDATE charging_pile SET status = 'FAULT' WHERE pile_id = p_pile_id;
        ELSE
            UPDATE charging_gun SET status = 'FAULT'
            WHERE gun_id = p_gun_id AND pile_id = p_pile_id AND status <> 'DISABLED';
        END IF;
    END IF;

    IF p_offline_threshold_sec > 0
       AND p_offline_duration_sec >= p_offline_threshold_sec
       AND (p_fault_code IS NULL OR p_fault_code = '') THEN
        INSERT INTO equipment_offline_task (pile_id)
        SELECT p_pile_id
        WHERE NOT EXISTS (
            SELECT 1
            FROM equipment_offline_task
            WHERE pile_id = p_pile_id AND closed_at IS NULL
        );
        UPDATE charging_pile
        SET status = 'OFFLINE'
        WHERE pile_id = p_pile_id AND status = 'READY';
    END IF;
    IF p_offline_duration_sec=0 AND (p_fault_code IS NULL OR p_fault_code='') THEN
        UPDATE charging_pile SET status='READY'
        WHERE pile_id=p_pile_id AND status='OFFLINE' AND commissioned_on IS NOT NULL
          AND NOT EXISTS(SELECT 1 FROM alarm WHERE pile_id=p_pile_id
              AND alarm_status IN ('OPEN','ACKNOWLEDGED'));
        UPDATE equipment_offline_task SET closed_at=CURRENT_TIMESTAMP(6)
        WHERE pile_id=p_pile_id AND closed_at IS NULL AND created_at<=p_collect_time
          AND EXISTS(SELECT 1 FROM charging_pile WHERE pile_id=p_pile_id AND status='READY');
    END IF;
    END IF;
END$$

CREATE PROCEDURE sp_c_dispatch_work_order(
    IN p_alarm_id BIGINT UNSIGNED,
    IN p_work_order_no VARCHAR(50),
    IN p_work_order_type VARCHAR(20),
    IN p_maintainer_id BIGINT UNSIGNED,
    OUT p_work_order_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_alarm_status VARCHAR(20);

    IF p_alarm_id IS NULL OR p_alarm_id = 0
       OR p_work_order_no IS NULL OR TRIM(p_work_order_no) = ''
       OR p_work_order_type NOT IN ('REPAIR', 'INSPECTION', 'PREVENTIVE') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_WORK_ORDER_INPUT';
    END IF;

    SELECT alarm_status INTO v_alarm_status
    FROM alarm WHERE alarm_id = p_alarm_id FOR UPDATE;

    IF v_alarm_status IS NULL OR v_alarm_status NOT IN ('OPEN', 'ACKNOWLEDGED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_ALARM_NOT_DISPATCHABLE';
    END IF;

    INSERT INTO maintenance_work_order (
        work_order_no, alarm_id, work_order_type, maintainer_id
    ) VALUES (
        p_work_order_no, p_alarm_id, p_work_order_type, p_maintainer_id
    );
    SET p_work_order_id = LAST_INSERT_ID();

    IF v_alarm_status = 'OPEN' THEN
        UPDATE alarm SET alarm_status = 'ACKNOWLEDGED'
        WHERE alarm_id = p_alarm_id;
    END IF;
END$$

CREATE PROCEDURE sp_c_advance_work_order(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_action VARCHAR(20),
    IN p_maintainer_id BIGINT UNSIGNED,
    IN p_result VARCHAR(500)
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_status VARCHAR(20);

    IF p_work_order_id IS NULL OR p_work_order_id = 0
       OR p_action NOT IN ('ACCEPT', 'ARRIVE', 'REPAIR') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_WORK_ORDER_ACTION';
    END IF;

    SELECT work_order_status INTO v_status
    FROM maintenance_work_order
    WHERE work_order_id = p_work_order_id
    FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_NOT_FOUND';
    END IF;

    IF p_action = 'ACCEPT' AND v_status = 'ASSIGNED' THEN
        UPDATE maintenance_work_order
        SET work_order_status = 'ACCEPTED',
            maintainer_id = COALESCE(p_maintainer_id, maintainer_id),
            accept_time = CURRENT_TIMESTAMP(6)
        WHERE work_order_id = p_work_order_id;
    ELSEIF p_action = 'ARRIVE' AND v_status IN ('ACCEPTED', 'REPAIR_REQUIRED') THEN
        UPDATE maintenance_work_order
        SET work_order_status = 'ARRIVED',
            maintainer_id = COALESCE(p_maintainer_id, maintainer_id),
            arrive_time = CURRENT_TIMESTAMP(6),
            verify_result = 'PENDING',
            verify_remark = NULL
        WHERE work_order_id = p_work_order_id;
    ELSEIF p_action = 'REPAIR' AND v_status = 'ARRIVED'
       AND p_result IS NOT NULL AND TRIM(p_result) <> '' THEN
        UPDATE maintenance_work_order
        SET work_order_status = 'REPAIRED',
            repair_finish_time = CURRENT_TIMESTAMP(6),
            repair_result = p_result
        WHERE work_order_id = p_work_order_id;
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_WORK_ORDER_TRANSITION';
    END IF;
END$$

CREATE PROCEDURE sp_c_verify_work_order(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_pass BOOLEAN,
    IN p_verify_remark VARCHAR(500)
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_alarm_id BIGINT UNSIGNED;
    DECLARE v_pile_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_open_parts BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_other_alarms BIGINT UNSIGNED DEFAULT 0;

    SELECT wo.alarm_id, wo.work_order_status, a.pile_id, a.gun_id
      INTO v_alarm_id, v_status, v_pile_id, v_gun_id
    FROM maintenance_work_order AS wo
    JOIN alarm AS a ON a.alarm_id = wo.alarm_id
    WHERE wo.work_order_id = p_work_order_id
    FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'REPAIRED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_NOT_READY_FOR_VERIFY';
    END IF;

    IF p_pass THEN
        SELECT COUNT(*) INTO v_open_parts
        FROM work_order_part
        WHERE work_order_id = p_work_order_id
          AND issued_qty <> installed_qty + returned_qty;
        IF v_open_parts > 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PARTS_NOT_RECONCILED';
        END IF;

        UPDATE maintenance_work_order
        SET work_order_status = 'CLOSED',
            verify_result = 'PASS',
            verify_time = CURRENT_TIMESTAMP(6),
            verify_remark = p_verify_remark
        WHERE work_order_id = p_work_order_id;

        SELECT COUNT(*) INTO v_other_alarms
        FROM maintenance_work_order
        WHERE alarm_id = v_alarm_id
          AND work_order_id <> p_work_order_id
          AND work_order_status NOT IN ('CLOSED', 'CANCELLED');

        IF v_other_alarms = 0 THEN
            UPDATE alarm
            SET alarm_status = 'RESOLVED',
                recover_verify_status = 'PASSED',
                recover_time = CURRENT_TIMESTAMP(6)
            WHERE alarm_id = v_alarm_id
              AND alarm_status = 'ACKNOWLEDGED';

            IF ROW_COUNT() = 1 THEN
                IF v_gun_id IS NOT NULL THEN
                    UPDATE charging_gun
                    SET status = 'READY'
                    WHERE gun_id = v_gun_id AND status = 'FAULT'
                      AND NOT EXISTS (
                          SELECT 1 FROM alarm
                          WHERE gun_id = v_gun_id
                            AND alarm_id <> v_alarm_id
                            AND alarm_status IN ('OPEN', 'ACKNOWLEDGED')
                      );
                ELSE
                    UPDATE charging_pile
                    SET status = 'READY'
                    WHERE pile_id = v_pile_id AND status = 'FAULT' AND commissioned_on IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM alarm
                          WHERE pile_id = v_pile_id
                            AND alarm_id <> v_alarm_id
                            AND alarm_status IN ('OPEN', 'ACKNOWLEDGED')
                      );
                END IF;
                UPDATE equipment_offline_task
                SET closed_at = CURRENT_TIMESTAMP(6)
                WHERE pile_id = v_pile_id AND closed_at IS NULL
                  AND EXISTS(SELECT 1 FROM charging_pile WHERE pile_id=v_pile_id AND status='READY')
                  AND NOT EXISTS (
                      SELECT 1 FROM alarm
                      WHERE pile_id = v_pile_id
                        AND alarm_id <> v_alarm_id
                        AND alarm_status IN ('OPEN', 'ACKNOWLEDGED')
                  );
            END IF;
        END IF;
    ELSE
        UPDATE maintenance_work_order
        SET work_order_status = 'REPAIR_REQUIRED',
            verify_result = 'FAIL',
            repair_finish_time = NULL,
            verify_remark = COALESCE(p_verify_remark, '复核未通过，请继续维修')
        WHERE work_order_id = p_work_order_id;
        UPDATE alarm
        SET recover_verify_status = 'FAILED',
            recover_time = CURRENT_TIMESTAMP(6)
        WHERE alarm_id = v_alarm_id
          AND alarm_status = 'ACKNOWLEDGED';
    END IF;
END$$

CREATE PROCEDURE sp_c_cancel_work_order(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_reason VARCHAR(255)
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_status VARCHAR(20);

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_CANCEL_REASON_REQUIRED';
    END IF;
    SELECT work_order_status INTO v_status
    FROM maintenance_work_order
    WHERE work_order_id = p_work_order_id
    FOR UPDATE;
    IF v_status IS NULL OR v_status <> 'ASSIGNED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_ONLY_UNACCEPTED_ORDER_CAN_CANCEL';
    END IF;
    UPDATE maintenance_work_order
    SET work_order_status = 'CANCELLED', verify_remark = p_reason
    WHERE work_order_id = p_work_order_id;
END$$

CREATE PROCEDURE sp_c_plan_work_order_part(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_spare_part_id BIGINT UNSIGNED,
    IN p_warehouse_id BIGINT UNSIGNED,
    IN p_planned_qty INT UNSIGNED,
    IN p_remark VARCHAR(255),
    OUT p_work_order_part_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_status VARCHAR(20);
    IF p_planned_qty IS NULL OR p_planned_qty = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PLANNED_QUANTITY_REQUIRED';
    END IF;
    SELECT work_order_status INTO v_status
    FROM maintenance_work_order
    WHERE work_order_id = p_work_order_id FOR UPDATE;
    IF v_status IS NULL OR v_status NOT IN ('ASSIGNED', 'ACCEPTED', 'ARRIVED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PART_PLAN_ORDER_CLOSED';
    END IF;
    INSERT INTO work_order_part (
        work_order_id, spare_part_id, warehouse_id, planned_qty, remark
    ) VALUES (
        p_work_order_id, p_spare_part_id, p_warehouse_id, p_planned_qty, p_remark
    );
    SET p_work_order_part_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_c_receive_stock(
    IN p_warehouse_id BIGINT UNSIGNED,
    IN p_spare_part_id BIGINT UNSIGNED,
    IN p_quantity INT UNSIGNED,
    IN p_operator_id BIGINT UNSIGNED,
    IN p_transaction_no VARCHAR(50),
    OUT p_transaction_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_inventory_id BIGINT UNSIGNED;
    DECLARE v_before INT UNSIGNED;
    DECLARE v_after INT UNSIGNED;
    DECLARE v_version INT UNSIGNED;
    IF p_quantity IS NULL OR p_quantity = 0
       OR p_transaction_no IS NULL OR TRIM(p_transaction_no) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_RECEIPT';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM warehouse WHERE warehouse_id = p_warehouse_id
          AND warehouse_status = 'ACTIVE'
    ) OR NOT EXISTS (
        SELECT 1 FROM spare_part WHERE spare_part_id = p_spare_part_id
          AND part_status = 'ACTIVE'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INACTIVE_STOCK_REFERENCE';
    END IF;
    INSERT INTO inventory (warehouse_id, spare_part_id)
    VALUES (p_warehouse_id, p_spare_part_id)
    ON DUPLICATE KEY UPDATE inventory_id = LAST_INSERT_ID(inventory_id);
    SELECT inventory_id, quantity, version_no
      INTO v_inventory_id, v_before, v_version
    FROM inventory
    WHERE warehouse_id = p_warehouse_id AND spare_part_id = p_spare_part_id
    FOR UPDATE;
    SET v_after = v_before + p_quantity;
    UPDATE inventory
    SET quantity = v_after, version_no = version_no + 1
    WHERE inventory_id = v_inventory_id AND version_no = v_version;
    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_VERSION_CONFLICT';
    END IF;
    INSERT INTO inventory_transaction (
        transaction_no, warehouse_id, spare_part_id, transaction_type,
        quantity_change, before_quantity, after_quantity, operator_id
    ) VALUES (
        p_transaction_no, p_warehouse_id, p_spare_part_id, 'RECEIPT',
        p_quantity, v_before, v_after, p_operator_id
    );
    SET p_transaction_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_c_issue_work_order_part(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_spare_part_id BIGINT UNSIGNED,
    IN p_warehouse_id BIGINT UNSIGNED,
    IN p_quantity INT UNSIGNED,
    IN p_operator_id BIGINT UNSIGNED,
    IN p_transaction_no VARCHAR(50),
    OUT p_transaction_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_work_order_status VARCHAR(20);
    DECLARE v_inventory_id BIGINT UNSIGNED;
    DECLARE v_before INT UNSIGNED;
    DECLARE v_locked INT UNSIGNED;
    DECLARE v_after INT UNSIGNED;
    DECLARE v_version INT UNSIGNED;
    DECLARE v_issued INT UNSIGNED;
    DECLARE v_planned INT UNSIGNED;
    DECLARE v_work_order_part_id BIGINT UNSIGNED;
    IF p_quantity IS NULL OR p_quantity = 0
       OR p_transaction_no IS NULL OR TRIM(p_transaction_no) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_ISSUE';
    END IF;
    SELECT work_order_status INTO v_work_order_status
    FROM maintenance_work_order
    WHERE work_order_id = p_work_order_id FOR UPDATE;
    IF v_work_order_status IS NULL OR v_work_order_status NOT IN ('ARRIVED', 'REPAIR_REQUIRED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_NOT_READY_FOR_ISSUE';
    END IF;
    SELECT work_order_part_id, issued_qty, planned_qty
      INTO v_work_order_part_id, v_issued, v_planned
    FROM work_order_part
    WHERE work_order_id = p_work_order_id
      AND spare_part_id = p_spare_part_id
      AND warehouse_id = p_warehouse_id
    FOR UPDATE;
    IF v_work_order_part_id IS NULL OR v_planned = 0
       OR v_issued + p_quantity > v_planned THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PART_NOT_PLANNED_OR_OVER_PLAN';
    END IF;
    SELECT inventory_id, quantity, locked_quantity, version_no
      INTO v_inventory_id, v_before, v_locked, v_version
    FROM inventory
    WHERE warehouse_id = p_warehouse_id
      AND spare_part_id = p_spare_part_id
    FOR UPDATE;
    IF v_inventory_id IS NULL OR v_before - v_locked < p_quantity THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INSUFFICIENT_AVAILABLE_STOCK';
    END IF;
    SET v_after = v_before - p_quantity;
    UPDATE inventory
    SET quantity = v_after, version_no = version_no + 1
    WHERE inventory_id = v_inventory_id AND version_no = v_version;
    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_VERSION_CONFLICT';
    END IF;
    UPDATE work_order_part
    SET issued_qty = issued_qty + p_quantity,
        part_usage_status = 'ISSUED'
    WHERE work_order_id = p_work_order_id
      AND spare_part_id = p_spare_part_id
      AND warehouse_id = p_warehouse_id;
    INSERT INTO inventory_transaction (
        transaction_no, warehouse_id, spare_part_id, work_order_id,
        transaction_type, quantity_change, before_quantity, after_quantity,
        operator_id
    ) VALUES (
        p_transaction_no, p_warehouse_id, p_spare_part_id, p_work_order_id,
        'ISSUE', -CAST(p_quantity AS SIGNED), v_before, v_after, p_operator_id
    );
    SET p_transaction_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_c_return_work_order_part(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_spare_part_id BIGINT UNSIGNED,
    IN p_warehouse_id BIGINT UNSIGNED,
    IN p_quantity INT UNSIGNED,
    IN p_operator_id BIGINT UNSIGNED,
    IN p_transaction_no VARCHAR(50),
    OUT p_transaction_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_work_order_status VARCHAR(20);
    DECLARE v_inventory_id BIGINT UNSIGNED;
    DECLARE v_before INT UNSIGNED;
    DECLARE v_after INT UNSIGNED;
    DECLARE v_version INT UNSIGNED;
    DECLARE v_issued INT UNSIGNED;
    DECLARE v_installed INT UNSIGNED;
    DECLARE v_returned INT UNSIGNED;
    IF p_quantity IS NULL OR p_quantity = 0
       OR p_transaction_no IS NULL OR TRIM(p_transaction_no) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_RETURN';
    END IF;
    SELECT work_order_status INTO v_work_order_status
    FROM maintenance_work_order
    WHERE work_order_id = p_work_order_id FOR UPDATE;
    IF v_work_order_status IS NULL
       OR v_work_order_status NOT IN ('ARRIVED', 'REPAIR_REQUIRED', 'REPAIRED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_NOT_READY_FOR_RETURN';
    END IF;
    SELECT issued_qty, installed_qty, returned_qty
      INTO v_issued, v_installed, v_returned
    FROM work_order_part
    WHERE work_order_id = p_work_order_id
      AND spare_part_id = p_spare_part_id
      AND warehouse_id = p_warehouse_id
    FOR UPDATE;
    IF v_issued IS NULL OR v_installed + v_returned + p_quantity > v_issued THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_RETURN_EXCEEDS_UNINSTALLED_ISSUE';
    END IF;
    SELECT inventory_id, quantity, version_no
      INTO v_inventory_id, v_before, v_version
    FROM inventory
    WHERE warehouse_id = p_warehouse_id
      AND spare_part_id = p_spare_part_id
    FOR UPDATE;
    IF v_inventory_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_NOT_FOUND';
    END IF;
    SET v_after = v_before + p_quantity;
    UPDATE inventory
    SET quantity = v_after, version_no = version_no + 1
    WHERE inventory_id = v_inventory_id AND version_no = v_version;
    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_VERSION_CONFLICT';
    END IF;
    UPDATE work_order_part
    SET part_usage_status = CASE
            WHEN installed_qty + returned_qty + p_quantity = issued_qty THEN 'COMPLETED'
            ELSE 'ISSUED'
        END,
        returned_qty = returned_qty + p_quantity
    WHERE work_order_id = p_work_order_id
      AND spare_part_id = p_spare_part_id
      AND warehouse_id = p_warehouse_id;
    INSERT INTO inventory_transaction (
        transaction_no, warehouse_id, spare_part_id, work_order_id,
        transaction_type, quantity_change, before_quantity, after_quantity,
        operator_id
    ) VALUES (
        p_transaction_no, p_warehouse_id, p_spare_part_id, p_work_order_id,
        'RETURN', p_quantity, v_before, v_after, p_operator_id
    );
    SET p_transaction_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_c_record_part_installation(
    IN p_work_order_id BIGINT UNSIGNED,
    IN p_spare_part_id BIGINT UNSIGNED,
    IN p_warehouse_id BIGINT UNSIGNED,
    IN p_quantity INT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_order_status VARCHAR(20);
    DECLARE v_issued INT UNSIGNED;
    DECLARE v_returned INT UNSIGNED;
    DECLARE v_installed INT UNSIGNED;
    IF p_quantity IS NULL OR p_quantity = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_INSTALL_QUANTITY';
    END IF;
    SELECT work_order_status INTO v_order_status
    FROM maintenance_work_order
    WHERE work_order_id = p_work_order_id FOR UPDATE;
    IF v_order_status IS NULL OR v_order_status NOT IN ('ARRIVED', 'REPAIR_REQUIRED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_NOT_READY_FOR_INSTALL';
    END IF;
    SELECT issued_qty, returned_qty, installed_qty
      INTO v_issued, v_returned, v_installed
    FROM work_order_part
    WHERE work_order_id = p_work_order_id
      AND spare_part_id = p_spare_part_id
      AND warehouse_id = p_warehouse_id
    FOR UPDATE;
    IF v_issued IS NULL OR v_installed + v_returned + p_quantity > v_issued THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INSTALL_EXCEEDS_UNINSTALLED_ISSUE';
    END IF;
    UPDATE work_order_part
    SET part_usage_status = CASE
            WHEN installed_qty + returned_qty + p_quantity = issued_qty THEN 'COMPLETED'
            ELSE 'ISSUED'
        END,
        installed_qty = installed_qty + p_quantity
    WHERE work_order_id = p_work_order_id
      AND spare_part_id = p_spare_part_id
      AND warehouse_id = p_warehouse_id;
END$$

CREATE PROCEDURE sp_c_adjust_stock(
    IN p_warehouse_id BIGINT UNSIGNED,
    IN p_spare_part_id BIGINT UNSIGNED,
    IN p_delta INT,
    IN p_operator_id BIGINT UNSIGNED,
    IN p_transaction_no VARCHAR(50),
    IN p_reason VARCHAR(255),
    OUT p_transaction_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_inventory_id BIGINT UNSIGNED;
    DECLARE v_before INT UNSIGNED;
    DECLARE v_locked INT UNSIGNED;
    DECLARE v_after INT UNSIGNED;
    DECLARE v_version INT UNSIGNED;
    IF p_delta IS NULL OR p_delta = 0 OR p_reason IS NULL OR TRIM(p_reason) = ''
       OR p_transaction_no IS NULL OR TRIM(p_transaction_no) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_STOCK_ADJUSTMENT';
    END IF;
    SELECT inventory_id, quantity, locked_quantity, version_no
      INTO v_inventory_id, v_before, v_locked, v_version
    FROM inventory
    WHERE warehouse_id = p_warehouse_id AND spare_part_id = p_spare_part_id
    FOR UPDATE;
    IF v_inventory_id IS NULL OR v_before + p_delta < v_locked THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_STOCK_ADJUSTMENT_BELOW_LOCKED';
    END IF;
    SET v_after = v_before + p_delta;
    UPDATE inventory
    SET quantity = v_after, version_no = version_no + 1
    WHERE inventory_id = v_inventory_id AND version_no = v_version;
    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_VERSION_CONFLICT';
    END IF;
    INSERT INTO inventory_transaction (
        transaction_no, warehouse_id, spare_part_id, transaction_type,
        quantity_change, before_quantity, after_quantity, operator_id
    ) VALUES (
        p_transaction_no, p_warehouse_id, p_spare_part_id, 'ADJUSTMENT',
        p_delta, v_before, v_after, p_operator_id
    );
    SET p_transaction_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_c_reverse_inventory_transaction(
    IN p_original_transaction_id BIGINT UNSIGNED,
    IN p_reversal_no VARCHAR(50),
    IN p_operator_id BIGINT UNSIGNED,
    IN p_reason VARCHAR(255),
    OUT p_reversal_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_warehouse_id BIGINT UNSIGNED;
    DECLARE v_spare_part_id BIGINT UNSIGNED;
    DECLARE v_inventory_id BIGINT UNSIGNED;
    DECLARE v_work_order_id BIGINT UNSIGNED;
    DECLARE v_type VARCHAR(30);
    DECLARE v_delta INT;
    DECLARE v_before INT UNSIGNED;
    DECLARE v_locked INT UNSIGNED;
    DECLARE v_after INT UNSIGNED;
    DECLARE v_version INT UNSIGNED;
    DECLARE v_work_order_status VARCHAR(20);
    DECLARE v_part_issued INT UNSIGNED;
    DECLARE v_part_installed INT UNSIGNED;
    DECLARE v_part_returned INT UNSIGNED;
    DECLARE v_remaining_issued INT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @c_inventory_reversal = NULL;
        RESIGNAL;
    END;
    IF p_reversal_no IS NULL OR TRIM(p_reversal_no) = ''
       OR p_reason IS NULL OR TRIM(p_reason) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_REVERSAL_REASON_REQUIRED';
    END IF;
    SELECT warehouse_id, spare_part_id, work_order_id, transaction_type, quantity_change
      INTO v_warehouse_id, v_spare_part_id, v_work_order_id, v_type, v_delta
    FROM inventory_transaction
    WHERE transaction_id = p_original_transaction_id
    FOR UPDATE;
    IF v_type IS NULL OR v_type = 'REVERSAL' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_TRANSACTION_NOT_REVERSIBLE';
    END IF;
    IF v_work_order_id IS NOT NULL THEN
        SELECT work_order_status INTO v_work_order_status
        FROM maintenance_work_order
        WHERE work_order_id = v_work_order_id
        FOR UPDATE;
        IF v_work_order_status IS NULL
           OR v_work_order_status NOT IN ('ARRIVED', 'REPAIR_REQUIRED', 'REPAIRED') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_NOT_REVERSIBLE';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM inventory_transaction
        WHERE related_transaction_id = p_original_transaction_id
          AND transaction_type = 'REVERSAL'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_TRANSACTION_ALREADY_REVERSED';
    END IF;
    SELECT inventory_id, quantity, locked_quantity, version_no
      INTO v_inventory_id, v_before, v_locked, v_version
    FROM inventory
    WHERE warehouse_id = v_warehouse_id AND spare_part_id = v_spare_part_id
    FOR UPDATE;
    SET v_after = v_before - v_delta;
    IF v_after < v_locked THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_REVERSAL_BELOW_LOCKED_STOCK';
    END IF;

    IF v_type = 'ISSUE' THEN
        SELECT issued_qty, installed_qty, returned_qty
          INTO v_part_issued, v_part_installed, v_part_returned
        FROM work_order_part
        WHERE work_order_id = v_work_order_id
          AND spare_part_id = v_spare_part_id
          AND warehouse_id = v_warehouse_id
        FOR UPDATE;
        IF v_part_issued IS NULL OR v_part_issued + v_delta < v_part_installed + v_part_returned THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_ISSUE_REVERSAL_ALREADY_USED';
        END IF;
        SET v_remaining_issued = v_part_issued + v_delta;
        SET @c_inventory_reversal = 1;
        UPDATE work_order_part
        SET issued_qty = v_remaining_issued,
            part_usage_status = CASE
                WHEN v_remaining_issued = 0 THEN 'PLANNED'
                WHEN v_remaining_issued = v_part_installed + v_part_returned THEN 'COMPLETED'
                ELSE 'ISSUED'
            END
        WHERE work_order_id = v_work_order_id
          AND spare_part_id = v_spare_part_id
          AND warehouse_id = v_warehouse_id;
        SET @c_inventory_reversal = NULL;
    ELSEIF v_type = 'RETURN' THEN
        SELECT issued_qty, installed_qty, returned_qty
          INTO v_part_issued, v_part_installed, v_part_returned
        FROM work_order_part
        WHERE work_order_id = v_work_order_id
          AND spare_part_id = v_spare_part_id
          AND warehouse_id = v_warehouse_id
        FOR UPDATE;
        IF v_part_returned < v_delta THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_RETURN_REVERSAL_ALREADY_USED';
        END IF;
        SET @c_inventory_reversal = 1;
        UPDATE work_order_part
        SET returned_qty = returned_qty - v_delta,
            part_usage_status = 'ISSUED'
        WHERE work_order_id = v_work_order_id
          AND spare_part_id = v_spare_part_id
          AND warehouse_id = v_warehouse_id;
        SET @c_inventory_reversal = NULL;
    END IF;

    UPDATE inventory
    SET quantity = v_after, version_no = version_no + 1
    WHERE inventory_id = v_inventory_id AND version_no = v_version;
    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_VERSION_CONFLICT';
    END IF;
    INSERT INTO inventory_transaction (
        transaction_no, warehouse_id, spare_part_id, work_order_id,
        transaction_type, quantity_change, before_quantity, after_quantity,
        operator_id, related_transaction_id
    ) VALUES (
        p_reversal_no, v_warehouse_id, v_spare_part_id, v_work_order_id,
        'REVERSAL', -v_delta, v_before, v_after, p_operator_id,
        p_original_transaction_id
    );
    SET p_reversal_id = LAST_INSERT_ID();
END$$

DELIMITER ;
