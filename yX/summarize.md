# 仓库文件夹与文件说明

本文按当前工作区实际文件整理。项目是“新能源汽车充电桩运营服务平台”课程设计，统一数据库名为 `charging_platform`，技术栈为 MySQL、PyMySQL/SQLAlchemy 和 pytest。

## 根目录

| 文件 | 功能 |
|---|---|
| [README.md](../README.md) | 项目总体说明：八条业务线、成员分工、技术栈、核心规则、仓库结构、验收和快速运行。 |
| [requirements.txt](../requirements.txt) | Python 依赖清单，包括 PyMySQL、SQLAlchemy、python-dotenv、pytest 等。 |
| [.env.example](../.env.example) | 数据库连接环境变量模板；真实 `.env` 不提交。 |
| [.gitignore](../.gitignore) | 忽略虚拟环境、缓存、真实环境变量和本地临时文件。 |

## `A/`

A 模块的图形、工具和第三阶段实测证据目录。A 模块负责⑥预约排队与⑧公告通知。

| 文件/目录 | 功能 |
|---|---|
| [README.md](../A/README.md) | A 模块导航、交付清单、验收结果、接口、复现和待确认事项。 |
| [A/业务图/](../A/业务图/) | 用例图、鲁棒图、局部 E-R 图及可重渲染的 Graphviz `.dot` 源码。 |
| [A/工具/](../A/工具/) | A 模块辅助工具。 |
| [A/第三天材料/](../A/第三天材料/) | MySQL 和 Python 实测证据。 |

### `A/业务图/`

- `01_⑥预约排队_用例图.dot/.png`：⑥预约排队用例图源码及渲染图。
- `02_⑧公告通知_用例图.dot/.png`：⑧公告通知用例图源码及渲染图。
- `03_⑥预约到站_鲁棒图.dot/.png`：预约到站过程的鲁棒图源码及渲染图。
- `04_⑧公告通知_鲁棒图.dot/.png`：公告发布、定向通知和撤回的鲁棒图源码及渲染图。
- `05_⑥预约排队_局部ER图.dot/.png`：预约、排队、核验、占位实体关系图源码及渲染图。
- `06_⑧公告通知_局部ER图.dot/.png`：公告、版本、接收人、通知实体关系图源码及渲染图。

### `A/工具/`

- [generate_data_dictionary.py](../A/工具/generate_data_dictionary.py)：读取 MySQL `information_schema` 和行数，重新生成⑥⑧数据字典 Excel。

### `A/第三天材料/实测/`

| 文件 | 功能 |
|---|---|
| [README.md](../A/第三天材料/实测/README.md) | 汇总 A 模块本机验收环境、对象、约束、并发和回滚结果。 |
| `business_queries.txt` | Q01～Q07 业务查询执行证据。 |
| `constraint_tests.txt` | 16 项约束、状态机和过程测试结果。 |
| `demo_concurrency.txt` | 同枪并发预约演示结果。 |
| `demo_notice.txt` | 公告演示执行结果。 |
| `demo_notice_workflow.txt` | 公告发布、发送、撤回事务演示结果。 |
| `demo_reservation.txt` | 预约看板演示结果。 |
| `demo_reservation_workflow.txt` | 预约核验占位事务演示结果。 |
| `schema_verify.txt` | 表、字段、外键、CHECK、视图、过程和触发器结构核查。 |
| `unit_tests.txt` | Python 单元测试执行结果。 |
| `verify_a_module.json` | 17 项验收的结构化 JSON 结果。 |
| `verify_a_module.txt` | 17 项验收的文本结果。 |

## `B/`

B 模块负责①场站与充电设施、②充电订单与计费。

