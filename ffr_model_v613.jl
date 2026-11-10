# ============================================================
# Model v6.13 (JuMP). Equation numbers refer to day_ahead_multi_dc_ffr_model_v6_13.pdf;
# constraint names start with "eqN".
#
# Options (keyword arguments of build_model):
#   with_ffr     false -> no-FFR model, minimizes c^DA (gives C0)
#                true  -> full model, maximizes f + C0 (= f^FFR, Eq. 29)
#   C0           constant added to the objective so that the solver reports f^FFR directly
#   inv_loss     :exact (Eq. 10 as equality, default) | :relaxed (q >= ..., Appendix B)
#   server       :quadratic (Eq. 3, default) | :linear_test (chord; ONLY for the code test)
#   gen_takeover true -> comparison case: BESS and IT give nothing in the sustain stage
#
# Event resolution: every stage s has a BESS value at its start (k=0) and end (k=1), linear in
# between (Eq. 12). Outside the loading stages one variable is used for both ends.
# v6.13 (q.bess_modes = true): binary y[d,b,t,s] = block b discharges in stage s of the event of hour t;
# executable setpoints (Eqs. 12a-12d) and the no-load loss of a block that is on (Eq. 13).
# ============================================================

using JuMP

function build_model(q; with_ffr::Bool, C0::Float64=0.0, inv_loss::Symbol=:exact,
                     server::Symbol=:quadratic, gen_takeover::Bool=false)
    m = Model()
    D, T, J = q.D, q.Tset, q.J
    A = q.A; nA = length(A)
    Bd = [1:q.nB[d] for d in q.D]
    Thr = q.Thr
    hp(t) = mod1(t, q.T)                         # periodic hour (24+ = 1)

    # ================= M1 workload (Eqs. 1-2) =================
    @variable(m, x[k=1:nA], lower_bound=0, upper_bound=q.Wflex[A[k].dp, A[k].tp, A[k].j])
    into = Dict((d, t) => Int[] for d in D, t in T)
    from = Dict((d, t, j) => Int[] for d in D, t in T, j in J)
    for (k, a) in enumerate(A)
        push!(into[(a.d, a.t)], k); push!(from[(a.dp, a.tp, a.j)], k)
    end
    @expression(m, lflex[d in D, t in T], sum(x[k] for k in into[(d, t)]; init=0.0))
    @expression(m, l[d in D, t in T], q.Wfix[d, t] + lflex[d, t])
    # work of class j processed at (d,t) that may be capped: absorbed classes always, others with >= T^mk_j h of slack
    @expression(m, lelig[d in D, t in T, j in J], sum(x[k] for k in into[(d, t)] if q.elig[k] && A[k].j == j; init=0.0))
    @constraint(m, [d in D, t in T, j in J], sum(x[k] for k in from[(d, t, j)]; init=0.0) == q.Wflex[d, t, j], base_name="eq1")
    @constraint(m, [d in D, t in T], l[d, t] <= q.Wmax[d] * Thr, base_name="eq2")

    # ================= M2 IT power and site balance (Eqs. 3-6) =================
    @variable(m, 0 <= u[d in D, t in T] <= 1)
    @constraint(m, [d in D, t in T], q.K[d] * u[d, t] * Thr == l[d, t], base_name="eq3_util")
    @variable(m, q.Pmax[d] * q.G0 <= pIT[d in D, t in T] <= q.Pmax[d])
    if server == :quadratic
        @constraint(m, [d in D, t in T], pIT[d, t] == q.Pmax[d] * (q.G0 + q.G1 * u[d, t] + q.G2 * u[d, t]^2), base_name="eq3")
    elseif server == :linear_test
        @constraint(m, [d in D, t in T], pIT[d, t] == q.Pmax[d] * (q.G0 + (q.G1 + q.G2) * u[d, t]), base_name="eq3")
    else
        error("server must be :quadratic or :linear_test")
    end

    @variable(m, 0 <= pch[d in D, b in Bd[d], t in T] <= q.Pch_max[d])
    @variable(m, 0 <= pdis[d in D, b in Bd[d], t in T] <= q.Pdis_max[d])
    @variable(m, zch[d in D, b in Bd[d], t in T], Bin)
    @variable(m, zdis[d in D, b in Bd[d], t in T], Bin)
    qmax(d, p) = q.Pinv[d] * (q.L0[d] + q.L1[d] * p / q.Pinv[d] + q.L2[d] * (p / q.Pinv[d])^2)
    @variable(m, 0 <= qch[d in D, b in Bd[d], t in T] <= (inv_loss == :relaxed ? Inf : qmax(d, q.Pch_max[d])))
    @variable(m, 0 <= qdis[d in D, b in Bd[d], t in T] <= (inv_loss == :relaxed ? Inf : qmax(d, q.Pdis_max[d])))
    @variable(m, q.Emin[d] <= e[d in D, b in Bd[d], t in 1:(q.T+1)] <= q.Emax[d])
    @variable(m, pgrid[d in D, t in T] >= 0)

    @constraint(m, [d in D, t in T], pgrid[d, t] + sum(pdis[d, b, t] for b in Bd[d]) ==
                                     q.PUE[d] * pIT[d, t] + sum(pch[d, b, t] for b in Bd[d]), base_name="eq4")
    @constraint(m, [d in D, t in T], sum(pdis[d, b, t] for b in Bd[d]) <= q.U[d] * pIT[d, t], base_name="eq5")
    for d in D
        isfinite(q.ramp[d]) || continue
        @constraint(m, [t in 2:q.T], pIT[d, t] - pIT[d, t-1] <= q.ramp[d], base_name="eq6_up")
        @constraint(m, [t in 2:q.T], pIT[d, t-1] - pIT[d, t] <= q.ramp[d], base_name="eq6_down")
        if q.ramp_cyclic   # the representative day repeats: hour 1 follows hour 24
            @constraint(m, pIT[d, 1] - pIT[d, q.T] <= q.ramp[d], base_name="eq6_cyc_up[$d]")
            @constraint(m, pIT[d, q.T] - pIT[d, 1] <= q.ramp[d], base_name="eq6_cyc_down[$d]")
        end
    end

    # ================= M3 WAN (Eqs. 7-8), data in TB =================
    mig = [k for k in 1:nA if is_migration(A[k])]
    v = Dict{Tuple{Int,Int},VariableRef}()
    for k in mig, h in A[k].tp:(A[k].t - 1)
        v[(k, h)] = @variable(m, lower_bound=0, base_name="v[$k,$h]")
    end
    for k in mig
        @constraint(m, sum(v[(k, h)] for h in A[k].tp:(A[k].t - 1)) == q.Ddata[A[k].j] * x[k], base_name="eq7[$k]")
    end
    on_link = Dict((lk, h) => Tuple{Int,Int}[] for lk in q.links, h in T)
    for (k, h) in keys(v)
        push!(on_link[((A[k].dp, A[k].d), h)], (k, h))
    end
    for lk in q.links, h in T
        isempty(on_link[(lk, h)]) && continue
        @constraint(m, sum(v[kh] for kh in on_link[(lk, h)]) <= q.link_cap[lk], base_name="eq8[$(lk[1])->$(lk[2]),$h]")
    end

    # ================= M4 BESS schedule (Eqs. 9-11) =================
    @constraint(m, [d in D, b in Bd[d], t in T], q.Pch_min[d] * zch[d, b, t] <= pch[d, b, t], base_name="eq9_chmin")
    @constraint(m, [d in D, b in Bd[d], t in T], pch[d, b, t] <= q.Pch_max[d] * zch[d, b, t], base_name="eq9_chmax")
    @constraint(m, [d in D, b in Bd[d], t in T], q.Pdis_min[d] * zdis[d, b, t] <= pdis[d, b, t], base_name="eq9_dismin")
    @constraint(m, [d in D, b in Bd[d], t in T], pdis[d, b, t] <= q.Pdis_max[d] * zdis[d, b, t], base_name="eq9_dismax")
    @constraint(m, [d in D, b in Bd[d], t in T], zch[d, b, t] + zdis[d, b, t] <= 1, base_name="eq9_mode")
    lossf(d, p, z) = q.Pinv[d] * q.L0[d] * z + q.L1[d] * p + (q.L2[d] / q.Pinv[d]) * p^2
    if inv_loss == :exact
        @constraint(m, [d in D, b in Bd[d], t in T], qch[d, b, t] == lossf(d, pch[d, b, t], zch[d, b, t]), base_name="eq10_ch")
        @constraint(m, [d in D, b in Bd[d], t in T], qdis[d, b, t] == lossf(d, pdis[d, b, t], zdis[d, b, t]), base_name="eq10_dis")
    elseif inv_loss == :relaxed
        @constraint(m, [d in D, b in Bd[d], t in T], qch[d, b, t] >= lossf(d, pch[d, b, t], zch[d, b, t]), base_name="eq10_ch")
        @constraint(m, [d in D, b in Bd[d], t in T], qdis[d, b, t] >= lossf(d, pdis[d, b, t], zdis[d, b, t]), base_name="eq10_dis")
    elseif inv_loss == :linear_test
        @constraint(m, [d in D, b in Bd[d], t in T], qch[d, b, t] >= q.Pinv[d] * q.L0[d] * zch[d, b, t] + (q.L1[d] + q.L2[d]) * pch[d, b, t], base_name="eq10_ch")
        @constraint(m, [d in D, b in Bd[d], t in T], qdis[d, b, t] >= q.Pinv[d] * q.L0[d] * zdis[d, b, t] + (q.L1[d] + q.L2[d]) * pdis[d, b, t], base_name="eq10_dis")
    else
        error("inv_loss must be :exact, :relaxed or :linear_test")
    end
    @constraint(m, [d in D, b in Bd[d], t in T], e[d, b, t+1] == e[d, b, t] +
        Thr * (q.H[d] * (pch[d, b, t] - qch[d, b, t]) - (pdis[d, b, t] + qdis[d, b, t]) / q.H[d]), base_name="eq11")
    @constraint(m, [d in D, b in Bd[d]], e[d, b, 1] == q.E0[d], base_name="eq11_start")
    @constraint(m, [d in D, b in Bd[d]], e[d, b, q.T+1] == q.E0[d], base_name="eq11_end")

    # ================= day-ahead cost (Eq. 26) =================
    @expression(m, C_energy, sum(q.CE[t, d] * pgrid[d, t] * Thr for d in D, t in T))
    @expression(m, C_bess_base, sum(q.C_B_base[d] * (pch[d, b, t] + pdis[d, b, t]) * Thr for d in D, b in Bd[d], t in T))
    @expression(m, C_mig, sum(q.C_mig[A[k].j] * x[k] for k in mig; init=0.0))
    @expression(m, C_dly, sum(q.C_dly[A[k].j] * (A[k].t - A[k].tp) * Thr * x[k] for k in 1:nA))
    @expression(m, C_DA, C_energy + C_bess_base + C_mig + C_dly)

    refs = (; x, u, pIT, pch, pdis, zch, zdis, qch, qdis, e, pgrid, v, l, lflex, lelig, mig, Bd)

    if !with_ffr
        @objective(m, Min, C_DA)
        return (model=m, q=q, with_ffr=false, refs=refs, opts=(; inv_loss, server, gen_takeover))
    end

    # ================= FFR offer and what-if event =================
    S, SL, s_sus = q.S, q.SL, q.s_sus
    W(t) = (t, hp(t + 1))                         # two-hour envelope W_t = {t, t+}
    eidx(k) = k <= q.T + 1 ? k : k - q.T          # stored-energy index, periodic (e[25] = e[1])
    Kset(t) = (t, t + 1, t + 2)                   # K_t

    @variable(m, 0 <= rffr[d in D, t in T] <= q.F[d] * q.PUE[d] * q.Pmax[d])
    # BESS event power at the start of every stage (k=0) and at the end of the loading stages (k=1)
    @variable(m, 0 <= rch0[d in D, b in Bd[d], t in T, s in S] <= q.Pch_max[d])
    @variable(m, 0 <= rdis0[d in D, b in Bd[d], t in T, s in S] <= q.Pdis_max[d])
    @variable(m, 0 <= rch1[d in D, b in Bd[d], t in T, s in SL] <= q.Pch_max[d])
    @variable(m, 0 <= rdis1[d in D, b in Bd[d], t in T, s in SL] <= q.Pdis_max[d])
    rch(d, b, t, s, k) = (k == 1 && s in SL) ? rch1[d, b, t, s] : rch0[d, b, t, s]     # second line of Eq. 12
    rdis(d, b, t, s, k) = (k == 1 && s in SL) ? rdis1[d, b, t, s] : rdis0[d, b, t, s]
    # v6.13 (F3): block b adds discharge in stage s of the event of hour t (same mode at both stage ends, so the
    # linear path inside the stage never enters the forbidden range 0 < p < P^dis,min)
    ydis = q.bess_modes ? @variable(m, ydis[d in D, b in Bd[d], t in T, s in S], Bin) : nothing
    @variable(m, 0 <= rITj[d in D, t in T, s in S, j in J] <= q.MQoS[d])      # IT reduction by class [MW]
    @expression(m, rIT[d in D, t in T, s in S], sum(rITj[d, t, s, j] for j in J))
    @variable(m, 0 <= n[d in D, t in T] <= q.N_FFR[d], Int)
    @variable(m, 0 <= pG[d in D, t in T] <= q.N_FFR[d] * q.P_G_avail)
    KK = (0, 1)

    # ---- Eq. 12: BESS power limits at both stage ends, two-hour envelope
    #      event setpoint of block b in hour θ: charge pch - rch, or discharge pdis + rdis
    for d in D, b in Bd[d], t in T, s in S, k in KK, θ in W(t)
        (k == 1 && !(s in SL)) && continue
        if q.bess_modes
            # (12a) a charging block only lowers its charge and stays at or above P^ch,min (stays on, keeps its mode)
            @constraint(m, rch(d, b, t, s, k) <= pch[d, b, θ] - q.Pch_min[d] * zch[d, b, θ], base_name="eq12_ch[$d,$b,$t,$s,$k,$θ]")
            # (12b) added discharge only when on, and the discharge setpoint is at least P^dis,min
            @constraint(m, rdis(d, b, t, s, k) <= q.Pdis_max[d] * ydis[d, b, t, s], base_name="eq12_on[$d,$b,$t,$s,$k]")
            @constraint(m, pdis[d, b, θ] + rdis(d, b, t, s, k) >= q.Pdis_min[d] * ydis[d, b, t, s],
                        base_name="eq12_dismin[$d,$b,$t,$s,$k,$θ]")
        else
            @constraint(m, rch(d, b, t, s, k) <= pch[d, b, θ], base_name="eq12_ch[$d,$b,$t,$s,$k,$θ]")
        end
        @constraint(m, rdis(d, b, t, s, k) <= q.Pdis_max[d] - pdis[d, b, θ], base_name="eq12_dis[$d,$b,$t,$s,$k,$θ]")
    end
    if q.bess_modes
        # (12c) no added discharge on a block that is charging in either hour of the envelope
        for d in D, b in Bd[d], t in T, s in S, θ in W(t)
            @constraint(m, ydis[d, b, t, s] <= 1 - zch[d, b, θ], base_name="eq12_mode[$d,$b,$t,$s,$θ]")
        end
    end
    # (12d) stages the BESS cannot reach in time (X_B,s = 0): no BESS increments at all
    for d in D, b in Bd[d], t in T, s in S
        q.XB[s] > 0 && continue
        fix(rch0[d, b, t, s], 0.0; force=true); fix(rdis0[d, b, t, s], 0.0; force=true)
        if s in SL
            fix(rch1[d, b, t, s], 0.0; force=true); fix(rdis1[d, b, t, s], 0.0; force=true)
        end
        q.bess_modes && fix(ydis[d, b, t, s], 0.0; force=true)
    end
    for d in D, t in T, s in S, k in KK, θ in W(t)
        (k == 1 && !(s in SL)) && continue
        @constraint(m, sum(pdis[d, b, θ] + rdis(d, b, t, s, k) for b in Bd[d]) <= q.U[d] * pIT[d, θ] - rIT[d, t, s],
                    base_name="eq12_ups[$d,$t,$s,$k,$θ]")
    end

    # ---- Eq. 13: event energies (stage average of the linear power); v6.13: plus the no-load loss of every
    #      stage in which the block is on (counted also for a block that was already discharging: conservative)
    @expression(m, efix[d in D, b in Bd[d], t in T],
        q.bess_modes ? sum(q.Pfix[d] * q.Ts[s] * ydis[d, b, t, s] for s in S) : AffExpr(0.0))
    @expression(m, edraw[d in D, b in Bd[d], t in T],
        sum((rdis(d, b, t, s, 0) + rdis(d, b, t, s, 1)) / (2 * q.H_ev_dis[d]) * q.Ts[s] for s in S) + efix[d, b, t])
    @expression(m, edev[d in D, b in Bd[d], t in T],
        edraw[d, b, t] + sum(q.H[d] * (rch(d, b, t, s, 0) + rch(d, b, t, s, 1)) / 2 * q.Ts[s] for s in S))
    # ---- Eq. 14 (backup floor) and Eq. 15 (restoration and second event), points K_t and hours W_t
    for d in D, b in Bd[d], t in T, ϑ in Kset(t)
        @constraint(m, edraw[d, b, t] <= e[d, b, eidx(ϑ)] - q.Emin[d] - q.Efix[d], base_name="eq14[$d,$b,$t,$ϑ]")
        for θ in W(t)
            @constraint(m, edev[d, b, t] + edraw[d, b, t] <= e[d, b, eidx(ϑ)] - q.Emin[d] - q.Efix[d] +
                q.H_ev_ch[d] * (q.Pch_max[d] - pch[d, b, θ]) * q.T_rest, base_name="eq15[$d,$b,$t,$ϑ,$θ]")
        end
    end

    # ---- Eq. 16: IT power capping per class on eligible work, and the site cap M^QoS
    for d in D, t in T, s in S, j in J, θ in W(t)
        @constraint(m, rITj[d, t, s, j] <= q.XIT[s] * q.Sd[d] * q.Acls[j][s] * lelig[d, θ, j] / Thr,
                    base_name="eq16[$d,$t,$s,$j,$θ]")
    end
    @constraint(m, [d in D, t in T, s in S], rIT[d, t, s] <= q.MQoS[d], base_name="eq16_qos")
    # ---- Eq. 17: make-up of the slowed work of the classes that are not absorbed, within each class's window,
    #      in physical spare capacity (classes sorted by window length; the windows are nested, so one
    #      constraint per window suffices); the event may start in hour t or continue into t+1, so the window
    #      starts at t+1 or t+2; hours after 24 are the next day's, equal to this day's (typical day)
    spare(d, h) = q.cap_mk[d] * Thr - l[d, hp(h)]
    @expression(m, cmk[d in D, t in T, j in J], sum(rITj[d, t, s, j] * q.Ts[s] for s in S) / q.Sd[d])   # work slowed
    for d in D, t in T, (pos, k) in enumerate(q.mk_order), δ in (0, 1)
        within = q.mk_order[1:pos]
        hs = (t + 1 + δ):(t + δ + q.T_mk[k])
        @constraint(m, sum(cmk[d, t, j] for j in within) <= sum(spare(d, h) for h in hs), base_name="eq17[$d,$t,$k,$δ]")
    end

    # ---- Eq. 19: generators (sustained output, minimum loading, loading rate); Eq. 21: no export after the event
    @constraint(m, [d in D, t in T], n[d, t] * q.P_G_min <= pG[d, t], base_name="eq19_min")
    @constraint(m, [d in D, t in T], pG[d, t] <= n[d, t] * q.P_G_avail, base_name="eq19_max")
    @constraint(m, [d in D, t in T], pG[d, t] <= n[d, t] * q.R_G_up * q.T_load, base_name="eq19_rate")
    for d in D, t in T, θ in W(t)
        @constraint(m, n[d, t] * q.P_G_min <= pgrid[d, θ], base_name="eq21[$d,$t,$θ]")
    end

    # ---- Eq. 22: delivery within the design band and no export, both stage ends (Eq. 18 trajectory: Y0, Y1)
    hBIT(d, t, s, k) = sum(q.XB[s] * (rch(d, b, t, s, k) + rdis(d, b, t, s, k)) for b in Bd[d]) + rIT[d, t, s]
    Y(s, k) = k == 0 ? q.Y0[s] : q.Y1[s]
    rtot(d, t, s, k) = hBIT(d, t, s, k) + Y(s, k) * pG[d, t]
    for d in D, t in T, s in S, k in KK
        (k == 1 && !(s in SL)) && continue
        @constraint(m, q.Qlo[s] * rffr[d, t] <= rtot(d, t, s, k), base_name="eq22_lo[$d,$t,$s,$k]")
        @constraint(m, rtot(d, t, s, k) <= q.Qhi[s] * rffr[d, t], base_name="eq22_hi[$d,$t,$s,$k]")
        for θ in W(t)
            @constraint(m, rtot(d, t, s, k) <= pgrid[d, θ], base_name="eq22_noexp[$d,$t,$s,$k,$θ]")
        end
    end
    @expression(m, rbar[d in D, t in T, s in S], (rtot(d, t, s, 0) + rtot(d, t, s, 1)) / 2)   # stage average
    if gen_takeover
        for d in D, t in T
            for j in J; fix(rITj[d, t, s_sus, j], 0.0; force=true); end
            for b in Bd[d]
                fix(rch0[d, b, t, s_sus], 0.0; force=true); fix(rdis0[d, b, t, s_sus], 0.0; force=true)
                q.bess_modes && fix(ydis[d, b, t, s_sus], 0.0; force=true)
            end
        end
    end

    # ---- Eqs. 23-25: offer limits and permit hours
    @constraint(m, [d in D, t in T], rffr[d, t] <= q.F[d] * q.PUE[d] * pIT[d, t], base_name="eq23_share")
    @constraint(m, [t in T], sum(rffr[d, t] for d in D) <= q.R_mkt, base_name="eq23_fleet")
    q.R_req > 0 && @constraint(m, [t in T], sum(rffr[d, t] for d in D) >= q.R_req, base_name="eq24")
    @constraint(m, [d in D], 365 * sum(q.pact[t] * q.T_G_tot * n[d, t] for t in T) <= q.T_perm * q.N_FFR[d], base_name="eq25")

    # ---- Eq. 27: cost of one full event starting in hour t
    @expression(m, Cev_B[t in T], sum(q.C_B_act[d] * edev[d, b, t] for d in D, b in Bd[d]))
    @expression(m, Cev_IT[t in T], sum((q.C_QoS[d] + q.PUE[d] * q.Mmk * q.CE_mk[t, d, j]) *
                                       sum(rITj[d, t, s, j] * q.Ts[s] for s in S) for d in D, j in J))
    @expression(m, Cev_G[t in T], sum(q.C_G_st * n[d, t] + q.C_G_nl * q.T_G_tot * n[d, t] + q.C_G_f * q.T_G_eq * pG[d, t] +
                                      (q.C_G_f - q.CE_ev[t, d]) * q.P_G_min * q.T_G_ext * n[d, t] for d in D))
    @expression(m, Cev_credit[t in T], sum(q.CE_ev[t, d] * sum(rbar[d, t, s] * q.Ts[s] for s in S) for d in D))
    @expression(m, Cev[t in T], Cev_B[t] + Cev_IT[t] + Cev_G[t] - Cev_credit[t])
    @expression(m, Rev, sum(q.CRRS[t] * Thr * rffr[d, t] for d in D, t in T))
    @expression(m, ECev, sum(q.pact[t] * Cev[t] for t in T))

    # ---- Eq. 28 + constant C0 (Eq. 29): the solver reports f^FFR directly
    @objective(m, Max, Rev - C_DA - ECev + C0)

    acc = (; rch, rdis, rtot, hBIT)
    refs = merge(refs, (; rffr, rch0, rdis0, rch1, rdis1, ydis, rIT, rITj, cmk, n, pG, efix, edraw, edev, rbar, acc))
    return (model=m, q=q, with_ffr=true, refs=refs, opts=(; inv_loss, server, gen_takeover))
