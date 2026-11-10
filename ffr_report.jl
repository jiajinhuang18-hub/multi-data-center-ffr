# ============================================================
# Results: KPIs, CSV tables and a constraint check of every equation family (model v6.13).
# ============================================================

using DataFrames, CSV, Printf

"""
Average power of BESS, IT and generators in every stage of the what-if event of (d,t) [MW],
and the start/end values of the total response.
"""
function stage_split(res, d, t)
    q, r = res.q, res.mf.refs
    a = r.acc
    bess = [sum(q.XB[s] * (value(a.rch(d, b, t, s, 0)) + value(a.rch(d, b, t, s, 1)) +
                           value(a.rdis(d, b, t, s, 0)) + value(a.rdis(d, b, t, s, 1))) / 2 for b in r.Bd[d]) for s in q.S]
    it = [value(r.rIT[d, t, s]) for s in q.S]
    gen = [0.5 * (q.Y0[s] + q.Y1[s]) * value(r.pG[d, t]) for s in q.S]
    tot0 = [value(a.rtot(d, t, s, 0)) for s in q.S]
    tot1 = [value(a.rtot(d, t, s, 1)) for s in q.S]
    return bess, it, gen, tot0, tot1
end

function kpis(res)
    q, mf, m0 = res.q, res.mf, res.m0
    m = mf.model; r = mf.refs
    k = Dict{String,Any}()
    k["case"] = res.label
    k["status_noFFR"] = string(termination_status(m0.model))
    k["status_FFR"] = string(termination_status(m))
    k["C0_USD"] = res.C0; k["C0_bound_USD"] = res.C0_bound
    k["time_noFFR_s"] = res.t0; k["time_FFR_s"] = res.tf; k["C0_from_cache"] = res.from_cache
    k["time_polish_s"] = get(res, :tp, 0.0); k["polished"] = get(res, :polished, false)
    k["workload_mode"] = q.workload_mode
    k["rrs_scenario"] = q.rrs_scenario; k["rrs_avg_USD_MWh"] = mean(q.CRRS)
    k["R_req_MW"] = q.R_req; k["R_mkt_MW"] = q.R_mkt
    k["N_FFR"] = join(q.N_FFR, "/"); k["U_share"] = join(q.U, "/")
    k["inv_loss_mode"] = string(mf.opts.inv_loss); k["gen_takeover"] = mf.opts.gen_takeover
    has_values(m) || return k
    k["f_FFR_USD"] = objective_value(m)
    k["f_FFR_bound_USD"] = get(res, :f_bound, _bound(m))          # bound of the first FFR solve
    k["f_FFR_before_polish_USD"] = get(res, :f_stage1, objective_value(m))
    k["capacity_revenue_USD"] = value(m[:Rev])
    k["C_DA_USD"] = value(m[:C_DA])
    k["delta_C_DA_USD"] = value(m[:C_DA]) - res.C0
    k["expected_event_cost_USD"] = value(m[:ECev])
    k["E_event_BESS_USD"] = sum(q.pact[t] * value(m[:Cev_B][t]) for t in q.Tset)
    k["E_event_IT_USD"] = sum(q.pact[t] * value(m[:Cev_IT][t]) for t in q.Tset)
    k["E_event_GEN_USD"] = sum(q.pact[t] * value(m[:Cev_G][t]) for t in q.Tset)
    k["E_event_credit_USD"] = sum(q.pact[t] * value(m[:Cev_credit][t]) for t in q.Tset)
    k["ffr_MW_h"] = sum(value(r.rffr[d, t]) for d in q.D, t in q.Tset)
    for d in q.D
        k["ffr_MW_h_$(q.site_names[d])"] = sum(value(r.rffr[d, t]) for t in q.Tset)
    end
    k["hours_with_ffr"] = count(t -> sum(value(r.rffr[d, t]) for d in q.D) > 1e-4, q.Tset)
    k["max_fleet_ffr_MW"] = maximum(sum(value(r.rffr[d, t]) for d in q.D) for t in q.Tset)
    # energy delivered in the what-if events of all hours: whole event and sustain stage
    eB = eI = eG = 0.0; sB = sI = sG = 0.0
    for d in q.D, t in q.Tset
        bess, it, gen, _, _ = stage_split(res, d, t)
        eB += sum(bess .* q.Ts); eI += sum(it .* q.Ts); eG += sum(gen .* q.Ts)
        ss = q.s_sus
        sB += bess[ss] * q.Ts[ss]; sI += it[ss] * q.Ts[ss]; sG += gen[ss] * q.Ts[ss]
    end
    tot = eB + eI + eG; stot = sB + sI + sG
    k["event_BESS_MWh"] = eB; k["event_IT_MWh"] = eI; k["event_GEN_MWh"] = eG
    k["event_share_BESS"] = tot > 0 ? eB / tot : 0.0
    k["event_share_IT"] = tot > 0 ? eI / tot : 0.0
    k["event_share_GEN"] = tot > 0 ? eG / tot : 0.0
    k["sustain_share_BESS"] = stot > 0 ? sB / stot : 0.0
    k["sustain_share_IT"] = stot > 0 ? sI / stot : 0.0
    k["sustain_share_GEN"] = stot > 0 ? sG / stot : 0.0
    k["bess_energy_above_floor_MWh"] = sum(q.nB[d] * (q.E0[d] - q.Emin[d]) for d in q.D)
    k["gen_units_planned_sum_over_hours"] = sum(round(value(r.n[d, t])) for d in q.D, t in q.Tset)
    k["gen_expected_starts_per_year"] = 365 * sum(q.pact[t] * round(value(r.n[d, t])) for d in q.D, t in q.Tset)
    for d in q.D
        k["gen_expected_hours_per_unit_year_$(q.site_names[d])"] = q.N_FFR[d] > 0 ?
            365 * sum(q.pact[t] * q.T_G_tot * value(r.n[d, t]) for t in q.Tset) / q.N_FFR[d] : 0.0
    end
    flexsum = sum(q.Wflex)
    k["migrated_share"] = flexsum > 0 ? sum(value(r.x[i]) for i in r.mig; init=0.0) / flexsum : 0.0
    for j in q.J
        fj = sum(q.Wflex[:, :, j])
        k["migrated_share_$(q.class_names[j])"] = fj > 0 ? sum(value(r.x[i]) for i in r.mig if q.A[i].j == j; init=0.0) / fj : 0.0
    end
    # IT capping: how often each limit of Eqs. 16-17 is reached (site, hour, stage with X_IT = 1)
    nIT = 0; atQoS = 0; atWork = 0
    for d in q.D, t in q.Tset, s in q.S
        q.XIT[s] > 0 || continue
        nIT += 1
        rv = value(r.rIT[d, t, s])
        wl = sum(minimum(q.XIT[s] * q.Sd[d] * q.Acls[j][s] * value(r.lelig[d, θ, j]) / q.Thr for θ in (t, mod1(t + 1, q.T))) for j in q.J)
        rv >= q.MQoS[d] - 1e-4 && (atQoS += 1)
        (rv >= wl - 1e-4 && wl > 1e-6) && (atWork += 1)
    end
    for j in q.J
        k["event_IT_MWh_$(q.class_names[j])"] = sum(value(r.rITj[d, t, s, j]) * q.Ts[s] for d in q.D, t in q.Tset, s in q.S)
    end
    for d in q.D
        k["event_IT_MWh_$(q.site_names[d])"] = sum(value(r.rIT[d, t, s]) * q.Ts[s] for t in q.Tset, s in q.S)
    end
    k["IT_at_QoS_cap_share"] = nIT > 0 ? atQoS / nIT : 0.0        # M^QoS reached
    k["IT_at_work_limit_share"] = nIT > 0 ? atWork / nIT : 0.0     # A_j,s x eligible work reached (Eq. 16)
    nZero = count(q.XIT[s] > 0 && value(r.rIT[d, t, s]) < 1e-4 for d in q.D, t in q.Tset, s in q.S)
    k["IT_zero_share"] = nIT > 0 ? nZero / nIT : 0.0
    k["avg_delay_h"] = flexsum > 0 ? sum((q.A[i].t - q.A[i].tp) * value(r.x[i]) for i in eachindex(q.A)) / flexsum : 0.0
    k["wan_max_util"] = wan_max_util(res.mf)
    k["energy_cost_USD"] = value(m[:C_energy]); k["migration_cost_USD"] = value(m[:C_mig]); k["delay_cost_USD"] = value(m[:C_dly])
    k["net_cost_USD"] = value(m[:C_DA]) + value(m[:ECev]) - value(m[:Rev])
    k["max_IT_ramp_MW"] = maximum(abs(value(r.pIT[d, t]) - value(r.pIT[d, mod1(t - 1, q.T)]))
                                  for d in q.D, t in (q.ramp_cyclic ? (1:q.T) : (2:q.T)))
    k["ramp_cyclic"] = q.ramp_cyclic
    for d in q.D   # hour 24 -> hour 1 change and its share of the ramp limit (reported in both settings)
        dp = value(r.pIT[d, 1]) - value(r.pIT[d, q.T])
        k["IT_ramp_24_to_1_MW_$(q.site_names[d])"] = dp
        k["IT_ramp_24_to_1_over_limit_$(q.site_names[d])"] = isfinite(q.ramp[d]) ? abs(dp) / q.ramp[d] : 0.0
    end
    merge!(k, repair_kpis(res))
    return k
