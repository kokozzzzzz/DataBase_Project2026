# C 同学：③设备监控与故障工单、⑦备件库存与领用

本目录保存 C 模块已有的概念设计和新增的后续实现材料。该模块是“新能源汽车充电桩运营服务平台”课程设计的一部分。

## 目录结构

| 路径 | 用途 |
|---|---|
| `C_03_07_data_dictionary.xlsx` | 原始逻辑字段、表清单、关系、约束和待确认项。 |
| `37E-R图.png` | ③⑦联合局部 E-R 图初稿。 |
| `业务图/` | ③和⑦业务线的用例图、鲁棒图、局部 E-R 图；每张均提供 PNG 和 `.dot` 源文件。 |
| `C_03_07_实施说明.md` | 关系模型、执行顺序、DDL对象、Python接口、安全、备份和验收说明。 |
| `C_个人报告.md` | 按任务计划整理的个人报告初稿；真实验收结果需实测后填写。 |
| `C_答辩提纲.md` | 5分钟讲解顺序、建议演示和常见问题。 |
| `sql/C/` | C 模块 MySQL 8 数据库脚本。 |
| `c_app/` | Python 持久层、服务入口和只读演示。 |
| `tests/` | C 单元测试与只读真实数据库验收脚本。 |
| `tools/` | 从已部署数据库导出最终物理数据字典的工具。 |
| `C_03_07_physical_dictionary.csv` | 由导出工具生成，当前未生成；依赖已部署的 C 表。 |
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

- B 是桩、枪、设备状态和停运计划的主维护模块。C 不重复建表；桩/枪 ID 作为逻辑引用，运行在 B 表已创建的数据库中，并由触发器检查桩枪对应关系。
- 人员/操作人 ID 沿用外部编号，不另建重复人员表；需在组内接入统一账号表后再确定物理引用。
- 领用、退回、调整和冲正由过程在事务内同时修改库存及追加流水。库存行使用行锁和 `version_no` 条件更新保护并发。
- 工单备件不允许无记录损耗，关单要求 `issued_qty = installed_qty + returned_qty`。
- 离线阈值通过采集过程参数传入，不把临时阈值写死。`equipment_outage_plan` 由全组共享，登记责任人待 A/B/C 确认。

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
python -m pytest -q yX/tests
python yX/c_app/run_demo.py
python yX/tests/verify_c_module.py
```

演示脚本和验收脚本使用根目录 `.env` 与 `app.database.connection`。单元测试不需要连接 MySQL；真实数据库脚本需先按上述顺序部署和提交 C 测试数据。

当前实际环境没有可用的 MySQL 命令行程序，因此新增 SQL 尚未在本机 MySQL 8.0.46 上执行。最终个人报告和答辩中需填入真实运行的测试数、SQL检查、执行计划与双连接库存竞争结果，不应把计划当成实测结论。