end

"Warm start the FFR model with the no-FFR solution (offer 0, event variables 0 is feasible, Prop. 1)."
function warmstart_from_noffr!(mf, m0)
    r0, rf, q = m0.refs, mf.refs, mf.q
    for k in eachindex(r0.x); set_start_value(rf.x[k], value(r0.x[k])); end
    for (key, var) in r0.v; set_start_value(rf.v[key], value(var)); end
    for d in q.D, t in q.Tset
        set_start_value(rf.u[d, t], value(r0.u[d, t])); set_start_value(rf.pIT[d, t], value(r0.pIT[d, t]))
        set_start_value(rf.pgrid[d, t], value(r0.pgrid[d, t]))
        set_start_value(rf.rffr[d, t], 0.0); set_start_value(rf.n[d, t], 0.0); set_start_value(rf.pG[d, t], 0.0)
        for s in q.S, j in q.J; set_start_value(rf.rITj[d, t, s, j], 0.0); end
        for b in r0.Bd[d]
            for nm in (:pch, :pdis, :qch, :qdis)
                set_start_value(getfield(rf, nm)[d, b, t], value(getfield(r0, nm)[d, b, t]))
            end
            for nm in (:zch, :zdis)
                set_start_value(getfield(rf, nm)[d, b, t], round(value(getfield(r0, nm)[d, b, t])))
            end
            for s in q.S
                set_start_value(rf.rch0[d, b, t, s], 0.0); set_start_value(rf.rdis0[d, b, t, s], 0.0)
            end
            for s in q.SL
                set_start_value(rf.rch1[d, b, t, s], 0.0); set_start_value(rf.rdis1[d, b, t, s], 0.0)
            end
            if rf.ydis !== nothing
                for s in q.S; set_start_value(rf.ydis[d, b, t, s], 0.0); end
            end
        end
    end
    for d in q.D, b in r0.Bd[d], t in 1:(q.T + 1)
        set_start_value(rf.e[d, b, t], value(r0.e[d, b, t]))
    end
    return nothing
end