end

"Smallest planned response / award over the stage ends of hour t at site d (NaN without an award)."
function response_ratio(res, d, t)
    q, r = res.q, res.mf.refs
    rf = value(r.rffr[d, t]); rf > 1e-4 || return NaN
    return minimum(value(r.acc.rtot(d, t, s, kk)) for s in q.S, kk in (0, 1) if kk == 0 || s in q.SL) / rf
end

"Event setpoint check of every block, stage end and hour of the envelope (F3)."
function bess_setpoint_check(res; tol=1e-3)   # MW; smaller values are solver tolerance
    q, r = res.q, res.mf.refs
    a = r.acc
    n_dead = 0; n_mixed = 0; pmin_pos = Inf
    for d in q.D, b in r.Bd[d], t in q.Tset, s in q.S, kk in (0, 1), θ in (t, mod1(t + 1, q.T))
        (kk == 1 && !(s in q.SL)) && continue
        rc, rd = value(a.rch(d, b, t, s, kk)), value(a.rdis(d, b, t, s, kk))
        pc, pd = value(r.pch[d, b, θ]), value(r.pdis[d, b, θ])
        dis = pd + rd; chg = pc - rc
        (rd > tol && pc > tol) && (n_mixed += 1)                       # charging block asked for extra discharge
        (tol < dis < q.Pdis_min[d] - tol) && (n_dead += 1)            # discharge setpoint below the minimum
        (tol < chg < q.Pch_min[d] - tol) && (n_dead += 1)             # charge setpoint below the minimum
        rd > tol && (pmin_pos = min(pmin_pos, dis))
    end
    return n_dead, n_mixed, pmin_pos