| 文件/目录 | 功能 |
|---|---|
| [README.md](../B/README.md) | B 第二阶段交付、建表范围、接入顺序、对接约定和后续计划。 |
| [B_第一天统一数据字典.xlsx](../B/B_第一天统一数据字典.xlsx) | 第一阶段逻辑字典和需求追溯。 |
| [B/业务图/](../B/业务图/) | 场站设施、交易计费用例图、鲁棒图和局部 E-R 图及源码。 |
| [B/第二天材料/](../B/第二天材料/) | 第二阶段物理字典、关系模式、对接清单、验证记录和元数据导出。 |

### `B/业务图/`

- `01 设施用例图.dot/.png`：设施档案、状态和运维用例。
- `02 设施鲁棒图.dot/.png`：设施功率校验、状态历史和业务对象交互。
- `04 交易用例图.dot/.png`：开单、计费、支付、退款和异常复核。
- `⑤交易鲁棒图.dot/.png`：交易主流程鲁棒图及渲染图（仓库实际名为 `05 交易鲁棒图.dot/.png`）。
- `① 场站与充电设施_局部ER图.dot/.png`：场站—桩—枪—车位—状态日志实体关系。
- `② 充电订单与计费_局部ER图.dot/.png`：订单、费率、费用明细、支付、退款实体关系。

### `B/第二天材料/`

| 文件 | 功能 |
|---|---|
| [B_第二天物理数据字典.xlsx](../B/第二天材料/B_第二天物理数据字典.xlsx) | 16 张表的正式物理字段、键、类型、精度、约束和备注。 |
| [B_物理字段数据字典.csv](../B/第二天材料/B_物理字段数据字典.csv) | 字段字典文本导出，便于审查。 |
| [关系模式与设计说明.md](../B/第二天材料/关系模式与设计说明.md) | 键、函数依赖、3NF、有意冗余、快照、资金汇总和索引分析。 |
| [ACD对接清单.md](../B/第二天材料/ACD对接清单.md) | 与 A/C/D 的公共编号、接口、写入责任和待确认规则。 |
| [建表验证记录.md](../B/第二天材料/建表验证记录.md) | 环境、执行顺序、20 项验证、资金样例、回滚边界和后续工作。 |

`B/第二天材料/实测/` 中：

- `物理字段.csv`：实际表、列、类型、主外键、空值和默认值。
- `外键明细.csv`：实际外键约束及引用关系。
- `检查约束.csv`：实际 CHECK 约束表达式。
- `索引明细.csv`：实际主键、唯一和普通索引。
- `建表验证结果.json`：20 项结构与正反例验收结果。

## `app/`

Python 应用入口、数据库持久层、事务服务和演示脚本。

| 文件/目录 | 功能 |
|---|---|
| [app/__init__.py](../app/__init__.py) | 标记 `app` 为 Python 包。 |
| [app/database/](../app/database/) | 数据库配置、连接、Repository 和存储过程封装。 |
| [app/services/](../app/services/) | 会员、车队、优惠、预约和公告事务服务。 |
| [app/run_*_demo.py](../app/) | 会员、车队、优惠、预约和公告演示入口。 |

### `app/database/`

| 文件 | 功能 |
|---|---|
| `__init__.py` | 标记数据库子包。 |
| `config.py` | 从环境变量读取配置，校验端口、库名和密码。 |
| `connection.py` | 创建并关闭 PyMySQL连接；异常回滚，事务上下文成功提交。 |
| `membership_repository.py` | 会员档案、数据库健康状态和可用全场活动只读查询。 |
| `reservation_repository.py` | 预约看板、排队看板、占位、履约、详情和状态历史查询。 |
| `notice_repository.py` | 公开公告、送达统计、受影响用户、版本和待发送通知查询。 |
| `procedure.py` | 调用存储过程并读取 OUT 参数，将常见 MySQL 错误翻译为中文业务异常。 |

### `app/services/`

