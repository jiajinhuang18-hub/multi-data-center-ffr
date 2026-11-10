# ============================================================
# One case = (1) no-FFR model -> C0 = min C^DA,
#            (2) full model warm-started from (1) -> f^FFR (Eq. 29).
# C0 is cached: experiments that change only FFR-side inputs reuse it.
# ============================================================

# Inputs that appear only in the FFR part of the model; they do not change C0.
const FFR_ONLY_KEYS = Set([:rrs_scenario, :rrs_multiplier, :pact, :T_rest_h, :M_band, :R_mkt, :R_req, :F_share,
    :A_bridge, :A_sustain, :QoS_share, :C_QoS, :carry_share, :C_B_deg, :fixed_event_loss,
    :Q_lo_target, :elig_cross_hour, :bess_event_modes,
    :G_rating, :G_avail_share, :G_min_share, :N_FFR, :T_G_s, :T_load_s, :K_L, :R_G_up, :T_run_h, :T_cd_h,
    :T_perm_h, :C_G_st, :diesel_USD_gal, :fuel_kW, :fuel_gph, :fuel_ref_kW,
    :lat_B_s, :lat_IT_s, :stage1_end_s, :T_event_s, :rrs_profiles])

function noffr_key(b::Dict{Symbol,Any}, opts)
    ks = sort([k for k in keys(b) if !(k in FFR_ONLY_KEYS)])
    return hash((repr([(k, b[k]) for k in ks]), opts.inv_loss, opts.server))
end

const C0_CACHE = Dict{UInt,Any}()

"""
    solve_case(b; label, inv_loss=:exact, server=:quadratic, gen_takeover=false, verbose=true)

Returns a NamedTuple (q, m0, mf, C0, C0_bound, t0, tf, from_cache).
"""
function solve_case(b::Dict{Symbol,Any}; label::AbstractString="case", inv_loss::Symbol=:exact,
                    server::Symbol=:quadratic, gen_takeover::Bool=false, verbose::Bool=true,
                    use_cache::Bool=true)
    q = derive_params(b)
    all(values(q.checks)) || @warn "[$label] a data condition failed" q.checks
    opts = (; inv_loss, server)
    key = noffr_key(b, opts)

    from_cache = use_cache && haskey(C0_CACHE, key)
    if from_cache
        c = C0_CACHE[key]
        m0, C0, C0b, t0 = c.m0, c.C0, c.C0_bound, 0.0
        verbose && println("\n[$label] C0 reused from an earlier case: ", round(C0, digits=3), " USD")
    else
        verbose && println("\n===== [$label] no-FFR model (C0) =====")
        m0 = build_model(q; with_ffr=false, inv_loss, server)
        attach_solver!(m0; label="$(label)_noFFR", verbose)
        t0 = @elapsed optimize!(m0.model)
        has_values(m0.model) || error("[$label] no-FFR model: no solution (status $(termination_status(m0.model)))")
        C0, C0b = objective_value(m0.model), _bound(m0.model)
        verbose && println("[$label] no-FFR status = ", termination_status(m0.model), ", C0 = ", round(C0, digits=3),
                           " USD, bound = ", round(C0b, digits=3), ", time = ", round(t0, digits=1), " s")
        use_cache && (C0_CACHE[key] = (; m0, C0, C0_bound=C0b))
    end

    verbose && println("\n===== [$label] FFR model (objective = f^FFR) =====")
    mf = build_model(q; with_ffr=true, C0=C0, inv_loss, server, gen_takeover)
    attach_solver!(mf; label="$(label)_FFR", verbose)
    warmstart_from_noffr!(mf, m0)   # with R_req > 0 this start is infeasible; the solver repairs or ignores it
    tf = @elapsed optimize!(mf.model)
    verbose && println("[$label] FFR status = ", termination_status(mf.model),
                       has_values(mf.model) ? ", f_FFR = $(round(objective_value(mf.model), digits=3)) USD" : "",
                       ", bound = ", round(_bound(mf.model), digits=3), ", time = ", round(tf, digits=1), " s")
    f1, fb1 = has_values(mf.model) ? objective_value(mf.model) : NaN, _bound(mf.model)
    tp = 0.0; polished = false
    if has_values(mf.model) && lowercase(get(ENV, "FFR_POLISH", "true")) in ("1", "true", "yes")
        verbose && println("\n===== [$label] polish: event split for the fixed schedule =====")
        tp = @elapsed (mp = polish_event_split(q, mf, C0; inv_loss, server, gen_takeover, label, verbose))
        if mp !== nothing
            polished = true
            verbose && println("[$label] polish: expected event cost ", round(value(mf.model[:ECev]), digits=2), " -> ",
                               round(value(mp.model[:ECev]), digits=2), " USD/day, f_FFR = ",
                               round(objective_value(mp.model), digits=3), " USD, time = ", round(tp, digits=1), " s")
            mf = mp
        end
    end
    return (; q, m0, mf, C0, C0_bound=C0b, t0, tf, tp, from_cache, label, f_stage1=f1, f_bound=fb1, polished)
