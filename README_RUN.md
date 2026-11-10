# 运行说明（模型 v6.13 + benchmark v6.13）

## v6.13b：24 点到 1 点的爬坡（第二轮审稿 4.3）

新增开关 `b[:ramp_cyclic] = true`（`benchmark/benchmark_params.jl`）：IT 功率爬坡限制也作用于第 24 小时到第 1 小时（代表日循环，和事件、补做的循环下标一致）。约束名 `eq6_cyc_up[DCx]`、`eq6_cyc_down[DCx]`。`kpi.csv` 新增 `IT_ramp_24_to_1_MW_DCx` 和 `IT_ramp_24_to_1_over_limit_DCx`（≤ 1 表示满足）。设为 `false` 即回到 v6.13（旧结果中 DC2 为 45.3 MW，超过 37.5 MW 的上限）。

这个开关会改变不参加 FFR 时的成本 C0，所以**所有 case 都要重跑**，并用新的输出文件夹：

```
$env:FFR_EXP_OUTPUT = "experiments/results_v613b"
Remove-Item Env:FFR_EXPERIMENTS -ErrorAction SilentlyContinue
$env:FFR_POLISH_GAP_ABS = "10"
julia --project=. experiments/run_experiments.jl
```

## v6.13 改了什么（审稿意见 F1–F3）

| 编号 | 改动 | 开关（`benchmark/benchmark_params.jl`） |
|---|---|---|
| F1 | 计划响应 = 100% 中标量（`Q_lo = 1.00`），不再是 97%；`M_band` 只留在上限一侧（103% / 108%） | `b[:Q_lo_target] = 1.00` |
| F2 | 可限功率的工作必须在"事件延续到下一小时"时补做窗口也不超过原截止时间：`t + 1 + T_mk ≤ t' + T_dly`；训练"延后完成"写成明确假设，并报告积压量 | `b[:elig_cross_hour] = true` |
| F3 | 事件中电池块的设定值可执行：充电块只能减少充电且不低于 P^ch,min；加放电的块必须处于放电模式且不低于 P^dis,min（每个块每段一个二元变量 `ydis`）；X_B = 0 的段增量固定为 0 | `b[:bess_event_modes] = true` |
| F3 | 事件中开机块的空载损耗 L0·P_inv 计入储能消耗（默认开） | `b[:fixed_event_loss] = true` |

`apply_v612_formulation!(b)` 一次把四个开关都关掉，得到 v6.12 的写法（用于对照，实验 E19）。

**注意求解时间：** F3 给事件部分加了 4,320 个二元变量（30 块 × 24 h × 6 段）。v6.8 曾经因为事件二元变量太多而去掉过它们，所以 v6.13 可能比 v6.12 慢。建议先单独跑 base case 看日志里 gap 的收敛，再跑整套实验。如果 polish 步骤太慢，可以设 `FFR_POLISH=false`。



## 文件

| 文件 | 内容 |
|---|---|
| `benchmark/benchmark_params.jl` | **所有 benchmark 参数都在这里**，按模块分组，每个参数都有单位和说明，直接改数字即可 |
| `benchmark/profiles/*.csv` | 24 小时曲线：负载（固定、灵活）、电价、RRS 价格情景，可以用 Excel 打开修改 |
| `main.jl` | 跑 base case（先 no-FFR 得到 C0，再跑 FFR 模型），输出到 `results/base/` |
| `experiments/run_experiments.jl` | 实验 E1–E19，输出到 `experiments/results/` |
| `experiments/plot_experiments.py` | 根据 `summary.csv` 画图 |
| `ffr_model_v613.jl` | 模型本体，约束名 `eq1`…`eq25` 与 PDF v6.13 公式编号一致 |
| `ffr_params.jl` | 附录 A：由 benchmark 输入计算所有派生参数（每次运行开头都会打印） |
| `ffr_case.jl` | 一个 case = no-FFR（C0）+ FFR 模型 + 事件分担精修（polish），C0 自动复用 |
| `ffr_solver.jl` | Gurobi 设置（**默认不限时间**） |
| `ffr_report.jl` | KPI、CSV、逐条约束检查 |
| `tests/build_check.jl` | 只建模型、不求解：改完参数后快速检查数据条件和模型能否建立 |
| `tests/code_test_highs.jl` | 线性替代模型 + HiGHS，只检查代码能跑，**不是结果** |
| `MODEL_MAPPING.md` | PDF 公式 ↔ 代码 |
| `EXPERIMENT_DESIGN.md` | 实验设计 |
| `BENCHMARK.md` | benchmark 取值和理由 |

## 第一次运行（VS Code）

1. 解压后用 VS Code 打开文件夹（File → Open Folder，选 `day_ahead_ffr_julia_project_v613`），打开终端（Terminal → New Terminal）。
2. 安装依赖（只需一次）：
   ```
   julia --project=. -e "import Pkg; Pkg.instantiate()"
   ```
