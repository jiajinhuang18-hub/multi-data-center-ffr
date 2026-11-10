# ============================================================
# Derived parameters (model v6.13, Appendix A) computed from benchmark/benchmark_params.jl.
# Experiments change the input dictionary; everything below is recomputed consistently.
# ============================================================

using Statistics: mean

"Assignment i = (dp, d, tp, t, j): class-j work arriving at site dp in hour tp, processed at site d in hour t."
struct Assignment
    dp::Int
    d::Int
    tp::Int
    t::Int
    j::Int
end
is_migration(a::Assignment) = a.d != a.dp

"Least-squares line y = intercept + slope*x."
function _linfit(x::Vector{Float64}, y::Vector{Float64})
    xm, ym = mean(x), mean(y)
    slope = sum((x .- xm) .* (y .- ym)) / sum((x .- xm) .^ 2)
    return ym - slope * xm, slope
end

"Periodic hour: 25 -> 1, 26 -> 2 (typical day)."
_hp(t, T) = mod1(t, T)

"""
    derive_params(b; T=24)

Return a NamedTuple with all sets and parameters used by the model.
"""
function derive_params(b::Dict{Symbol,Any}; T::Int=24)
    nD = length(b[:P_IT_max]); nJ = length(b[:cls_share])
    D = 1:nD; J = 1:nJ; Tset = 1:T
    Thr = 1.0                                   # h, scheduling interval

    # ---------- server curve, normalized so that g(1) = 1 (Eq. 3)
    c = Float64.(b[:server_coef]); c = c ./ sum(c)
    G0, G1, G2 = c
    (G1 + 2G2 > 0 && G2 <= 0) || error("server curve must be increasing and concave on [0,1]")
    Pmax = Float64.(b[:P_IT_max]); PUE = Float64.(b[:PUE])
    K = copy(Pmax)                              # 1 work unit = 1 MW of servers at full utilization for 1 h
    Umax = Float64.(b[:u_max])
    Wmax = Umax .* K                            # [W^max] = U^max K: processing limit incl. the idle reserve, units/h
    Wcarry = b[:carry_share] .* K .* Thr        # units
    Sd = (Pmax ./ K) .* min(G1, G1 + 2G2)       # [S_d] MW per (unit/h)
    Mmk = max(G1, G1 + 2G2) / min(G1, G1 + 2G2) # [M^mk]
    MQoS = b[:QoS_share] .* Pmax

    # ---------- workload
    mode = String(get(b, :workload_mode, "homogeneous"))
    Wfix = zeros(nD, T); Wflex = zeros(nD, T, nJ); scale = zeros(nD)
    if mode == "site_roles"
        # each site: total work = util_peak * K * shape(t) / max(shape); split into fixed + flexible classes
        for d in D
            tr = b[:fix_orig][1:T, d] .+ b[:flex_orig][1:T, d]
            fl = Float64(get(b, :shape_floor, zeros(nD))[d])
            shape = b[:flat_profile][d] ? ones(T) : fl .+ (1 - fl) .* tr ./ maximum(tr)
            scale[d] = b[:util_peak][d] * K[d] * Thr / maximum(shape)
            for t in Tset
                tot = shape[t] * scale[d]
                Wfix[d, t] = b[:mix_fixed][d] * tot
                for j in J
                    Wflex[d, t, j] = b[:mix_flex][d][j] * tot
                end
            end
        end
    elseif mode == "homogeneous"
        # v6.9: trace split into fixed and flexible work, flexible work split by cls_share
        full0 = b[:fix_orig] .+ b[:flex_orig]
        for d in D
            scale[d] = b[:util_peak][d] * K[d] * Thr / maximum(full0[:, d])
        end
        for d in D, t in Tset
            Wfix[d, t] = b[:fix_orig][t, d] * scale[d]
            for j in J
                Wflex[d, t, j] = b[:flex_orig][t, d] * scale[d] * b[:cls_share][j]
            end
        end
    else
        error("workload_mode must be \"site_roles\" or \"homogeneous\"")
    end
    T_dly = Int.(b[:T_dly]); C_dly = Float64.(b[:C_dly])
    Ddata = Float64.(b[:TB_per_unit])                          # TB per unit
    C_mig = b[:fee_USD_GB] .* b[:TB_per_unit] .* 1000.0        # USD per migrated unit

    # ---------- WAN (Eq. 8), data in TB: one direct link per ordered pair
    links = [(a, c2) for a in D for c2 in D if a != c2]
    BW = b[:waves] * b[:Gbps_wave]                             # Gb/s
    link_cap = Dict(l => 3600.0 * Thr * (1 - b[:bg_share]) * BW / 8000.0 for l in links)   # TB per hour
    allow_mig = BW > 0 && get(b, :allow_migration, true)
    allow_delay = get(b, :allow_delay, true)

    # ---------- admissible assignments
    A = Assignment[]
    for dp in D, tp in Tset, j in J
        tmax = allow_delay ? min(T, tp + T_dly[j]) : tp
        for t in tp:tmax, d in D
            if d == dp
                push!(A, Assignment(dp, d, tp, t, j))
            elseif allow_mig && t >= tp + 1
                push!(A, Assignment(dp, d, tp, t, j))
            end
        end
    end
    # eligible for capping: may still be delayed by one hour (t < tp + T_dly)
    T_mk = Int.(get(b, :T_mk, ones(Int, nJ)))                   # [T^mk_j] make-up window, h
    absorb = Bool.(get(b, :makeup_absorb, fill(false, nJ)))   # slowed work absorbed by a later job finish
    # eligible for capping: an absorbed class always; otherwise the make-up window must end by the deadline
    # t' + T_dly. The work of hour t can be slowed by an event that starts in t and runs on into t+1 (delta = 1
    # in Eq. 17), whose window ends at t + 1 + T_mk; elig_cross_hour = true (F2) requires that case too.
    cross = get(b, :elig_cross_hour, false) ? 1 : 0
    elig = [absorb[a.j] || a.t + cross + T_mk[a.j] <= a.tp + T_dly[a.j] for a in A]
    mk_order = [j for j in sortperm(T_mk) if !absorb[j]]       # made-up classes by window length (nested windows)
    cap_mk = get(b, :makeup_uses_reserve, true) ? K .* 1.0 : Wmax   # capacity usable for make-up, units/h

    # ---------- UPS battery blocks
    U = Float64.(b[:U_share])
    P_UPS = U .* Pmax
    nB = Int.(b[:n_blocks])
    Pdis_max = P_UPS ./ nB
    Pinv = copy(Pdis_max)
    Ecap = P_UPS .* b[:runtime_min] ./ 60.0 ./ nB
    Pch_max = b[:charger_share] .* Pdis_max
    Pdis_min = b[:pmin_share] .* Pdis_max
    Pch_min = b[:pmin_share] .* Pch_max
    H = Float64.(b[:eta_batt])                                  # H^ch = H^dis
    L0, L1, L2 = Float64.(b[:L0]), Float64.(b[:L1]), Float64.(b[:L2])
    qloss(d, p, z=1.0) = Pinv[d] * (L0[d] * z + L1[d] * p / Pinv[d] + L2[d] * (p / Pinv[d])^2)
    Ersv = [(Pdis_max[d] + qloss(d, Pdis_max[d])) * b[:ride_min][d] / 60.0 / H[d] for d in D]
    Emin = [b[:soc_min][d] * Ecap[d] + Ersv[d] for d in D]
    Emax = b[:emax_share] .* Ecap
    E0 = b[:e0_share] .* Ecap
    H_ev_dis = [H[d] / (1 + L1[d] + 2L2[d] * Pdis_max[d] / Pinv[d]) for d in D]
    H_ev_ch = [H[d] * min(1 - qloss(d, Pch_max[d]) / Pch_max[d], 1 - L1[d] - 2L2[d] * Pch_max[d] / Pinv[d]) for d in D]
    bess_modes = Bool(get(b, :bess_event_modes, false))
    fixed_loss = Bool(get(b, :fixed_event_loss, false))
    # no-load inverter loss drawn from the cells [MW of stored power] by a block that is on in an event stage
    Pfix = fixed_loss ? [L0[d] * Pinv[d] / H[d] for d in D] : zeros(nD)
    # v6.12 variant (bess_event_modes = false): full-event fixed loss on every block, a constant in Eqs. 14-15
    Efix = (fixed_loss && !bess_modes) ? Pfix .* (b[:T_event_s] / 3600.0) : zeros(nD)

    # ---------- prices
    CE = Matrix{Float64}(b[:energy_price_base][1:T, :]) .* b[:energy_price_multiplier]   # T x nD
    haskey(b[:rrs_profiles], b[:rrs_scenario]) ||
        error("rrs_scenario '$(b[:rrs_scenario])' is not a column of rrs_price.csv: $(collect(keys(b[:rrs_profiles])))")
    CRRS = b[:rrs_profiles][b[:rrs_scenario]][1:T] .* b[:rrs_multiplier]
    CE_ev = [min(CE[t, d], CE[_hp(t + 1, T), d]) for t in Tset, d in D]                  # T x nD
    # make-up energy price: the highest price of the hours in which class-j make-up can fall (t+1 .. t+1+T^mk_j)
    # absorbed classes: the site's daily average price (the make-up happens when the job runs on)
    CE_mk = [absorb[j] ? mean(CE[:, d]) : maximum(CE[_hp(h, T), d] for h in (t + 1):(t + 1 + T_mk[j]))
             for t in Tset, d in D, j in J]   # T x nD x nJ
    Cbar = [mean(CE[:, d]) for d in D]
    C_B_act = [b[:C_B_deg][d] + Cbar[d] / H_ev_ch[d] for d in D]
    pact = fill(Float64(b[:pact]), T)

    # ---------- generators
    gint, gslope = _linfit(Float64.(b[:fuel_kW]), Float64.(b[:fuel_gph]))   # gal/h, gal/kWh
    C_G_f = gslope * 1000.0 * b[:diesel_USD_gal]                          # USD/MWh
    C_G_nl = gint * (b[:G_rating] * 1000.0 / b[:fuel_ref_kW]) * b[:diesel_USD_gal]   # USD/h per unit
    P_G_avail = b[:G_avail_share] * b[:G_rating]
    P_G_min = b[:G_min_share] * b[:G_rating]
    N_inst = [ceil(Int, PUE[d] * Pmax[d] / b[:G_rating]) + 1 for d in D]
    N_FFR = Int.(b[:N_FFR])
    T_FFR = b[:T_event_s] / 3600.0
    T_G_ext = max(0.0, b[:T_run_h] - T_FFR)
    T_G_tot = T_FFR + T_G_ext + b[:T_cd_h]

    # ---------- event stages (Appendix A): 1 fast, 2 bridge, 3..K_L+2 loading, K_L+3 sustain
    T_G = Float64(b[:T_G_s]); T_load = Float64(b[:T_load_s]); K_L = Int(b[:K_L])
    ends = vcat([b[:stage1_end_s], T_G], [T_G + k * T_load / K_L for k in 1:K_L], [b[:T_event_s]])
    starts = vcat([0.0], ends[1:end-1])
    nS = length(ends); S = 1:nS; s_sus = nS; SL = 3:(K_L + 2)
    Ts = (ends .- starts) ./ 3600.0                                      # h
    Y0 = zeros(nS); Y1 = zeros(nS)
    for (k, s) in enumerate(SL); Y0[s] = (k - 1) / K_L; Y1[s] = k / K_L; end
    Y0[s_sus] = 1.0; Y1[s_sus] = 1.0
    T_G_eq = sum(0.5 * (Y0[s] + Y1[s]) * Ts[s] for s in S)
    t_dl = [s == 1 ? 0.25 : starts[s] for s in S]                       # activation deadlines [s]
    Tact_B = sum(b[:lat_B_s]); Tact_IT = sum(b[:lat_IT_s])
    XB = [Tact_B <= t_dl[s] ? 1.0 : 0.0 for s in S]
    XIT = [Tact_IT <= t_dl[s] ? 1.0 : 0.0 for s in S]
    Acls = [[s == s_sus ? Float64(b[:A_sustain][j]) : Float64(b[:A_bridge][j]) for s in S] for j in J]   # [A_j,s]
    M = Float64(b[:M_band])
    Qlo = fill(Float64(get(b, :Q_lo_target, 0.95 + M)), nS)     # F1: 1.00 = full award planned
    Qhi = [s == 1 ? 1.05 - M : 1.10 - M for s in S]

    ramp = [isfinite(r) ? r * Pmax[d] : Inf for (d, r) in enumerate(Float64.(b[:ramp_share]))]
    ramp_cyclic = Bool(get(b, :ramp_cyclic, false))   # ramp limit also between hour 24 and hour 1

    # ---------- data conditions checked before solving (Appendix A)
    checks = Dict{String,Bool}()
    checks["S_d > 0"] = all(Sd .> 0)
    checks["arriving work fits under U^max"] = all(Wfix[d, t] + sum(Wflex[d, t, :]) <= Wmax[d] * Thr + 1e-9 for d in D, t in Tset)
    if mode == "site_roles"
        checks["site work mix sums to 1"] = all(abs(b[:mix_fixed][d] + sum(b[:mix_flex][d]) - 1) < 1e-9 for d in D)
    end
    checks["0 <= A_j,s <= 1"] = all(0 <= a <= 1 for a in vcat(Acls...))
    checks["1 <= T_mk_j <= T_dly_j"] = all(1 <= T_mk[j] <= T_dly[j] for j in J)
    checks["generators N+1 cover facility"] = all((N_inst[d] - 1) * b[:G_rating] >= PUE[d] * Pmax[d] - 1e-9 for d in D)
    checks["N_FFR <= N_inst - 1"] = all(N_FFR[d] <= N_inst[d] - 1 for d in D)
    checks["P_G_min <= P_G_avail"] = P_G_min <= P_G_avail
    checks["E0 >= E_min"] = all(E0[d] >= Emin[d] - 1e-12 for d in D)
    checks["E_max >= E0"] = all(Emax[d] >= E0[d] for d in D)
    checks["T_G > 2 s"] = T_G > b[:stage1_end_s]
    checks["T_G + T_load < 900 s"] = T_G + T_load < b[:T_event_s]
    checks["0 <= M_band < 0.05"] = 0 <= M < 0.05
    checks["0.95 <= Q_lo <= Q_hi"] = all(0.95 - 1e-12 <= Qlo[s] <= Qhi[s] for s in S)
    checks["T_rest <= 0.25 h"] = b[:T_rest_h] <= 0.25 + 1e-12
    checks["R_req <= R_mkt"] = b[:R_req] <= b[:R_mkt]
    checks["sum of stage durations = event length"] = abs(sum(Ts) - T_FFR) < 1e-9

    return (; nD, nJ, T, D, J, Tset, Thr, site_names=b[:site_names], class_names=b[:class_names],
        workload_mode=mode, site_roles=get(b, :site_roles, fill("", nD)), Umax,
        G0, G1, G2, Pmax, PUE, K, Wmax, Wcarry, Sd, Mmk, MQoS, ramp, ramp_cyclic, scale,
        Wfix, Wflex, T_dly, C_dly, Ddata, C_mig, links, BW, link_cap, A, elig, T_mk, mk_order, cap_mk, absorb,
        U, P_UPS, nB, Pdis_max, Pdis_min, Pch_max, Pch_min, Pinv, Ecap, Emin, Emax, E0, Ersv, H, L0, L1, L2,
        H_ev_dis, H_ev_ch, Efix, Pfix, bess_modes, fixed_loss, elig_cross=(cross == 1), C_B_base=Float64.(b[:C_B_base]), C_B_act,
        CE, CRRS, CE_ev, CE_mk, pact, rrs_scenario=b[:rrs_scenario],
        C_G_st=Float64(b[:C_G_st]), C_G_nl, C_G_f, P_G_avail, P_G_min, R_G_up=Float64(b[:R_G_up]),
        N_inst, N_FFR, T_perm=Float64(b[:T_perm_h]), T_FFR, T_G_ext, T_G_tot,
        T_G, T_load, K_L, nS, S, s_sus, SL, Ts, Y0, Y1, T_G_eq, t_dl, Tact_B, Tact_IT, XB, XIT, Acls,
        Qlo, Qhi, M_band=M, T_rest=Float64(b[:T_rest_h]),
        F=Float64.(b[:F_share]), C_QoS=Float64.(b[:C_QoS]),
        R_mkt=Float64(b[:R_mkt]), R_req=Float64(b[:R_req]), checks)
