-- C constraint tests use existing committed seed data and leave no business changes.
USE charging_platform;
SET SESSION time_zone = '+08:00';
DROP PROCEDURE IF EXISTS sp_c_run_constraint_tests;
CREATE TEMPORARY TABLE c_constraint_results (
    test_id VARCHAR(8) NOT NULL,
    test_name VARCHAR(80) NOT NULL,
    observed_error INT NULL,
    result VARCHAR(8) NOT NULL,
    PRIMARY KEY (test_id)
) ENGINE=MEMORY;

DELIMITER $$
CREATE PROCEDURE sp_c_run_constraint_tests()
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    DECLARE v_error INT DEFAULT NULL;
    DECLARE v_pile_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_alarm_id BIGINT UNSIGNED;
    DECLARE v_work_order_id BIGINT UNSIGNED;
    DECLARE v_work_order_part_id BIGINT UNSIGNED;
    DECLARE v_inventory_transaction_id BIGINT UNSIGNED;
    DECLARE v_spare_part_id BIGINT UNSIGNED;

    IF (SELECT COUNT(*) FROM device_telemetry) = 0
       OR (SELECT COUNT(*) FROM inventory_transaction) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_TEST_DATA_REQUIRED';
    END IF;
    SELECT pile_id INTO v_pile_id
    FROM device_telemetry ORDER BY telemetry_id LIMIT 1;
    SELECT gun_id INTO v_gun_id
    FROM device_telemetry
    WHERE gun_id IS NOT NULL
    ORDER BY telemetry_id LIMIT 1;
    SELECT alarm_id INTO v_alarm_id
    FROM alarm WHERE alarm_status = 'RESOLVED' ORDER BY alarm_id LIMIT 1;
    SELECT work_order_id INTO v_work_order_id
    FROM maintenance_work_order
    WHERE work_order_status = 'CLOSED'
    ORDER BY work_order_id LIMIT 1;
    SELECT work_order_part_id INTO v_work_order_part_id
    FROM work_order_part ORDER BY work_order_part_id LIMIT 1;
    SELECT transaction_id INTO v_inventory_transaction_id
    FROM inventory_transaction ORDER BY transaction_id LIMIT 1;
    SELECT spare_part_id INTO v_spare_part_id
    FROM spare_part ORDER BY spare_part_id LIMIT 1;

    START TRANSACTION;

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        INSERT INTO device_telemetry (
            pile_id, gun_id, collect_time, module_temp, quality_flag
        ) VALUES (
            v_pile_id, v_gun_id, CURRENT_TIMESTAMP(6), 250, 'NORMAL'
        );
    END;
    INSERT INTO c_constraint_results VALUES (
        'C01', 'telemetry temperature CHECK', v_error,
        IF(v_error = 3819, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        INSERT INTO spare_part (part_code, part_name, unit)
        SELECT part_code, 'duplicate-code-test', 'unit'
        FROM spare_part WHERE spare_part_id = v_spare_part_id;
    END;
    INSERT INTO c_constraint_results VALUES (
        'C02', 'spare part code uniqueness', v_error,
        IF(v_error = 1062, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        UPDATE inventory
        SET locked_quantity = quantity + 1
        WHERE inventory_id = (
            SELECT inventory_id FROM (
                SELECT inventory_id FROM inventory ORDER BY inventory_id LIMIT 1
            ) AS first_inventory
        );
    END;
    INSERT INTO c_constraint_results VALUES (
        'C03', 'locked quantity cannot exceed stock', v_error,
        IF(v_error = 3819, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        UPDATE inventory_transaction
        SET transaction_no = CONCAT(transaction_no, '-MUTATED')
        WHERE transaction_id = v_inventory_transaction_id;
    END;
    INSERT INTO c_constraint_results VALUES (
        'C04', 'inventory ledger is immutable', v_error,
        IF(v_error = 1644, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        UPDATE alarm SET alarm_status = 'OPEN' WHERE alarm_id = v_alarm_id;
    END;
    INSERT INTO c_constraint_results VALUES (
        'C05', 'alarm state transition guard', v_error,
        IF(v_error = 1644, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        UPDATE maintenance_work_order
        SET work_order_status = 'ASSIGNED'
        WHERE work_order_id = v_work_order_id;
    END;
    INSERT INTO c_constraint_results VALUES (
        'C06', 'work order state transition guard', v_error,
        IF(v_error = 1644, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        UPDATE work_order_part
        SET installed_qty = issued_qty + 1
        WHERE work_order_part_id = v_work_order_part_id;
    END;
    INSERT INTO c_constraint_results VALUES (
        'C07', 'installed quantity cannot exceed issue', v_error,
        IF(v_error = 3819, 'PASS', 'FAIL')
    );

    SET v_error = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_error = MYSQL_ERRNO;
        END;
        INSERT INTO inventory_transaction (
            transaction_no, warehouse_id, spare_part_id, transaction_type,
            quantity_change, before_quantity, after_quantity
        )
        SELECT
            'C-TEST-LEDGER-MISMATCH', warehouse_id, spare_part_id, 'ADJUSTMENT',
            1, 0, 1
        FROM inventory ORDER BY inventory_id LIMIT 1;
    END;
    INSERT INTO c_constraint_results VALUES (
        'C08', 'ledger must match inventory state', v_error,
        IF(v_error = 1644, 'PASS', 'FAIL')
    );

    ROLLBACK;
    SELECT test_id, test_name, observed_error, result
    FROM c_constraint_results ORDER BY test_id;
    IF EXISTS (SELECT 1 FROM c_constraint_results WHERE result <> 'PASS') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C_CONSTRAINT_TEST_FAILED';
    END IF;
END$$
DELIMITER ;

CALL sp_c_run_constraint_tests();
DROP PROCEDURE sp_c_run_constraint_tests;
DROP TEMPORARY TABLE c_constraint_results;