| 文件 | 功能 |
|---|---|
| `__init__.py` | 标记服务子包。 |
| `membership_service.py` | 锁定用户行，原子更新等级并写入会员历史。 |
| `fleet_service.py` | 串行化车辆加入/退出车队，保证一车最多一条有效关系并保留历史。 |
| `promotion_service.py` | 使用 Decimal 计算固定减免、折扣、门槛、封顶和最优活动。 |
| `reservation_service.py` | 预约、改约、取消、核验、排队、叫号、释放和资格消费。 |
| `notice_service.py` | 公告创建、发布、撤回、通知状态更新和过期处理。 |

### `app` 演示入口

- `run_membership_demo.py`：演示会员档案及数据库健康状态。
- `run_membership_transaction_demo.py`：演示会员等级和历史同时更新并回滚。
- `run_fleet_transaction_demo.py`：演示车辆退出原车队、加入目标车队并回滚。
- `run_promotion_demo.py`：演示活动筛选和最优优惠计算。
- `run_reservation_demo.py`：演示预约和排队只读看板。
- `run_reservation_workflow_demo.py`：演示预约、核验、占位事务并回滚。
- `run_reservation_concurrency_demo.py`：演示同枪并发预约并清理测试数据。
- `run_notice_demo.py`：演示公开公告和送达统计只读看板。
- `run_notice_workflow_demo.py`：演示定向公告发布、发送、撤回并回滚。

## `sql/`

按成员划分的 DDL、触发器、过程、视图、种子和验收脚本。

### `sql/A/`

| 文件 | 功能 |
|---|---|
| `00_local_shared_fixtures.sql` | 本地联调夹具；正式联调应替换为 B 的正式种子。 |
| `01_schema.sql` | 10 张 A 表及外键、唯一、生成列、CHECK 和索引。 |
| `02_triggers.sql` | 冲突兜底、状态机、状态历史、核验占位、公告版本和通知状态。 |
| `03_procedures.sql` | 预约、改约、取消、排队、叫号、核验、释放、资格消费、过期和公告过程。 |
| `04_views.sql` | 预约、排队、占用、履约、公告、送达、受影响用户等 8 个视图。 |
| `05_seed.sql` | 10 张表测试数据，每张至少 20 条，不自动提交。 |
| `06_business_queries.sql` | Q01～Q07 预约压力、转化、排队、占位、触达、送达率和冲突查询。 |
| `07_verify.sql` | 只读结构、行数、状态一致性和冲突验收。 |
| `08_constraint_tests.sql` | 16 项约束、触发器和过程正反例测试，统一回滚。 |
| `README.md` | 执行顺序、依赖、文件说明和验收命令。 |

### `sql/B/`

- `00_preflight.sql`：建表前检查数据库、目标表和关键依赖。
- `01_schema.sql`：创建16张设施、费率、订单、支付、退款表。
- `02_structure_triggers.sql`：创建7个枪桩功率限制和状态历史触发器。
- `03_views.sql`：创建设备可用性、订单资金汇总等6个视图。
- `04_verify_structure.sql`：只读核查表结构、外键、生成列和索引。

### `sql/D/`

| 文件 | 功能 |
|---|---|
| `04_membership_core.sql` | 会员等级、用户、车辆、会员历史、活动、企业、车队、额度等9张核心表。 |
| `04_membership_seed_core.sql` | 核心表各20条测试数据，不自动提交。 |
| `04_membership_verify.sql` | 核心表引擎、字符集、主外键、CHECK和ID类型只读验收。 |
| `04_membership_constraint_tests.sql` | T01～T08唯一、非负、外键、时间、状态约束测试。 |
| `04_membership_business_queries.sql` | Q01～Q09会员档案、等级、车队、额度、活动查询。 |
| `04_membership_views.sql` | 用户会员档案、有效车队、全场活动等3个视图。 |
| `04_membership_views_verify.sql` | 视图存在性、敏感字段暴露和行数验收。 |
| `04_membership_procedure.sql` | 优惠试算存储过程。 |
| `04_membership_procedure_verify.sql` | 过程权限、固定减免、折扣和门槛验收。 |
| `04_membership_final_verify.sql` | F01～F08核心部分综合回归。 |
| `04_membership_integration.sql` | 活动适用场站、优惠券、优惠券核销等3张跨模块表。 |
| `04_membership_integration_verify.sql` | I01～I07跨模块外键、约束、唯一性、类型和初始数据验收。 |