end

"KPIs of the v6.13 repairs F1-F3 and solver/model size (F9)."
function repair_kpis(res)
    q, mf = res.q, res.mf; m = mf.model; r = mf.refs
    k = Dict{String,Any}()
    k["Q_lo"] = q.Qlo[1]; k["elig_cross_hour"] = q.elig_cross; k["bess_event_modes"] = q.bess_modes
    k["fixed_event_loss"] = q.fixed_loss
    # ---- F1: planned response vs award
    ratios = [response_ratio(res, d, t) for d in q.D, t in q.Tset]
    ok = filter(!isnan, vec(ratios))
    k["min_response_ratio"] = isempty(ok) ? NaN : minimum(ok)
    k["max_response_ratio"] = isempty(ok) ? NaN : maximum(ok)
    margins = [value(r.acc.rtot(d, t, s, kk)) - value(r.rffr[d, t]) for d in q.D, t in q.Tset, s in q.S, kk in (0, 1)
               if (kk == 0 || s in q.SL) && value(r.rffr[d, t]) > 1e-4]
    k["min_full_award_margin_MW"] = isempty(margins) ? NaN : minimum(margins)
    # ---- F2: deadline slack of capped work that is made up; training slowed (absorbed) work
    slack = Inf
    for (i, a) in enumerate(q.A)
        (q.elig[i] && !q.absorb[a.j] && value(r.x[i]) > 1e-6) || continue
        capped = any(value(r.cmk[a.d, tt, a.j]) > 1e-6 for tt in (a.t, mod1(a.t - 1, q.T)))
        capped || continue
        slack = min(slack, a.tp + q.T_dly[a.j] - (a.t + 1 + q.T_mk[a.j]))   # >= 0: made up before the deadline
    end
    k["min_deadline_slack_after_makeup_h"] = isfinite(slack) ? slack : NaN
    util = 0.0
    for d in q.D, t in q.Tset, (pos, kc) in enumerate(q.mk_order), δ in (0, 1)
        lhs = sum(value(r.cmk[d, t, j]) for j in q.mk_order[1:pos])
        rhs = sum(q.cap_mk[d] * q.Thr - value(r.l[d, mod1(h, q.T)]) for h in (t + 1 + δ):(t + δ + q.T_mk[kc]))
        lhs > 1e-4 && (util = max(util, rhs > 1e-4 ? lhs / rhs : Inf))   # ignore solver noise (units of work)
    end
    k["makeup_max_window_utilization"] = util
    for j in q.J
        q.absorb[j] || continue
        nm = q.class_names[j]
        k["absorbed_$(nm)_slowed_units_max_event"] = maximum(sum(value(r.cmk[d, t, j]) for d in q.D) for t in q.Tset)
        k["absorbed_$(nm)_backlog_units_per_year"] = 365 * sum(q.pact[t] * value(r.cmk[d, t, j]) for d in q.D, t in q.Tset)
        k["absorbed_$(nm)_backlog_share_of_daily_work"] = sum(q.Wflex[:, :, j]) > 0 ?
            maximum(sum(value(r.cmk[d, t, j]) for d in q.D) for t in q.Tset) / sum(q.Wflex[:, :, j]) : 0.0
    end
    # ---- F3: schedule, SOC, executable setpoints, fixed loss
    k["bess_sched_charge_block_hours"] = count(value(r.zch[d, b, t]) > 0.5 for d in q.D for b in r.Bd[d] for t in q.Tset)
    k["bess_sched_discharge_block_hours"] = count(value(r.zdis[d, b, t]) > 0.5 for d in q.D for b in r.Bd[d] for t in q.Tset)
    socs = [value(r.e[d, b, t]) / q.Ecap[d] for d in q.D for b in r.Bd[d] for t in 1:(q.T + 1)]
    k["bess_soc_min"] = minimum(socs); k["bess_soc_max"] = maximum(socs)
    n_dead, n_mixed, pmin_pos = bess_setpoint_check(res)
    k["bess_setpoints_below_min"] = n_dead
    k["bess_charging_blocks_with_extra_discharge"] = n_mixed
    k["bess_min_positive_event_discharge_MW"] = isfinite(pmin_pos) ? pmin_pos : NaN
    soc_marg = Inf
    for d in q.D, b in r.Bd[d], t in q.Tset
        emin = minimum(value(r.e[d, b, kk <= q.T + 1 ? kk : kk - q.T]) for kk in (t, t + 1, t + 2))
        soc_marg = min(soc_marg, emin - q.Emin[d] - q.Efix[d] - value(r.edraw[d, b, t]))
    end
    k["bess_min_backup_margin_MWh"] = soc_marg
    k["bess_fixed_loss_MWh_all_events"] = sum(value(r.efix[d, b, t]) for d in q.D for b in r.Bd[d] for t in q.Tset) +
                                          sum(q.Efix[d] * q.nB[d] * q.T for d in q.D)
    if r.ydis !== nothing
        k["bess_block_stages_on"] = count(value(r.ydis[d, b, t, s]) > 0.5 for d in q.D for b in r.Bd[d] for t in q.Tset for s in q.S)
        k["bess_max_blocks_on_per_site"] = maximum(count(value(r.ydis[d, b, t, s]) > 0.5 for b in r.Bd[d]) for d in q.D, t in q.Tset, s in q.S)
    end
    # ---- F9: gap of the first FFR solve and model size
    f1, fb = get(res, :f_stage1, NaN), get(res, :f_bound, NaN)
    k["gap_rel_FFR_first_solve"] = (isfinite(f1) && isfinite(fb)) ? abs(fb - f1) / max(abs(f1), 1e-9) : NaN
    k["n_variables_FFR"] = num_variables(m)
    k["n_binary_FFR"] = count(is_binary, all_variables(m))
    k["n_integer_FFR"] = count(is_integer, all_variables(m))
    k["n_constraints_FFR"] = num_constraints(m; count_variable_in_set_constraints=false)
    return k
