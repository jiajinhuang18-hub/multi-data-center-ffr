# ============================================================
# Solver settings. Default: Gurobi, NO time limit, run until the absolute gap
# of the objective is at most FFR_MIP_GAP_ABS (USD).
#
# Environment variables
#   FFR_SOLVER       gurobi (default) | highs   (highs only for the linear code test)
#   FFR_TIME_LIMIT   seconds; default "none" = no limit
#   FFR_MIP_GAP      relative gap; default 1e-3
#   FFR_MIP_GAP_ABS  absolute gap in USD; default 100
#   (Gurobi stops when EITHER gap is reached.)
#   FFR_POLISH       true (default) | false: after the FFR solve, fix the day-ahead schedule and the
#                    offer and re-optimize only the event split (BESS / IT / generators) to a 0.01 USD gap
#   FFR_POLISH_GAP_ABS  absolute gap of the polish step in USD; default 1 (v6.13: the event mode
#                    binaries make a 0.01 USD polish slow; 1 USD is about 0.2% of the expected event cost)
#   FFR_THREADS      0 = all cores (default)
#   FFR_GRB_PARAMS   extra Gurobi parameters, e.g. "MIPFocus=1,Presolve=2"
#   FFR_LOG_DIR      folder for Gurobi log files (default: none)
#
# Why these gaps: c^DA is about one million USD per day and the FFR profit is in the
# millions with the default RRS prices, so a relative gap of 1e-3 means a few thousand USD.
# The expected event cost is only hundreds of USD per day, smaller than that gap, so the
# split of the event among BESS, IT and generators would not be optimized reliably by the
# first solve. The polish step (ffr_case.jl) re-optimizes exactly that split for the
# schedule found, which is a small mixed-integer linear problem.
# ============================================================

const FFR_SOLVER = lowercase(get(ENV, "FFR_SOLVER", "gurobi"))
if FFR_SOLVER == "gurobi"
    using Gurobi
elseif FFR_SOLVER == "highs"
    using HiGHS
else
    error("FFR_SOLVER must be 'gurobi' or 'highs'")
end

const _GRB_ENV = Ref{Any}(nothing)
_grb_env() = (_GRB_ENV[] === nothing && (_GRB_ENV[] = Gurobi.Env()); _GRB_ENV[])

function _time_limit()
    s = lowercase(strip(get(ENV, "FFR_TIME_LIMIT", "none")))
    return s in ("", "none", "inf", "0") ? Inf : parse(Float64, s)
end

function _parse_value(s)
    v = tryparse(Int, s); v !== nothing && return v
    v = tryparse(Float64, s); v !== nothing && return v
    return s
end

"Attach the solver to model `mm` (NamedTuple returned by build_model)."
function attach_solver!(mm; label::AbstractString="model", verbose::Bool=true,
                        gap_rel=nothing, gap_abs=nothing)
    m = mm.model
    tl = _time_limit()
    gap = gap_rel === nothing ? parse(Float64, get(ENV, "FFR_MIP_GAP", "1e-3")) : Float64(gap_rel)
    gapabs = gap_abs === nothing ? parse(Float64, get(ENV, "FFR_MIP_GAP_ABS", "100")) : Float64(gap_abs)
    threads = parse(Int, get(ENV, "FFR_THREADS", "0"))
    if FFR_SOLVER == "gurobi"
        set_optimizer(m, () -> Gurobi.Optimizer(_grb_env()))
        set_attribute(m, "OutputFlag", verbose ? 1 : 0)
        set_attribute(m, "MIPGap", gap)
        set_attribute(m, "MIPGapAbs", gapabs)
        isfinite(tl) && set_attribute(m, "TimeLimit", tl)
        threads > 0 && set_attribute(m, "Threads", threads)
        # Quadratic equalities (Eqs. 3 and 10) are nonconvex. Gurobi >= 11 accepts them by
        # default; NonConvex = 2 is needed for Gurobi 9-10. Setting it is harmless otherwise.
        try
            set_attribute(m, "NonConvex", 2)
        catch err
            @warn "Could not set NonConvex=2 (fine for Gurobi >= 11)" err
        end
        logdir = get(ENV, "FFR_LOG_DIR", "")
        if !isempty(logdir)
            mkpath(logdir); set_attribute(m, "LogFile", joinpath(logdir, "gurobi_$(label).log"))
        end
        for kv in split(get(ENV, "FFR_GRB_PARAMS", ""), ','; keepempty=false)
            k, v = strip.(split(kv, '='))
            set_attribute(m, String(k), _parse_value(String(v)))
        end
    else
        set_optimizer(m, HiGHS.Optimizer)
        set_attribute(m, "output_flag", verbose)
        set_attribute(m, "mip_rel_gap", gap)
        set_attribute(m, "mip_abs_gap", gapabs)
        isfinite(tl) && set_attribute(m, "time_limit", tl)
    end
    return mm
end

"Objective bound (best bound) if the solver provides one, otherwise NaN."
_bound(m) = try objective_bound(m) catch; NaN end
_gap(m) = try relative_gap(m) catch; NaN end
