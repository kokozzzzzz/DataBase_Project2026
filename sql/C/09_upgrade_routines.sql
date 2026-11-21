-- 已有C表的过程升级；暂停C写入入口，确认无业务事务后执行。
-- 只替换过程定义，保留表、数据、视图及库存流水。DDL会隐式提交。
USE charging_platform;
DROP PROCEDURE IF EXISTS sp_c_ingest_telemetry;
DROP PROCEDURE IF EXISTS sp_c_dispatch_work_order;
DROP PROCEDURE IF EXISTS sp_c_advance_work_order;
DROP PROCEDURE IF EXISTS sp_c_verify_work_order;
DROP PROCEDURE IF EXISTS sp_c_cancel_work_order;
DROP PROCEDURE IF EXISTS sp_c_plan_work_order_part;
DROP PROCEDURE IF EXISTS sp_c_receive_stock;
DROP PROCEDURE IF EXISTS sp_c_issue_work_order_part;
DROP PROCEDURE IF EXISTS sp_c_return_work_order_part;
DROP PROCEDURE IF EXISTS sp_c_record_part_installation;
DROP PROCEDURE IF EXISTS sp_c_adjust_stock;
DROP PROCEDURE IF EXISTS sp_c_reverse_inventory_transaction;
SOURCE sql/C/03_procedures.sql;