## `tests/`

pytest 单元测试及真实 MySQL 验收脚本。

| 文件 | 功能 |
|---|---|
| `test_database_config.py` | 环境变量读取、缺失密码、数据库名校验。 |
| `test_membership_repository.py` | 用户档案、分页、参数化和非法状态过滤。 |
| `test_membership_service.py` | 等级变更、同等级拒绝、缺失用户和事务。 |
| `test_fleet_service.py` | 车辆加入/退出车队及有效关系冲突。 |
| `test_promotion_service.py` | 固定减免、折扣、封顶、门槛和最优活动。 |
| `test_reservation_repository.py` | 预约、排队、占位、履约和状态历史查询。 |
| `test_reservation_service.py` | 预约、核验、排队、叫号、释放和资格消费输入。 |
| `test_notice_repository.py` | 公告、送达、受影响用户、版本和待发送通知查询。 |
| `test_notice_service.py` | 公告创建、发布、撤回、通知状态和过期处理。 |
| `test_procedure.py` | 存储过程调用、OUT参数和 MySQL 错误翻译。 |
| `test_transaction.py` | 事务提交、回滚和上下文行为。 |
| `verify_a_module.py` | 真实 A 模块结构、数据、工作流、并发和回滚验收。 |
| `verify_b_structure.py` | 真实 B–D 结构、外键、约束和事务回滚验收，包含20项检查。 |

## `docs/`

全组文档、统一字典、任务分工、流程图和模块说明。

| 文件/目录 | 功能 |
|---|---|
| `八条业务线统一数据字典模板_MySQL_Python.xlsx` | 八条业务线实体、字段、关系、接口、约束和规则的全组模板。 |
| `四人四天任务分工计划_八条业务线_MySQL_Python.docx` | 四天任务、验收清单、风险和交付安排。 |
| `第一天详细执行方案_八条业务线_MySQL_Python.docx` | Day 1需求、公共编号、跨模块规则和执行方案。 |
| `新能源汽车充电桩平台_八条业务线整体业务流程图.png/.svg` | 八条业务线及跨模块交接关系的 PNG 和可缩放 SVG 流程图。 |
| [docs/a/](../docs/a/) | A 模块⑥⑧详细设计、字典和导航。 |
| [docs/d/](../docs/d/) | D 模块④⑤详细设计、字典和导航。 |

### `docs/a/`

- `README.md`：A 模块状态、交付、验收、接口、运行方式和待确认事项。
- `06_reservation_queue.md`：⑥需求、状态机、概念/逻辑/物理结构、过程、并发、索引和测试。
- `08_notice.md`：⑧需求、状态机、版本、接收人、通知、触发器、过程和安全。
- `A_06_08_data_dictionary.xlsx`：⑥⑧共10表116字段的数据字典。

### `docs/d/`

- `README.md`：D 模块状态、交付、验收、接口和运行方式。
- `04_membership.md`：④会员 DDL执行顺序、表、视图、过程、验收和设计说明。
- `05_settlement.md`：⑤结算与对账规划；实体和口径仍需继续补充。
- `D_04_05_data_dictionary.xlsx`：④⑤字段、实体、关系和约束字典。

## `target/`

- [DB课设思路_01.docx](../target/DB课设思路_01.docx)：小组课设方案、五条原业务线和三条新增业务线。
- [新能源汽车充电桩运营服务平台课程设计2026年任务书.pdf](../target/新能源汽车充电桩运营服务平台课程设计2026年任务书.pdf)：学校任务书，定义业务范围、验收和答辩材料。

## `yX/`

