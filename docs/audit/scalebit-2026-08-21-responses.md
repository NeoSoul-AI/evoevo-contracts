# ScaleBit 2026-08-21 审计报告回复

对应审计报告：《Neosoul Preliminary Audit Report》（2026-08-21）。

下表逐条列出每个 finding 的处理结果，Fixed 条目附本仓库对应改动的简述（英文 issue 标题随附于处理说明中，便于审计方与原报告对照）。

| ID | Severity | 处理 | 说明 |
|----|----------|------|------|
| ECO-1 | Medium | Fixed | *(Inefficient active-juror iteration)* active 陪审员 EnumerableSet 索引替代全量扫描；新增 GOVERNOR 可配的 `maxActiveJurors` 上限（0=不限）。 |
| ECO-2 | Medium | Fixed | *(Challenge bond has no upside/downside asymmetry)* 挑战成立全额退还保证金（pull-payment）；额外激励暂不引入（挑战者为 CHALLENGE_ROLE 白名单运营方），后续版本再评估。超付说明：`challengePendingResult` 以 `>=` 校验 `msg.value` 并将全额计为 bond（成立全退 / 失败全没）——此为既有行为，非本次改动引入，特此明示以免复审误报为新问题。 |
| ECO-3 | Major | Fixed | *(No withdrawal path for settled bonds)* 新增 `treasury` + `pendingWithdrawals` + `withdraw()`；应急解决时按结果是否翻转结算退还 / 罚没。活性说明：Challenged 状态的 bond 锁定至 `EMERGENCY_GUARDIAN_ROLE` 行动为止（唯一出口是应急解决；资金可恢复、不会丢失）——此为设计固有约束，运维手册需包含 guardian 响应时限的规定。`pendingWithdrawals` 以**结算时**的 treasury 地址入账；此后更换 treasury 不会迁移已入账余额，故 treasury 必须是长期可用、可收 ETH 的地址。 |
| ECO-4 | Discussion | Fixed | *(Dual activation entry points with signature reuse ambiguity)* `activateJurorWithSig` 已删除，`SetJurorActive` 签名只剩单一消费者，互换问题不复存在。 |
| ECO-5 | Medium | Fixed | *(Quorum tally does not key by outcome)* 计票 key 为 (predictionId, resolutionKind, winningOptionIndex, optionVotes.length)，使 `_legacyOutcome` 读取的全部字段均有 quorum 背书；canonical 首提交者仅可提供 evidence 与票数值，不影响 outcome/resolution。 |
| ECO-7 | Discussion | Acknowledged | *(Retry requires entropy expiry)* 设计确认：重试要求熵过期是刻意的（防止在熵仍可得时重掷）。等待时长按链实测块时间：BSC（Maxwell，~0.75s）256 块 ≈ 3.2 分钟；0G 按其块时间同理，均在可接受范围。 |
| EBR-8 | Major | Fixed | *(Self-hosted registration bypass)* 删除 `registerAndBind` / `registerAndBindFor` / `setSelfHostedRegistrationEnabled` 及 Router 侧入口；`selfHostedRegistrationEnabled` 变量保留为存储占位。 |
| ECO-9 | Medium | Partially Fixed | *(Governance config lacks bounds / timelock)* 合约内新增全字段上下界与 primary 严格多数校验；timelock / 多签治理在运维层执行（`GOVERNOR_ROLE` 授予多签），暂不写入合约。 |
| ECO-10 | Minor | Fixed | *(Redundant no-op writes)* `_setJurorActive` 值未变化时直接 `return`，不写存储不发事件不耗 nonce。 |
| ECO-11 | Informational | Fixed | *(Redundant activation entry point)* 删除 `activateJuror`，`activateJurorWithSig` 已随 ECO-4 一并删除（两个冗余入口同时移除），仅保留 `setJurorActive` 单一入口。 |
| EBR-12 | Medium | Fixed | *(Unprotected reinitializer)* `initializeV2` 加 `onlyRole(ADMIN_ROLE)`；fresh 部署脚本在同一 broadcast 内原子调用 `initializeV2`。 |

## 升级说明

执行完代码后、真正在 BSC / 0G 升级时的运维注意：

1. 选择"安静窗口"升级：链上不存在处于 `Voting` / `PendingFinality` / `Challenged` 状态的 prediction（ECO-5 计票口径切换不兼容在途投票；已有 Challenged 的保证金结算逻辑兼容，无需迁移）。
2. Oracle 用 `upgradeToAndCall(newImpl, abi.encodeCall(initializeV2, ()))` 原子完成陪审员索引回填。
3. 升级前确认线上 BindingRegistry proxy 的 `initializeV2` 是否已被调用（0G 已调、BSC 未调则本次补上）；执行账户须持有各 proxy 的 `ADMIN_ROLE`。
4. 升级完成后（或与升级同一批交易内）由 `ADMIN_ROLE` 调用 `setTreasury(<运营金库地址>)`，并确认该地址能接收 plain ETH 转账；在 treasury 设置之前，任何"挑战被驳回"路径的应急解决会以 `TreasuryNotSet` revert（fail-closed，可恢复）。fresh 部署同理，部署后立即设置。

## 存储布局升级安全证明

`EvoCommitteeOracle`、`EvoBindingRegistry`、`EvoUserActionRouter` 三份改动前 `forge inspect storage-layout` 基线（`docs/audit/storage-baseline/*.json`，Task 1 生成）与改动后布局逐槽比对，确认所有既有 slot 的 `label`/`slot`/`offset`/`type` 均未变化，仅在 `EvoCommitteeOracle` 尾部追加 6 个新变量：

| 追加变量 | slot | 说明 |
|----------|------|------|
| `_activeJurorTokenIds` | 18 | ECO-1，active 陪审员索引 |
| `maxActiveJurors` | 20 | ECO-1，上限配置 |
| `_outcomeApprovalCounts` | 21 | ECO-5，按结果 key 的计票 |
| `_outcomeCanonicalProposal` | 22 | ECO-5，canonical 提案指针 |
| `treasury` | 23 | ECO-3，国库地址 |
| `pendingWithdrawals` | 24 | ECO-3，待提现余额 |

`EvoBindingRegistry`、`EvoUserActionRouter` 均为 0 追加（本次改动仅删除函数/事件，未新增状态变量）。UUPS 可升级性未被破坏。
