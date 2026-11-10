# 实验设计（v6.13）

base case：`benchmark/benchmark_params.jl` 的默认值（站点分工：DC1 训练园区 / DC2 推理 / DC3 混合云；RRS 峰值 5,000；N_FFR = 50/27/12；UPS 后备保留 3 min；R_mkt = 250 MW；F = 0.25；M_band = 0.02；K_L = 3；逆变器损耗精确等式；事件分担精修；v6.13：Q_lo = 1.00 满额、跨小时补做截止检查、电池事件模式和最小功率、空载损耗计入）。

**v6.13 的所有组都要重新跑**（base 变了，旧的 summary.csv 不能混用）。建议用新的输出文件夹，例如 `FFR_EXP_OUTPUT=experiments/results_v613`。
每个 case 报告：f^FFR、C0、容量收入、ΔC^DA、期望事件成本、FFR MW-h、整个事件和 sustain 段中 BESS / IT / 发电机的能量和占比、发电机期望年启动次数和年运行小时、迁移比例、WAN 最大利用率、求解时间和 bound。

| 组 | 变什么 | 取值 | 要回答的问题 | 复用 C0 |
|---|---|---|---|---|
| E1 | base case | — | 基准 | — |
| E2 | 合格发电机数（base 的倍数） | ×0, 0.25, 0.5, 0.75, 1 | 发电机越多，利润和 BESS / IT / 发电机分担怎么变；×0 时 BESS 和 IT 能撑多少 | 是 |
| E3 | 发电机全接管 sustain 段 | ×0.5, 0.75, 1 | 与 E2 对比：让 BESS、IT 也参与持续段值多少钱 | 是 |
| E4 | UPS 后备保留时间 | 2, 2.5, 3, 3.5, 4 min | 给 FFR 让出的 BESS 能量越少，发电机和 IT 份额怎么变 | 否 |
| E5 | RRS 价格情景 | cap_peak_5000 / aug2023_level / jun2026_actual / record_peak_25000 | 价格从上限到当前水平，报价量和资源组合 | 是 |
| E6 | 发电机启动并网时间 T_G | 15, 30, 60 s | 桥接段变长时 BESS / IT 的负担 | 是 |
| E7 | 发电机加载时间 T^{G,load} | 10, 30, 60, 120 s | 爬坡越慢，BESS 要多撑多久 | 是 |
| E8 | loading 段数 K_L | 1, 3, 6 | 检查离散化：BESS 段内线性后结果应基本不变 | 是 |
| E9 | 上限一侧的设计余量 M_band（下限固定为满额） | 0, 0.02, 0.04 | 上限余量的代价 | 是 |
| E10 | sustain 段 IT 可放慢比例（两类任务同值） | 0, 0.10, 0.20, 0.30 | IT 只做桥接和持续参与的差别 | 是 |
| E11 | 机群 FFR 上限 R_mkt | 100, 250, 400 MW | 上限是否约束报价 | 是 |
| E12 | 报价上限 F（占设施负荷） | 0.15, 0.25, 0.35 | 运营方愿意拿出多少负荷 | 是 |
| E13 | UPS 覆盖比例 U | 0.4, 0.6, 0.8 | UPS 功率是否限制报价（第一阶段发电机为 0） | 否 |
| E14 | WAN 波长数 | 0, 1, 2, 4 | 带宽对负载迁移和 FFR 的影响 | 否 |
| E15 | IT 功率爬坡限制 | 无, 0.30, 0.15, 0.10 | 负载能否集中到高价小时 | 否 |
| E16 | 事件空载逆变器损耗（v6.13 base：计入，按开机的块和段） | 不计 / 计入 | 空载损耗对报价和后备余量的影响 | 是 |
| E17 | 逆变器损耗 | 精确等式 / 凸松弛 | 松弛是否紧、能省多少求解时间 | 否 |
| E18 | IT 灵活度 | 见下表 | 站点分工和任务迁移让 IT 占比提高多少，哪些参数决定它 | 部分 |
| E19 | 审稿修改 F1–F3 的消融 | 见下表 | 每项修改单独值多少钱，v6.12 写法高估了多少 | 是 |