- [README.md](../yX/README.md)：C 模块③设备监控与⑦备件库存导航、数据库依赖、运行方式和实测边界。
- [C_03_07_data_dictionary.xlsx](../yX/C_03_07_data_dictionary.xlsx)：③⑦完整字段、表、关系和约束字典。
- [37E-R图.png](../yX/37E-R图.png)：③⑦联合局部 E-R 图初稿。
- [业务图/](../yX/业务图/)：两条业务线各有用例图、鲁棒图和局部 E-R 图，包含 PNG 成图与 `.dot` 源文件。
- [C_03_07_实施说明.md](../yX/C_03_07_实施说明.md)：设计依据、执行顺序、8张表、触发器、存储过程、视图、Python接口、安全与备份说明。
- [sql/C/](../yX/sql/C/)：schema、触发器、过程、视图、20条/表测试种子、6条多表SQL、验收及约束测试脚本。
- [c_app/](../yX/c_app/)：参数化 Repository、业务服务、只读看板演示。
- [tests/](../yX/tests/)：C 单元测试和真实数据库只读验收脚本。
- [tools/](../yX/tools/)：从部署后的 `information_schema` 导出物理字典 CSV 的工具。
- `C_03_07_physical_dictionary.csv`：运行导出工具后生成的物理字典，目前尚未生成。
- [summarize.md](./summarize.md)：本文件。

C 当前新增交付覆盖 SQL、Python 持久层、测试；Python 单元测试 13 项已通过。实际 MySQL 8.0.46 集成验收、双连接库存竞争测试和执行计划需在具备对应数据库的环境运行后补证据。

## `DataBase_Project2026/`

这是仓库内的嵌套项目快照，相对根目录更偏向早期 Day 1 文档，不是主要实现目录。

| 文件/目录 | 功能 |
|---|---|
| [README.md](../DataBase_Project2026/README.md) | 快照的项目和 Day 1 开发计划说明。 |
| [requirements.txt](../DataBase_Project2026/requirements.txt) | 快照的 Python依赖清单副本。 |
| [.gitignore](../DataBase_Project2026/.gitignore) | 快照自身忽略规则。 |
| [docs/](../DataBase_Project2026/docs/) | 快照中的任务分工、流程图、执行方案和 D 模块说明。 |
| [target/](../DataBase_Project2026/target/) | 快照中的课设思路和任务书副本。 |

嵌套目录具体文件为：

- `docs/八条业务线统一数据字典模板_MySQL_Python.xlsx`：全组数据字典模板副本。
- `docs/四人四天任务分工计划_八条业务线_MySQL_Python.docx`：分工计划副本。
- `docs/第一天详细执行方案_八条业务线_MySQL_Python.docx`：Day 1执行方案副本。
- `docs/新能源汽车充电桩平台_八条业务线整体业务流程图.png/.svg`：整体流程图副本。
- `docs/d/README.md`：D 模块导航副本。
- `docs/d/04_membership.md`：④会员 DDL说明副本。
- `docs/d/05_settlement.md`：⑤结算设计副本。
- `docs/d/D_04_05_data_dictionary.xlsx`：D模块数据字典副本。
- `target/DB课设思路_01.docx`：课设思路副本。
- `target/新能源汽车充电桩运营服务平台课程设计2026年任务书.pdf`：任务书副本。

## 总体阅读顺序与状态

1. 先读根目录 README 和 requirements，再读 target 与 docs 的任务书、字典、分工和流程图。
2. 再读 A/B/D/C 模块说明，区分已实现、已验收和规划中内容。
3. 按依赖执行 `sql/D/`、`sql/B/`、`sql/A/` 和 `yX/sql/C/`；A/C依赖 B 的设施、设备和订单等共享表。
4. 使用 app 演示和 tests 单元测试、真实验收脚本验证。
5. C 的③⑦已经补充 SQL、Python 持久层和测试框架，Python 单元测试 13 项通过；真实 MySQL 集成、双连接库存竞争与报告验收数据仍待执行；D 的⑤结算对账及 B/C 部分应用联调仍需继续完善。