3. Gurobi：用你现在的学术 license 即可（v6.5 能跑通的环境不需要再做任何设置）。

## 重要：确认没有时间上限

代码默认**不设** Gurobi 时间上限。之前跑 v6.5 时如果在终端里设过 `FFR_TIME_LIMIT`（例如 300 秒），它在同一个终端窗口里仍然有效。先删掉：

```
Remove-Item Env:FFR_TIME_LIMIT -ErrorAction SilentlyContinue      # PowerShell
unset FFR_TIME_LIMIT                                               # macOS / Linux
```

或者直接关掉旧终端，开一个新的。运行开头会打印 `time limit: Inf s`，看到 `Inf` 就说明没有上限。

## 跑 base case

```
julia --project=. tests/build_check.jl     # 可选：几十秒，检查参数和模型能建立
julia --project=. main.jl                  # base case
```

终端会先打印派生参数（各站的角色、每小时工作量和利用率、BESS 可用电量、发电机容量、各阶段时长等），然后是三段日志：

1. `no-FFR model (C0)`：最小化 c^DA。
2. `FFR model`：目标值**直接就是 f^FFR**（代码把常数 C0 加进了目标函数，与式 29 等价）。停止条件：相对 gap 1e-3 **或**绝对 gap 100 USD，满足任一个即停。
3. `polish`：把第 2 步得到的日前计划和报价固定住，只重新优化事件中 BESS / IT / 发电机的分担，绝对 gap 1 USD（`FFR_POLISH_GAP_ABS`，v6.12 为 0.01），通常几秒到几十秒。
   原因：期望事件成本每天只有几百美元，比第 2 步的 gap（几千美元）还小，所以第 2 步停下时分担方式不一定是最优的；精修后的分担才可信。利润只会增加，不会减少。
   不想要这一步：`$env:FFR_POLISH = "false"`。

结果在 `results/base/`：

| 文件 | 内容 |
|---|---|
| `kpi.csv` | v6.13 新增：`min_response_ratio`（≥ 1 表示每个阶段端点都交付满额）、`min_full_award_margin_MW`、`min_deadline_slack_after_makeup_h`（≥ 0 表示补做不超截止时间）、`makeup_max_window_utilization`、`absorbed_training_backlog_units_per_year`、`bess_sched_charge/discharge_block_hours`、`bess_soc_min/max`、`bess_setpoints_below_min` 和 `bess_charging_blocks_with_extra_discharge`（v6.13 应为 0）、`bess_min_backup_margin_MWh`、`bess_fixed_loss_MWh_all_events`、`gap_rel_FFR_first_solve`、`n_binary_FFR`；原有：f^FFR、C0、容量收入、ΔC^DA、期望事件成本、整个事件和 sustain 段中 BESS / IT / 发电机的能量占比、IT 受哪条上限约束（`IT_at_QoS_cap_share`、`IT_at_work_limit_share`）、各类任务的迁移比例、期望年启动次数等 |
| `hourly_site.csv` | 每站每小时（新增 `min_response_ratio`）：负载、P_IT、P_grid、r^FFR、每个事件阶段 BESS / IT / 发电机的平均出力和段首段末的总响应、发电机台数 |
| `bess_blocks.csv` | 每个电池块每小时：充放电、损耗、储能、e^draw（含空载损耗）、e^dev、空载损耗 `e_fixed_loss`、开机段数 `stages_on`、式 14/15 的余量 |
| `workload_assignments.csv` | 所有 x > 0 的分配（从哪来、到哪去、推迟几小时） |
| `wan_link_hours.csv` | 每条链路每小时传了多少数据（TB）和利用率 |
| `event_cost_hourly.csv` | 每小时 what-if 事件的成本构成和容量收入 |
| `constraint_check.txt` | 每一族约束的最大违反量、两条二次等式的残差、数据条件 |

## 可选的环境变量（PowerShell 写法；bash 用 `export 名字=值`）

```
$env:FFR_RRS          = "aug2023_level"   # RRS 价格换一列：cap_peak_5000（默认）/ aug2023_level / jun2026_actual / record_peak_25000
$env:FFR_WORKLOAD     = "homogeneous"     # 用 v6.9 的同质负载（对照）；默认 site_roles
$env:FFR_MIP_GAP      = "1e-3"            # 相对 gap（默认 1e-3）
$env:FFR_MIP_GAP_ABS  = "100"             # 绝对 gap [USD]（默认 100）
$env:FFR_POLISH       = "true"            # 事件分担精修（默认开）
$env:FFR_THREADS      = "16"              # 线程数，默认用全部核
$env:FFR_LOG_DIR      = "logs"            # 保存每次求解的 Gurobi 日志
$env:FFR_GRB_PARAMS   = "MIPFocus=3"      # 其他 Gurobi 参数
$env:FFR_GEN_TAKEOVER = "true"            # 对比：发电机承担整个 sustain 段
```