end

"Print the derived parameters so that the effect of an input change can be checked."
function print_params(q)
    r(x) = round.(x, digits=4)
    println("---------------- derived parameters (model v6.13, Appendix A) ----------------")
    println("workload mode = ", q.workload_mode, ";  classes = ", q.class_names, ", max delay ", q.T_dly, " h, slowed work absorbed ", q.absorb, ", make-up window ", q.T_mk,
            " h (make-up may use the idle reserve: ", q.cap_mk != q.Wmax, ");  A (bridge / sustain) = ",
            [r(q.Acls[j][1 + (q.XIT[1] == 0)]) for j in q.J], " / ", [r(q.Acls[j][end]) for j in q.J])
    println("RRS scenario = ", q.rrs_scenario, ": average ", r(mean(q.CRRS)), " USD/MW-h, max ", r(maximum(q.CRRS)),
            ";  energy price average per site ", r([mean(q.CE[:, d]) for d in q.D]), " USD/MWh")
    println("server curve G = ", r([q.G0, q.G1, q.G2]), ",  M_mk = ", r(q.Mmk))
    for d in q.D
        wtot = q.Wfix[d, :] .+ vec(sum(q.Wflex[d, :, :]; dims=2))
        println(q.site_names[d], " (", q.site_roles[d], "): work per hour ", r(minimum(wtot)), "-", r(maximum(wtot)),
                " units (utilization ", r(minimum(wtot) / q.K[d]), "-", r(maximum(wtot) / q.K[d]), ", cap U_max=", q.Umax[d],
                "); daily fixed ", r(sum(q.Wfix[d, :])), ", flexible by class ", r([sum(q.Wflex[d, :, j]) for j in q.J]))
        println("   P_IT_max=", q.Pmax[d], " MW, PUE=", q.PUE[d], ", S_d=", r(q.Sd[d]),
                ", M_QoS=", q.MQoS[d], " MW, ramp=", r(q.ramp[d]), " MW/h", q.ramp_cyclic ? " (cyclic)" : "",
                ", workload scale=", r(q.scale[d]))
        println("   UPS: U=", q.U[d], ", power=", r(q.P_UPS[d]), " MW in ", q.nB[d], " blocks; per block Pdis_max=", r(q.Pdis_max[d]),
                " MW, Pch_max=", r(q.Pch_max[d]), " MW, E=", r(q.Ecap[d]), " MWh, E_min=", r(q.Emin[d]),
                ", E0=", r(q.E0[d]), ";  H_ev_dis=", r(q.H_ev_dis[d]), ", H_ev_ch=", r(q.H_ev_ch[d]), ", C_B_act=", r(q.C_B_act[d]))
        usable = q.nB[d] * (q.E0[d] - q.Emin[d])
        println("   BESS energy above floor = ", r(usable), " MWh (", r(usable / q.P_UPS[d] * 60), " min at UPS power);",
                " generators: N_inst=", q.N_inst[d], ", N_FFR=", q.N_FFR[d], " (", r(q.N_FFR[d] * q.P_G_avail), " MW)")
    end
    println("generator unit: P_avail=", q.P_G_avail, " MW, P_min=", q.P_G_min, " MW, C_f=", r(q.C_G_f),
            " USD/MWh, C_nl=", r(q.C_G_nl), " USD/h, C_st=", q.C_G_st, " USD, T_perm=", q.T_perm,
            " h; T_ext=", r(q.T_G_ext), " h, T_tot=", r(q.T_G_tot), " h, T_G_eq=", r(q.T_G_eq), " h")
    println("stages [s]: ", r(q.Ts .* 3600), ";  Y0=", r(q.Y0), ", Y1=", r(q.Y1), ";  X_B=", q.XB, ", X_IT=", q.XIT)
    println("design band: Q_lo=", r(q.Qlo[1]), ", Q_hi(stage 1)=", r(q.Qhi[1]), ", Q_hi(later)=", r(q.Qhi[end]),
            ";  R_mkt=", q.R_mkt, " MW, R_req=", q.R_req, " MW, F=", q.F)
    println("v6.13 repairs: F1 full award (Q_lo = ", r(q.Qlo[1]), "); F2 cross-hour eligibility = ", q.elig_cross,
            " (eligible assignments ", count(q.elig), " of ", length(q.A), "); F3 BESS event modes = ", q.bess_modes,
            ", fixed event loss = ", q.fixed_loss, " (", r(q.Pfix), " MW per block and stage on)")
    println("WAN: ", q.BW, " Gb/s per link, ", r(first(values(q.link_cap))), " TB per link-hour;  |A| = ", length(q.A),
            " (migrations ", count(is_migration, q.A), ")")
    println("data conditions: ", join(["$(k)=$(v ? "OK" : "FAIL")" for (k, v) in sort(collect(q.checks))], "; "))
    println("------------------------------------------------------------------------------")
end