end

function wan_max_util(mm)
    q, r = mm.q, mm.refs
    isempty(r.v) && return 0.0
    used = Dict((lk, h) => 0.0 for lk in q.links, h in q.Tset)
    for ((k, h), var) in r.v
        used[((q.A[k].dp, q.A[k].d), h)] += value(var)
    end
    return maximum(used[(lk, h)] / q.link_cap[lk] for lk in q.links, h in q.Tset)
end

"Group the primal violations of all constraints by equation family (eq1, eq3, eq12_ups, ...)."
function constraint_check(mm; atol=1e-6)
    m = mm.model
    rep = primal_feasibility_report(m; atol=atol, skip_missing=true)
    worst = Dict{String,Float64}()
    for (c, viol) in rep
        nm = name(c)
        fam = isempty(nm) ? "variable bounds / integrality" : String(split(nm, '[')[1])
        worst[fam] = max(get(worst, fam, 0.0), viol)
    end
    fams = Set{String}()
    for (F, Sset) in list_of_constraint_types(m), c in all_constraints(m, F, Sset)
        nm = name(c); isempty(nm) && continue
        push!(fams, String(split(nm, '[')[1]))
    end
    return worst, sort(collect(fams))
end

"Residuals of the two quadratic equalities (server curve, inverter loss)."
function nonlinear_residuals(mm)
    q, r = mm.q, mm.refs
    srv = maximum(abs(value(r.pIT[d, t]) - q.Pmax[d] * (q.G0 + q.G1 * value(r.u[d, t]) + q.G2 * value(r.u[d, t])^2)) for d in q.D, t in q.Tset)
    f(d, p, z) = q.Pinv[d] * q.L0[d] * z + q.L1[d] * p + q.L2[d] / q.Pinv[d] * p^2
    inv = 0.0
    for d in q.D, b in r.Bd[d], t in q.Tset
        inv = max(inv, value(r.qch[d, b, t]) - f(d, value(r.pch[d, b, t]), value(r.zch[d, b, t])),
                       value(r.qdis[d, b, t]) - f(d, value(r.pdis[d, b, t]), value(r.zdis[d, b, t])))
    end
    return srv, inv