end

# ------------------------------------------------------------------------------------------
# Polish: the first FFR solve stops at a gap of thousands of USD, larger than the whole
# expected event cost, so the split among BESS, IT and generators is not optimized reliably.
# Fix every day-ahead variable and the offer at the solution found (a box of +-1e-7 for
# continuous variables, exact values for binaries) and re-optimize only the event variables.
# The result is the cheapest event split for that schedule; profit can only increase.
# ------------------------------------------------------------------------------------------
_keys(a) = a isa AbstractDict ? collect(keys(a)) : (a isa JuMP.Containers.SparseAxisArray ? collect(keys(a.data)) : collect(eachindex(a)))
_get(a, k) = a isa AbstractDict ? a[k] : (a isa JuMP.Containers.SparseAxisArray ? a.data[k] : a[k])

function _hold!(vp, val)
    if is_binary(vp) || is_integer(vp)
        fix(vp, round(val); force=true)
    else
        lo = val - 1e-7; hi = val + 1e-7
        has_lower_bound(vp) && (lo = max(lo, lower_bound(vp)))
        has_upper_bound(vp) && (hi = min(hi, upper_bound(vp)))
        lo > hi && (lo = hi)
        set_lower_bound(vp, lo); set_upper_bound(vp, hi)
    end
end

function polish_event_split(q, mf, C0; inv_loss, server, gen_takeover, label, verbose)
    mp = build_model(q; with_ffr=true, C0=C0, inv_loss, server, gen_takeover)
    rf, rp = mf.refs, mp.refs
    for nm in (:x, :u, :pIT, :pch, :pdis, :zch, :zdis, :qch, :qdis, :e, :pgrid, :v, :rffr)
        a, ap = getfield(rf, nm), getfield(rp, nm)
        for k in _keys(a)
            _hold!(_get(ap, k), value(_get(a, k)))
        end
    end
    for nm in (:rch0, :rdis0, :rch1, :rdis1, :ydis, :rITj, :n, :pG)   # warm start the event variables
        a, ap = getfield(rf, nm), getfield(rp, nm)
        a === nothing && continue
        for k in _keys(a)
            vp = _get(ap, k)
            is_fixed(vp) || set_start_value(vp, value(_get(a, k)))
        end
    end
    attach_solver!(mp; label="$(label)_polish", verbose=false, gap_rel=0.0,
                   gap_abs=parse(Float64, get(ENV, "FFR_POLISH_GAP_ABS", "1")))   # USD; v6.12 used 0.01
    try
        optimize!(mp.model)
    catch err
        @warn "[$label] polish failed; keeping the first solution" err
        return nothing
    end
    if has_values(mp.model) && objective_value(mp.model) >= objective_value(mf.model) - 1.0
        return mp
    end
    @warn "[$label] polish gave no better solution (status $(termination_status(mp.model))); keeping the first solution"
    return nothing
end
