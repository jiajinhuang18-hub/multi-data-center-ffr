# PDF v6.13 ↔ 代码

| PDF | 内容 | 代码（`ffr_model_v613.jl`） | 约束名 |
|---|---|---|---|
| (1) | 每单位灵活工作恰好分配一次 | `x` | `eq1` |
| (2) | 处理能力，W^max = U^max × K（推理站保留空闲） | `l <= Wmax*Thr` | `eq2` |
| (3) | 利用率与服务器功率曲线（二次等式） | `u`, `pIT` | `eq3_util`, `eq3` |
| (4) | 站点功率平衡 | `pgrid` | `eq4` |
| (5) | UPS 只供关键 IT | | `eq5` |
| (6) | IT 功率小时间爬坡；v6.13b：`ramp_cyclic = true` 时第 24→1 小时也限制 | | `eq6_up`, `eq6_down`, `eq6_cyc_up`, `eq6_cyc_down` |
| (7)(8) | WAN 数据到达和链路容量（TB） | `v` | `eq7`, `eq8` |
| (9) | BESS 功率范围和模式 | `pch`, `pdis`, `zch`, `zdis` | `eq9_*` |
| (10) | 逆变器损耗（二次等式） | `qch`, `qdis` | `eq10_ch`, `eq10_dis` |
| (11) | 储能 | `e` | `eq11*` |
| (12) | BESS 事件功率：两小时包络、段首段末、UPS 上限；非 loading 段首末相等；v6.13：充电块只减充且 ≥ P^ch,min，加放电的块处于放电模式且 ≥ P^dis,min，充电块不加放电，X_B = 0 的段增量为 0 | `rch0`, `rdis0`（段首）、`rch1`, `rdis1`（loading 段段末）；访问函数 `rch(d,b,t,s,k)`；模式二元变量 `ydis[d,b,t,s]` | `eq12_ch`, `eq12_dis`, `eq12_on`, `eq12_dismin`, `eq12_mode`, `eq12_ups` |
| (13) | 事件能量 e^draw, e^dev（段内平均）；v6.13：e^draw 加上开机段的空载损耗 P^fix·y·T_s | `edraw`, `edev`, `efix`, `q.Pfix` | 表达式 |
| (14) | 后备下限，K_t 三个点 | | `eq14` |
| (15) | 恢复后可应付第二次事件 | | `eq15` |
| l^elig 定义 | 可限功率的工作：训练（J^abs）全部；其他类 t + 1 + T^mk ≤ t' + T^dly（v6.13，F2） | `q.elig`（`ffr_params.jl`，`b[:elig_cross_hour]`） | — |
| (16) | 各类 IT 限功率 ≤ A_{j,s} × S × 第 j 类可限工作 l^elig_{d,t,j}；合计 ≤ M^QoS | `rITj[d,t,s,j]`, `rIT`（合计）, `lelig`, `q.Acls` | `eq16`, `eq16_qos` |
| (17) | 补做：不属于 J^abs 的类别在窗口 T^mk_j 内的空闲容量（可用推理站保留的空闲，K^mk = K；24 点以后取当天对应小时）；训练类（J^abs）不需要补做容量 | `cmk[d,t,j]`, `q.T_mk`, `q.cap_mk`, `q.absorb` | `eq17` |
| (18) | 发电机物理轨迹，Y^0_s、Y^1_s | `q.Y0`, `q.Y1`（`ffr_params.jl`） | — |
| (19) | 持续出力、最小负载、爬坡速率 | `n`, `pG` | `eq19_min`, `eq19_max`, `eq19_rate` |
| (20) | 最小运行时间和冷却 | `q.T_G_ext`, `q.T_G_tot` | — |
| (21) | 事件后最小负载运行不倒送 | | `eq21` |
| (22) | 两端都检查带宽上下限和不倒送 | `rtot(d,t,s,k)` | `eq22_lo`, `eq22_hi`, `eq22_noexp` |
| 9.1 节 | 满额和设计上限：Q^lo = 1（v6.13），Q^hi = 1.05/1.10 − M^band | `q.Qlo`（`b[:Q_lo_target]`）, `q.Qhi` | — |
| (23) | 报价上限（站点份额、机群） | `rffr` | `eq23_share`, `eq23_fleet` |
| (24) | 最低承诺（只在 R_req > 0 时） | | `eq24` |
| (25) | 年运行小时 | | `eq25` |
| (26) | 日前成本 | `C_DA` | 表达式 |
| (27) | 事件成本（C^{E,ev}, C^{E,mk}, T^{G,eq}） | `Cev_B`, `Cev_IT`, `Cev_G`, `Cev_credit`, `Cev` | 表达式 |
| (28)(29) | 目标；目标里加常数 C0，求解器直接报告 f^FFR | `Rev - C_DA - ECev + C0` | — |
| 附录 A | 派生参数 | `ffr_params.jl: derive_params` | — |
| 附录 B | v6.12 写法对照 | `apply_v612_formulation!(b)`；`bess_event_modes = false` 时 `fixed_event_loss = true` 为 v6.12 的整段固定损耗 `q.Efix` | — |
| 附录 B | 两步求解：固定日前计划和报价，精修事件分担 | `ffr_case.jl: polish_event_split` | — |
| 附录 A | 站点角色和负载组成 | `ffr_params.jl`（`workload_mode = "site_roles"`） | — |

下标说明：`k = 0` 段首，`k = 1` 段末；`θ ∈ W(t) = (t, t+1)`（24 的下一小时是 1）；`ϑ ∈ (t, t+1, t+2)`，储能下标超过 25 时周期回到当天开头。