end

function write_reports(res, outdir::AbstractString)
    mkpath(outdir)
    q, mf = res.q, res.mf; r = mf.refs; m = mf.model
    k = kpis(res)
    ks = sort(collect(keys(k)))
    CSV.write(joinpath(outdir, "kpi.csv"), DataFrame(metric=ks, value=[string(k[x]) for x in ks]))
    has_values(m) || return k

    # ---- hourly site table: schedule, offer, and average power of each resource in each event stage
    rows = []
    for d in q.D, t in q.Tset
        bess, it, gen, tot0, tot1 = stage_split(res, d, t)
        row = Dict{String,Any}("site" => q.site_names[d], "hour" => t, "energy_price" => q.CE[t, d],
            "rrs_price" => q.CRRS[t], "pact" => q.pact[t], "W_fix" => q.Wfix[d, t], "l_flex" => value(r.lflex[d, t]),
            "l" => value(r.l[d, t]), "l_elig" => sum(value(r.lelig[d, t, j]) for j in q.J), "util" => value(r.u[d, t]),
            "p_IT" => value(r.pIT[d, t]), "p_facility" => q.PUE[d] * value(r.pIT[d, t]), "p_grid" => value(r.pgrid[d, t]),
            "bess_charge" => sum(value(r.pch[d, b, t]) for b in r.Bd[d]),
            "bess_discharge" => sum(value(r.pdis[d, b, t]) for b in r.Bd[d]),
            "r_FFR" => value(r.rffr[d, t]), "r_FFR_cap" => q.F[d] * q.PUE[d] * value(r.pIT[d, t]),
            "gen_units" => round(value(r.n[d, t])), "p_G_sustained" => value(r.pG[d, t]),
            "event_cost_BESS" => sum(q.C_B_act[d] * value(r.edev[d, b, t]) for b in r.Bd[d]),
            "min_response_ratio" => response_ratio(res, d, t))
        for s in q.S
            row["s$(s)_BESS"] = bess[s]; row["s$(s)_IT"] = it[s]; row["s$(s)_GEN"] = gen[s]
            row["s$(s)_total_start"] = tot0[s]; row["s$(s)_total_end"] = tot1[s]
        end
        push!(rows, row)
    end
    cols = vcat(["site", "hour", "energy_price", "rrs_price", "pact", "W_fix", "l_flex", "l", "l_elig", "util", "p_IT",
                 "p_facility", "p_grid", "bess_charge", "bess_discharge", "r_FFR", "r_FFR_cap", "gen_units", "p_G_sustained",
                 "event_cost_BESS", "min_response_ratio"],
                vcat([["s$(s)_BESS", "s$(s)_IT", "s$(s)_GEN", "s$(s)_total_start", "s$(s)_total_end"] for s in q.S]...))
    CSV.write(joinpath(outdir, "hourly_site.csv"), DataFrame([c => [rw[c] for rw in rows] for c in cols]))

    # ---- BESS blocks: schedule, event energies and slack of Eqs. 14-15 (worst point of K_t and hour of W_t)
    rows = NamedTuple[]
    for d in q.D, b in r.Bd[d], t in q.Tset
        epts = [value(r.e[d, b, kk <= q.T + 1 ? kk : kk - q.T]) for kk in (t, t + 1, t + 2)]
        emin = minimum(epts)
        pchmax = maximum(value(r.pch[d, b, θ]) for θ in (t, mod1(t + 1, q.T)))
        push!(rows, (site=q.site_names[d], block=b, hour=t, p_ch=value(r.pch[d, b, t]), p_dis=value(r.pdis[d, b, t]),
            z_ch=round(value(r.zch[d, b, t])), z_dis=round(value(r.zdis[d, b, t])), loss_ch=value(r.qch[d, b, t]),
            loss_dis=value(r.qdis[d, b, t]), e_start=value(r.e[d, b, t]), e_end=value(r.e[d, b, t+1]), E_min=q.Emin[d],
            e_draw=value(r.edraw[d, b, t]), e_dev=value(r.edev[d, b, t]), e_fixed_loss=value(r.efix[d, b, t]) + q.Efix[d],
            stages_on=(r.ydis === nothing ? missing : count(value(r.ydis[d, b, t, s]) > 0.5 for s in q.S)),
            slack_eq14=emin - q.Emin[d] - q.Efix[d] - value(r.edraw[d, b, t]),
            slack_eq15=emin - q.Emin[d] - q.Efix[d] + q.H_ev_ch[d] * (q.Pch_max[d] - pchmax) * q.T_rest -
                       value(r.edev[d, b, t]) - value(r.edraw[d, b, t])))
    end
    CSV.write(joinpath(outdir, "bess_blocks.csv"), DataFrame(rows))

    # ---- workload assignments with x > 0
    rows = NamedTuple[]
    for (i, a) in enumerate(q.A)
        xv = value(r.x[i]); xv > 1e-6 || continue
        push!(rows, (class=q.class_names[a.j], from_site=q.site_names[a.dp], arrival_hour=a.tp,
                     to_site=q.site_names[a.d], process_hour=a.t, units=xv, migrated=is_migration(a), delay_h=a.t - a.tp))
    end
    CSV.write(joinpath(outdir, "workload_assignments.csv"), DataFrame(rows))

    # ---- WAN link-hours (TB)
    used = Dict((lk, h) => 0.0 for lk in q.links, h in q.Tset)
    for ((i, h), var) in r.v
        used[((q.A[i].dp, q.A[i].d), h)] += value(var)
    end
    rows = [(link="$(q.site_names[lk[1]])->$(q.site_names[lk[2]])", hour=h, sent_TB=used[(lk, h)],
             capacity_TB=q.link_cap[lk], utilization=used[(lk, h)] / q.link_cap[lk]) for lk in q.links for h in q.Tset]
    CSV.write(joinpath(outdir, "wan_link_hours.csv"), DataFrame(rows))

    # ---- hourly cost of the what-if event and capacity revenue
    rows = [(hour=t, pact=q.pact[t], Cev_BESS=value(m[:Cev_B][t]), Cev_IT=value(m[:Cev_IT][t]), Cev_GEN=value(m[:Cev_G][t]),
             Cev_energy_credit=value(m[:Cev_credit][t]), Cev_total=value(m[:Cev][t]),
             fleet_FFR_MW=sum(value(r.rffr[d, t]) for d in q.D),
             capacity_revenue=q.CRRS[t] * sum(value(r.rffr[d, t]) for d in q.D)) for t in q.Tset]
    CSV.write(joinpath(outdir, "event_cost_hourly.csv"), DataFrame(rows))

    # ---- constraint check
    worst, fams = constraint_check(mf)
    srv, inv = nonlinear_residuals(mf)
    open(joinpath(outdir, "constraint_check.txt"), "w") do io
        println(io, "Constraint check of the FFR model (case $(res.label)), tolerance 1e-6")
        println(io, "Termination: ", termination_status(m), "   f_FFR = ", @sprintf("%.4f", objective_value(m)),
                    "   bound = ", @sprintf("%.4f", _bound(m)), "   C0 = ", @sprintf("%.4f", res.C0))
        println(io, "\nEquation family              max violation")
        for f in fams
            @printf(io, "  %-28s %s\n", f, haskey(worst, f) ? @sprintf("%.3e  VIOLATED", worst[f]) : "OK")
        end
        haskey(worst, "variable bounds / integrality") &&
            @printf(io, "  %-28s %.3e\n", "bounds / integrality", worst["variable bounds / integrality"])
        println(io, "\nQuadratic equalities")
        @printf(io, "  server curve  max |p_IT - Pmax g(u)|       = %.3e MW\n", srv)
        @printf(io, "  inverter loss max (q - f(p,z))             = %.3e MW %s\n", inv,
                mf.opts.inv_loss == :relaxed ? "(relaxed: >0 means wasted energy)" : "")
        println(io, "\nData conditions: ", join(["$(kk)=$(vv ? "OK" : "FAIL")" for (kk, vv) in sort(collect(q.checks))], "; "))
    end
    return k
