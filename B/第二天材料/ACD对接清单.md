# A、C、D 对接清单

2026-11-19。本次按 D 的真实 DDL 接入用户和车辆。以下业务决议需要对方核对后在会议记录中写明确认人和日期。负责汇总的组长维护全局图和统一字典，各模块负责人核实本模块内容。

## A：到站资格、占位、公告

| 交接 | B 当前提供 | 请 A 提供或确认 |
| --- | --- | --- |
| 公共设施 | station、charging_pile、charging_gun、parking_space；主键均为 BIGINT UNSIGNED | A 的枪、站、车位引用字段类型与这些表一致 |
| 枪位绑定 | 当前每枪必绑同站一位，每位至多一枪 | 是否接受该基数；实际入位、驶离由 A 维护 |
| 到站资格 | 订单 channel 为 DIRECT / RESERVATION / QUEUE，admission_id 接业务资格编号 | reservation_id、queue_id 与 admission_id 的映射；有效区间、归属、状态、原子消费及失败回滚接口 |
| 实际占位 | B 返回枪绑定的 parking_space_id | 提供当前车辆占位及冲突查询；充电结束但车未驶离时保持占用 |
| 当前设备可用性 | v_b_gun_availability 组合营业、投运、设备状态、停运与进行中订单 | 该视图提供即时设备状态；预约未来时间段另查停运、预约及占位，不可直接复用当前快照 |
| 计划停运 | equipment_outage_plan 全站或单枪区间，左闭右开 | 和 C 确认唯一登记方、受影响预约筛选、取消/改约及通知恢复流程 |

A 表尚未交付时，B 可以验证结构、计费和资金规则。正式预约/叫号开单须完成资格与占位校验后接入，不能仅因 admission_id 在订单中未重复就视为资格有效。

## C：状态、维修与停运

| 交接 | B 当前结构 | 请 C 提供或确认 |
| --- | --- | --- |
| 设备标识 | pile_id、gun_id、station_id | 设备采样、告警、工单的正式字段及最终物理外键接入计划 |
| 设备状态 | 桩 READY/OFFLINE/FAULT；枪 READY/FAULT/DISABLED/OFFLINE；订单占用另行推导 | 故障置位、离线、维修、复核与恢复的每类唯一写入方；跨模块锁顺序 |
| 历史 | equipment_status_log，桩和枪二选一；状态修改触发日志 | 任务书的“空闲、占用、故障、离线”展示与占用时间线如何统一，桩级多枪占用如何定义 |
| 离线待办 | equipment_offline_task，每桩至多一项未关闭 | 心跳采集来源、正式超时阈值、扫描频率、待办到告警/工单的关联及关闭责任 |
| 档案变更 | equipment_change_request 记录型号变更申请及审批 | 申请人、审批人接哪个人员或账号实体；其他铭牌字段的变更范围 |
| 停运 | equipment_outage_plan 唯一共享表，登记方待定 | 全站或单枪范围是否足够；如需按桩停运，统一扩展范围设计；计划变更、撤回和恢复通知 |

当前 C 说明把设备 ID 作为逻辑引用。B 表已具备可引用的主键，双方应确定何时补物理外键，或记录最终采用逻辑引用的校验方式。B 本次提供表和状态历史触发器；心跳自动恢复、故障恢复和停运写入入口在明确责任后实现。

## D：正式外键已具备，业务事务继续接入

| 对接项 | 当前事实 | 下一步 |
| --- | --- | --- |
| 用户车辆 | charging_order.user_id -> user.user_id；vehicle_id -> vehicle.vehicle_id | 开单时检查用户状态、实名、余额、车辆状态和当时归属；外键只保证编号存在 |
| 活动场站 | promotion_station.station_id -> station.station_id | D 可按依赖顺序创建跨模块表并填适用站 |
| 锁券核销 | coupon.locked_order_id 和 coupon_redemption.order_id 引用订单；D 保证券与订单分别唯一核销 | 确认锁定、确认账单、全部或部分支付时的核销节点；失败/取消/退款恢复与幂等 |
| 计价金额 | gross_amount 原价、discount_amount 优惠；payable 是视图计算列 | 统一原价、优惠上限、舍入、免费服务费与起步补差；D 的百分比折扣表示实付比例 |
| 支付 | 一单多笔，SUCCESS/FAILED；channel+trade_ref 去重 | 接支付渠道凭证，处理重试、超付拦截；若余额支付需与 D 扣款事务一致 |
| 退款 | refund_record 只记录成功退款，通过 payment_id 回查订单 | 同一支付行锁下校验成功和可退余额；部分退款跨账期调整由双方定义 |
| 结算⑤ | 提供 operator、station、order、payment、refund 和 v_b_order_funds | D 继续结算 DDL；支付退款按各自发生时间统计，分别聚合再连接，迄今资金汇总不能直接当月流水 |

## 当前接入约定

- 编号采用 BIGINT UNSIGNED，英文 snake_case。各自维护自己的主数据。
- 本次 B SQL 及验证连接使用 +08:00；DATETIME 保存约定的北京时间，本地营业与峰平谷采用日内分钟。有效期、分时和停运区间采用左闭右开。D 的公共连接尚未统一设置会话时区，团队需将同一口径落实到所有连接后复验；这项是本次 B 接入选择。
- 目标环境沿用仓库 MySQL 8.0.46，实测环境为 8.4.13。Python 复用 app/database/connection.py、config.py 的 DB_* 配置。
- 当前顺序为 D 核心 → B 结构 → B 设施触发器及视图 → D 跨模块表。A/C 最终 DDL 到达后补全组依赖表和迁移顺序。
- 修改共享字段时先更新各自字典与接口说明，经对方核对后同步代码和汇总字典。