E18 的 case：

| case | 改什么 | 回答的问题 |
|---|---|---|
| homogeneous_v6.9 | v6.9 的同质负载 | 对照：没有站点分工时 IT 占比约 3% |
| roles_base | 默认的站点分工 | 主结果，目标 IT 占比 10–20% |
| roles_no_migration | WAN = 0 | 训练任务困在满载的 DC1 时 IT 能贡献多少 |
| train_delay=3h / 12h | 训练最长可延迟 | 可延迟空间的影响 |
| train_A_sustain=0.1 / 0.2 / 0.25 | 训练可放慢比例（0–60 s 段多 0.05；base 0.15） | IT 占比对放慢比例的敏感度，用来把 IT 定在 10–20% |
| QoS_cap=10% / 25% | M^QoS | QoS 上限是否卡住 IT（结果相近说明不是瓶颈） |
| idle_reserve=0 / 30% | DC2、DC3 保留的空闲 | 推理站空闲容量对迁移和 IT 的影响 |
| train_absorb=off | 训练放慢后要在 3 h 内补做（v6.11 做法） | 作业延后完成这一假设的作用 |
| train_absorb=off_makeup=6h | 同上，窗口 6 h | 窗口长短的影响 |
| makeup_reserve=off | 补做不能用推理站的空闲 | 对照 v6.10 的做法 |

E19 的 case（回答审稿意见 F1–F3）：

| case | 改什么 | 回答的问题 |
|---|---|---|
| v6.13_base | 默认 | 与 E1 相同（输入相同只解一次） |
| v6.12_formulation | 四个开关全关 | v6.12 写法比修正后多算了多少利润 |
| F1_off_Q_lo=0.97 | 只把计划响应放回 97% | 满额要求的代价（F1） |
| F2_off_one_hour_slack | 只用旧的可限功率判据 | 跨小时补做截止检查的代价（F2）；看 `min_deadline_slack_after_makeup_h` 是否变负 |
| F3_off_increments_only | 电池只限增量、无模式、无空载损耗 | 可执行设定值的代价（F3）；看 `bess_setpoints_below_min` 和 `bess_charging_blocks_with_extra_discharge` |
| F3_modes_without_fixed_loss | 有模式和最小功率，不计空载损耗 | 空载损耗单独的影响 |
| ride=4.0min_v6.12_formulation | v6.12 写法 + 后备 4 min | 与 E4 ride=4.0min 对比：后备最紧时修正的影响（审稿要求看 4.0 min） |

读结果时：

- 比较不同 case 的利润时看 f^FFR（已扣除不参与 FFR 时也能拿到的迁移、套利收益）；改变 C0 的组（E4、E13–E15、E17）同时看 C0。
- BESS / IT / 发电机的分担看 `event_share_*`（整个事件）和 `sustain_share_*`（只看 sustain 段）。
- BESS / IT / 发电机的分担由"精修"步骤给出（gap 0.01 USD），不受第一步 gap 的影响；利润的比较仍以约 0.1% 的 gap 为误差。
- 看 IT：`event_share_IT`（目标 10–20%）、`IT_at_work_limit_share`（IT 受可放慢工作量限制的比例）、`IT_at_QoS_cap_share`（受 M^QoS 限制，应接近 0）、`migrated_share_training`。
- 要换基准价格，设 `FFR_RRS`（例如 aug2023_level），并另设 `FFR_EXP_OUTPUT` 到别的文件夹。
- v6.13 新增的检查量：`min_response_ratio`（应 ≥ 1）、`min_deadline_slack_after_makeup_h`（应 ≥ 0）、`bess_setpoints_below_min` 和 `bess_charging_blocks_with_extra_discharge`（应为 0）、`absorbed_training_backlog_units_per_year`（训练积压）、`bess_min_backup_margin_MWh`、`gap_rel_FFR_first_solve`、`n_binary_FFR`。在 v6.12_formulation 里这些量可能违反，这正是 E19 要展示的。
