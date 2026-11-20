-- B 第三阶段增量，只在 01/02/03 已安装后首次执行。
-- 兼容 D 在首笔成功支付前锁券、失败释放及重新确认账单。
USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';
DELIMITER $$
CREATE TRIGGER b_fee_snapshot_no_update BEFORE UPDATE ON order_fee_detail FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='B_FEE_SNAPSHOT_IMMUTABLE';
END$$
CREATE TRIGGER b_fee_snapshot_no_delete BEFORE DELETE ON order_fee_detail FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='B_FEE_SNAPSHOT_IMMUTABLE';
END$$
CREATE TRIGGER b_billed_order_guard BEFORE UPDATE ON charging_order FOR EACH ROW
BEGIN
    IF OLD.state='BILLED' AND (
        NEW.state<>OLD.state OR NEW.gun_id<>OLD.gun_id
        OR NEW.user_id<>OLD.user_id OR NEW.vehicle_id<>OLD.vehicle_id
        OR NEW.starts_at<>OLD.starts_at OR NOT(NEW.ends_at <=> OLD.ends_at)
        OR NOT(NEW.total_kwh <=> OLD.total_kwh)
        OR NOT(NEW.gross_amount <=> OLD.gross_amount)
        OR NEW.channel<>OLD.channel OR NOT(NEW.admission_id <=> OLD.admission_id)
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='B_BILLED_FACTS_IMMUTABLE';
    END IF;
    IF OLD.state='BILLED' AND (
        NEW.discount_amount<>OLD.discount_amount
        OR NOT(NEW.confirmed_at <=> OLD.confirmed_at)
    ) AND EXISTS(SELECT 1 FROM payment_record
                 WHERE order_id=OLD.order_id AND status='SUCCESS') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='B_PAID_BILL_IMMUTABLE';
    END IF;
END$$
DELIMITER ;
