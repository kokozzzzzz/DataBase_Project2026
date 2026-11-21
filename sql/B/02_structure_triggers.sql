USE charging_platform;
SET SESSION time_zone = '+08:00';
DELIMITER $$
CREATE TRIGGER b_gun_power_insert BEFORE INSERT ON charging_gun FOR EACH ROW
BEGIN
 DECLARE capacity DECIMAL(8,2);
 SELECT rated_kw INTO capacity FROM charging_pile WHERE pile_id=NEW.pile_id FOR UPDATE;
 IF NEW.max_kw > capacity THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Gun exceeds pile rated power'; END IF;
END$$
CREATE TRIGGER b_gun_power_update BEFORE UPDATE ON charging_gun FOR EACH ROW
BEGIN
 DECLARE capacity DECIMAL(8,2);
 SELECT rated_kw INTO capacity FROM charging_pile WHERE pile_id=NEW.pile_id FOR UPDATE;
 IF NEW.max_kw > capacity THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Gun exceeds pile rated power'; END IF;
END$$
CREATE TRIGGER b_pile_power_update BEFORE UPDATE ON charging_pile FOR EACH ROW
BEGIN
 DECLARE largest DECIMAL(8,2);
 IF NEW.rated_kw<OLD.rated_kw THEN
  SELECT MAX(max_kw) INTO largest FROM charging_gun WHERE pile_id=OLD.pile_id FOR UPDATE;
  IF NEW.rated_kw < largest THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Existing gun exceeds new pile power'; END IF;
 END IF;
END$$
CREATE TRIGGER b_pile_status_insert AFTER INSERT ON charging_pile FOR EACH ROW
 INSERT INTO equipment_status_log(pile_id,new_status) VALUES(NEW.pile_id,NEW.status)$$
CREATE TRIGGER b_pile_status_update AFTER UPDATE ON charging_pile FOR EACH ROW
BEGIN
 IF OLD.status<>NEW.status THEN
  INSERT INTO equipment_status_log(pile_id,old_status,new_status) VALUES(OLD.pile_id,OLD.status,NEW.status);
 END IF;
END$$
CREATE TRIGGER b_gun_status_insert AFTER INSERT ON charging_gun FOR EACH ROW
 INSERT INTO equipment_status_log(gun_id,new_status) VALUES(NEW.gun_id,NEW.status)$$
CREATE TRIGGER b_gun_status_update AFTER UPDATE ON charging_gun FOR EACH ROW
BEGIN
 IF OLD.status<>NEW.status THEN
  INSERT INTO equipment_status_log(gun_id,old_status,new_status) VALUES(OLD.gun_id,OLD.status,NEW.status);
 END IF;
END$$
DELIMITER ;
