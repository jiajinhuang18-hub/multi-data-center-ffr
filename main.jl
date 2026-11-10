# ============================================================
# Day-ahead multi-DC FFR model v6.13 -- base case
#   julia --project=. main.jl
#
# Benchmark values: benchmark/benchmark_params.jl and benchmark/profiles/*.csv
#
# Environment variables (all optional)
#   FFR_INV_LOSS      exact (default) | relaxed          Eq. 10
#   FFR_GEN_TAKEOVER  false (default) | true             comparison case: generators carry the sustain stage
#   FFR_WORKLOAD      site_roles (default) | homogeneous  homogeneous = the v6.9 workload
#   FFR_RRS           cap_peak_5000 (default) | aug2023_level | jun2026_actual | record_peak_25000   RRS price column
#   FFR_OUTPUT_DIR    default results/base
#   solver settings: see ffr_solver.jl (default: Gurobi, NO time limit, gap 100 USD or 1e-3, then the event-split polish)
# ============================================================
import Pkg
lowercase(get(ENV, "FFR_SKIP_ACTIVATE", "false")) in ("1", "true", "yes") || Pkg.activate(@__DIR__)

include(joinpath(@__DIR__, "ffr_include.jl"))

b = benchmark_inputs()
haskey(ENV, "FFR_RRS") && (b[:rrs_scenario] = ENV["FFR_RRS"])
lowercase(get(ENV, "FFR_WORKLOAD", "site_roles")) == "homogeneous" && apply_homogeneous!(b)
inv_loss = Symbol(lowercase(get(ENV, "FFR_INV_LOSS", "exact")))
takeover = lowercase(get(ENV, "FFR_GEN_TAKEOVER", "false")) in ("1", "true", "yes")

println("Benchmark: ", BENCHMARK_NAME, "   solver: ", FFR_SOLVER, "   time limit: ", _time_limit(),
        " s   gaps: abs ", get(ENV, "FFR_MIP_GAP_ABS", "100"), " USD, rel ", get(ENV, "FFR_MIP_GAP", "1e-3"),
        "   polish: ", get(ENV, "FFR_POLISH", "true"))
print_params(derive_params(b))

res = solve_case(b; label="base", inv_loss=inv_loss, gen_takeover=takeover)
outdir = get(ENV, "FFR_OUTPUT_DIR", joinpath(@__DIR__, "results", "base"))
k = write_reports(res, outdir)
print_kpis(k)
println("Results written to ", outdir)