end

function print_kpis(k)
    keyorder = ["status_noFFR", "status_FFR", "C0_USD", "f_FFR_USD", "f_FFR_bound_USD", "capacity_revenue_USD",
        "delta_C_DA_USD", "expected_event_cost_USD", "ffr_MW_h", "hours_with_ffr", "max_fleet_ffr_MW",
        "event_share_BESS", "event_share_IT", "event_share_GEN", "sustain_share_BESS", "sustain_share_IT",
        "sustain_share_GEN", "IT_at_QoS_cap_share", "IT_at_work_limit_share", "gen_expected_starts_per_year",
        "migrated_share", "avg_delay_h", "wan_max_util", "polished", "f_FFR_before_polish_USD",
        "min_response_ratio", "min_full_award_margin_MW", "min_deadline_slack_after_makeup_h",
        "makeup_max_window_utilization", "absorbed_training_backlog_units_per_year",
        "bess_sched_charge_block_hours", "bess_sched_discharge_block_hours", "bess_soc_min", "bess_soc_max",
        "bess_setpoints_below_min", "bess_charging_blocks_with_extra_discharge", "bess_min_positive_event_discharge_MW",
        "bess_min_backup_margin_MWh", "bess_fixed_loss_MWh_all_events", "gap_rel_FFR_first_solve", "n_binary_FFR"]
    println("---------------- KPIs ----------------")
    for kk in keyorder
        haskey(k, kk) || continue
        v = k[kk]
        println(rpad(kk, 30), v isa AbstractFloat ? round(v, digits=4) : v)
    end
end
