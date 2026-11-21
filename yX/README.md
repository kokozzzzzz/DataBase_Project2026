# C 同学：③设备监控与故障工单、⑦备件库存与领用

> **2026-11-21更新**：最新全组进度、规则、升级步骤及分工见[集成修正与交接](../docs/集成修正_2026-11-21/README.md)。下文保留本模块历史记录，以最新交接说明为准。

本目录保存 C 模块已有的概念设计和新增的后续实现材料。该模块是“新能源汽车充电桩运营服务平台”课程设计的一部分。

先按[C更新操作](C_更新操作_2026-11-21.md)完成本机升级和复验。

## 目录结构

| 路径 | 用途 |
|---|---|
| `C_03_07_data_dictionary.xlsx` | 原始逻辑字段、表清单、关系、约束和待确认项。 |
| `37E-R图.png` | ③⑦联合局部 E-R 图初稿。 |
| `业务图/` | ③和⑦业务线的用例图、鲁棒图、局部 E-R 图；每张均提供 PNG 和 `.dot` 源文件。 |
| `C_03_07_实施说明.md` | 关系模型、执行顺序、DDL对象、Python接口、安全、备份和验收说明。 |
| `C_更新操作_2026-11-21.md` | 本机更新、事务调用与后续交付步骤；个人报告和答辩提纲仍需补交。 |
| `sql/C/` | 兼容转发入口；正式脚本维护于仓库根 `sql/C/`。 |
| `c_app/` | 兼容入口；正式代码在公共app的c_repository/c_service/run_c_demo。 |
| `tests/` | C 单元测试与只读真实数据库验收脚本。 |
| `tools/` | 从已部署数据库导出最终物理数据字典的工具。 |
| `C_03_07_physical_dictionary.csv` | 本次从MySQL8.0.46实际库导出的物理字段快照。 |
| `summarize.md` | 仓库文件夹和文件概览。 |

## 八张实体表

**③设备监控与故障工单**

1. `device_telemetry`：按采集时刻存储桩/枪电压、电流、功率、温度、离线时长和故障码。
2. `alarm`：告警级别、发生/恢复时间、复核状态和来源采样。
3. `maintenance_work_order`：派单、接单、到场、维修和复核闭环；一条告警可关联多张历史工单。

**⑦备件库存与领用**

4. `spare_part`：备件档案。
5. `warehouse`：仓库档案。
6. `inventory`：仓库与备件组合的当前库存、锁定数量和版本号。
7. `inventory_transaction`：收货、领用、退料、盘点调整和冲正的不可变流水。
8. `work_order_part`：工单备件计划、领用、安装和退回数量明细。

## 关键设计约定

- B维护桩枪资产及表结构，C通过统一服务维护运行故障、离线与维修复核状态、登记共享停运计划。C 不重复建表；桩/枪 ID 作为逻辑引用，运行在 B 表已创建的数据库中，并由触发器检查桩枪对应关系。
- 人员/操作人 ID 沿用外部编号，不另建重复人员表；需在组内接入统一账号表后再确定物理引用。
- 领用、退回、调整和冲正由过程在事务内同时修改库存及追加流水。库存行使用行锁和 `version_no` 条件更新保护并发。
- 工单备件不允许无记录损耗，关单要求 `issued_qty = installed_qty + returned_qty`。
- 离线阈值通过采集过程参数传入，不把临时阈值写死。`equipment_outage_plan` 由全组共享，登记由C负责，A通知、A/B读取拦截。

## 建议执行顺序

确保 D、B 模块表已经安装，连接 `charging_platform` 后按顺序执行：

```sql
SOURCE yX/sql/C/01_schema.sql;
SOURCE yX/sql/C/02_triggers.sql;
SOURCE yX/sql/C/03_procedures.sql;
SOURCE yX/sql/C/04_views.sql;

-- 仅对空的 C 表执行；需要 B 已经准备桩和枪测试数据。
SOURCE yX/sql/C/05_seed.sql;
-- 检查行数后人工 COMMIT；发现错误则 ROLLBACK。

SOURCE yX/sql/C/07_verify.sql;
SOURCE yX/sql/C/06_business_queries.sql;
SOURCE yX/sql/C/08_constraint_tests.sql;
```

完整说明见 [C_03_07_实施说明.md](C_03_07_实施说明.md)。DDL/过程不能在未验证的正式共享库上盲目重复执行；库存流水禁止篡改删除。

## Python 验证

从仓库根目录运行：

```powershell
python -m pytest -q
python -m app.run_c_demo
python tests/verify_c_module.py --output C_本机验收
```

演示脚本和验收脚本使用根目录 `.env` 与 `app.database.connection`。单元测试不需要连接 MySQL；真实数据库脚本需先按上述顺序部署和提交 C 测试数据。

2026-11-21已在MySQL8.0.46完成16项C结构/数据验收、8项约束测试及跨模块真实联调，包含双连接库存竞争、安装/退料和外层回滚；证据见全组集成目录。个人报告、查询执行计划和答辩材料仍需按本人实际工作补齐。
