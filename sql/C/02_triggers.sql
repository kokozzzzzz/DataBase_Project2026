USE charging_platform;
SET SESSION time_zone = '+08:00';
DELIMITER $$

CREATE TRIGGER c_telemetry_device_bi
BEFORE INSERT ON device_telemetry
FOR EACH ROW
BEGIN
    DECLARE v_pile_id BIGINT UNSIGNED;
    IF NEW.gun_id IS NOT NULL THEN
        SELECT pile_id INTO v_pile_id
        FROM charging_gun
        WHERE gun_id = NEW.gun_id;
        IF v_pile_id IS NULL OR v_pile_id <> NEW.pile_id THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_GUN_NOT_IN_PILE';
        END IF;
    ELSEIF NOT EXISTS (
        SELECT 1 FROM charging_pile WHERE pile_id = NEW.pile_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PILE_NOT_FOUND';
    END IF;
END$$

CREATE TRIGGER c_alarm_device_bi
BEFORE INSERT ON alarm
FOR EACH ROW
BEGIN
    DECLARE v_pile_id BIGINT UNSIGNED;
    IF NEW.gun_id IS NOT NULL THEN
        SELECT pile_id INTO v_pile_id
        FROM charging_gun
        WHERE gun_id = NEW.gun_id;
        IF v_pile_id IS NULL OR v_pile_id <> NEW.pile_id THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_GUN_NOT_IN_PILE';
        END IF;
    ELSEIF NOT EXISTS (
        SELECT 1 FROM charging_pile WHERE pile_id = NEW.pile_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PILE_NOT_FOUND';
    END IF;
    IF NEW.source_telemetry_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM device_telemetry
        WHERE telemetry_id = NEW.source_telemetry_id
          AND pile_id = NEW.pile_id
          AND (NEW.gun_id IS NULL OR gun_id = NEW.gun_id)
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_TELEMETRY_DEVICE_MISMATCH';
    END IF;
END$$

CREATE TRIGGER c_alarm_state_bu
BEFORE UPDATE ON alarm
FOR EACH ROW
BEGIN
    IF OLD.alarm_status <> NEW.alarm_status
       AND NOT (
           (OLD.alarm_status = 'OPEN' AND NEW.alarm_status = 'ACKNOWLEDGED')
           OR (OLD.alarm_status = 'ACKNOWLEDGED' AND NEW.alarm_status = 'OPEN')
           OR (OLD.alarm_status = 'ACKNOWLEDGED' AND NEW.alarm_status = 'RESOLVED')
           OR (OLD.alarm_status = 'RESOLVED' AND NEW.alarm_status = 'CLOSED')
       ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_ALARM_TRANSITION';
    END IF;
    IF OLD.pile_id <> NEW.pile_id OR NOT (OLD.gun_id <=> NEW.gun_id)
       OR OLD.alarm_code <> NEW.alarm_code OR OLD.occur_time <> NEW.occur_time THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_ALARM_IDENTITY_IMMUTABLE';
    END IF;
END$$

CREATE TRIGGER c_work_order_state_bu
BEFORE UPDATE ON maintenance_work_order
FOR EACH ROW
BEGIN
    IF OLD.work_order_status <> NEW.work_order_status
       AND NOT (
           (OLD.work_order_status = 'ASSIGNED'
               AND NEW.work_order_status IN ('ACCEPTED', 'CANCELLED'))
           OR (OLD.work_order_status = 'ACCEPTED'
               AND NEW.work_order_status = 'ARRIVED')
           OR (OLD.work_order_status = 'ARRIVED'
               AND NEW.work_order_status = 'REPAIRED')
           OR (OLD.work_order_status = 'REPAIR_REQUIRED'
               AND NEW.work_order_status = 'ARRIVED')
           OR (OLD.work_order_status = 'REPAIRED'
               AND NEW.work_order_status IN ('CLOSED', 'REPAIR_REQUIRED'))
       ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_WORK_ORDER_TRANSITION';
    END IF;
    IF OLD.alarm_id <> NEW.alarm_id OR OLD.work_order_no <> NEW.work_order_no
       OR OLD.dispatch_time <> NEW.dispatch_time THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_IDENTITY_IMMUTABLE';
    END IF;
END$$

CREATE TRIGGER c_inventory_transaction_bi
BEFORE INSERT ON inventory_transaction
FOR EACH ROW
BEGIN
    DECLARE v_quantity INT UNSIGNED;
    DECLARE v_locked INT UNSIGNED;
    SELECT quantity, locked_quantity INTO v_quantity, v_locked
    FROM inventory
    WHERE warehouse_id = NEW.warehouse_id
      AND spare_part_id = NEW.spare_part_id;
    IF v_quantity IS NULL OR v_quantity <> NEW.after_quantity
       OR NEW.after_quantity < v_locked THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_LEDGER_MISMATCH';
    END IF;
    IF NEW.transaction_type = 'REVERSAL' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM inventory_transaction
            WHERE transaction_id = NEW.related_transaction_id
              AND warehouse_id = NEW.warehouse_id
              AND spare_part_id = NEW.spare_part_id
              AND quantity_change = -NEW.quantity_change
        ) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVALID_REVERSAL';
        END IF;
    END IF;
END$$

CREATE TRIGGER c_inventory_transaction_bu
BEFORE UPDATE ON inventory_transaction
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_LEDGER_IMMUTABLE';
END$$

CREATE TRIGGER c_inventory_transaction_bd
BEFORE DELETE ON inventory_transaction
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_INVENTORY_LEDGER_IMMUTABLE';
END$$

CREATE TRIGGER c_work_order_part_bu
BEFORE UPDATE ON work_order_part
FOR EACH ROW
BEGIN
    IF NEW.work_order_id <> OLD.work_order_id
       OR NEW.spare_part_id <> OLD.spare_part_id
       OR NEW.warehouse_id <> OLD.warehouse_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_WORK_ORDER_PART_IDENTITY_IMMUTABLE';
    END IF;
    IF COALESCE(@c_inventory_reversal, 0) <> 1
       AND (NEW.issued_qty < OLD.issued_qty
            OR NEW.installed_qty < OLD.installed_qty
            OR NEW.returned_qty < OLD.returned_qty) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_PART_USAGE_CANNOT_DECREASE';
    END IF;
END$$

DELIMITER ;