不要设 `FFR_TIME_LIMIT`。之前在终端里设过的 `FFR_MIP_GAP`、`FFR_MIP_GAP_ABS` 会覆盖新的默认值，新开一个终端最省事。

## 跑实验

```
julia --project=. experiments/run_experiments.jl                 # 全部
$env:FFR_EXPERIMENTS = "E1,E19"                                   # 只跑部分组
julia --project=. experiments/run_experiments.jl
python experiments/plot_experiments.py                            # 画图（需要 pandas、matplotlib）
```

- 每跑完一个 case，就追加一行到 `experiments/results/summary.csv`；中断后重跑会跳过已完成的 case（删掉 summary.csv 就全部重跑）。
- 只改 FFR 一侧参数的 case 复用同一个 C0，只需要解 FFR 模型。
- 多个组里输入完全相同的 case（比如 base case）只解一次。
- 每个 case 的详细输出在 `experiments/results/cases/<case>/`。
- 不限时间时整套实验会跑很久。建议先跑 base case，看日志里 gap 的收敛速度，再决定跑哪些组。

## 改 benchmark

1. 打开 `benchmark/benchmark_params.jl`，改数字，保存。每个参数旁边写了单位、对应 PDF 里的符号和含义。
2. 小时曲线在 `benchmark/profiles/` 的 CSV 里（第一列是小时 1–24，其余每列一个站点或一个价格情景）。可以在 Excel 里改，存回 CSV 格式。要加一个新的 RRS 价格情景，就在 `rrs_price.csv` 里加一列，然后把 `b[:rrs_scenario]` 改成这一列的列名。
3. 跑 `tests/build_check.jl`，看打印出来的派生参数和数据条件（全部 OK）是否符合预期。
4. 派生值（电池块大小、能量下限、事件效率、S_d、M^mk、发电机成本、阶段时长、Y^0/Y^1、带宽等）都在 `ffr_params.jl` 里按 PDF 附录 A 的公式计算，不需要手改。

## 已知的模型行为（读结果时注意）

0. **补做规则（v6.11–v6.13）。** v6.13：批处理只有在"事件延续到下一小时"时补做窗口仍在原截止时间之前才能被限功率（F2）。 训练任务被放慢后不在当天补做，而是让作业晚一点完成（`b[:makeup_absorb]`，补做电费按当天平均电价计入）；批处理在 1 h 窗口内补完（`b[:T_mk]`），补做可以借用推理站保留的空闲容量（`b[:makeup_uses_reserve]`）。跨午夜的补做容量按"典型日"取当天对应小时的值。训练的放慢比例 0.20 / 0.15（0–60 s / 持续段）。
1. **站点分工（v6.10 新增）。** DC1 是 AI 训练园区（全天约 97% 利用率，几乎没有空闲）；DC2 是推理/云服务站（峰值 55%，必须保留 20% 空闲）；DC3 是混合云（峰值 60%，保留 15%）。训练放慢后由作业延后完成吸收，批处理要在补做窗口内用空闲算力补做（式 17）。E18 比较同质负载、不能迁移、不同的可延迟时间和放慢比例。
2. **IT 占比的目标范围是 10–20%。** 看 `kpi.csv` 的 `event_share_IT`。`IT_at_work_limit_share` 高说明 IT 受"可放慢的工作量"限制；`IT_at_QoS_cap_share` 高说明受 M^QoS 限制（应该接近 0）；`IT_zero_share` 是 IT 出力为 0 的比例（通常因为补做窗口内没有空闲算力）；`event_IT_MWh_<站点>`、`event_IT_MWh_<类别>` 给出 IT 出力在哪里、来自哪类任务。
3. **BESS 只承担开头一分钟左右。** UPS 保留 3 分钟后备，下限以上只剩约 1.1 分钟的电量（`ride_min` 可改）。
4. **RRS 价格默认峰值 5,000 USD/MW-h**（现行辅助服务报价上限），日均约 875。利润仍主要来自容量收入。
5. **能量价格还是占位曲线**（`energy_price.csv`），不是 ERCOT 实际数据。
6. **v6.13 的响应是满额。** v6.12 计划 97%，v6.13 计划 100%，所以同样的资源能卖的 FFR 少约 3%，利润相应下降；E19 给出每项修改单独的影响。
7. **电池在日前计划里待机是正常结果。** 71 个 v6.12 case 中所有块的 p_ch = p_dis = 0（SOC 一直在 95%）。`bess_sched_*_block_hours` 用来确认 v6.13 是否仍然如此。
