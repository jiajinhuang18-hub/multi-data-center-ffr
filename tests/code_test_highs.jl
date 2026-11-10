# ============================================================
# CODE TEST ONLY (not a result, model v6.9): builds the full model and solves a LINEAR
# stand-in with HiGHS (server curve replaced by its chord, inverter loss by a
# linear bound), first 24 h, small gap. Purpose: check that the code runs, the
# data conditions hold and every constraint family is satisfied by the solution.
#   FFR_SOLVER=highs julia --project=. tests/code_test_highs.jl
# ============================================================
import Pkg
lowercase(get(ENV, "FFR_SKIP_ACTIVATE", "false")) in ("1", "true", "yes") || Pkg.activate(joinpath(@__DIR__, ".."))
ENV["FFR_SOLVER"] = "highs"
get!(ENV, "FFR_MIP_GAP_ABS", "50")
get!(ENV, "FFR_TIME_LIMIT", "600")
include(joinpath(@__DIR__, "..", "ffr_include.jl"))
b = benchmark_inputs()
print_params(derive_params(b))
res = solve_case(b; label="code_test", server=:linear_test, inv_loss=:linear_test, verbose=false)
k = write_reports(res, joinpath(@__DIR__, "..", "results", "code_test"))
print_kpis(k)
print(read(joinpath(@__DIR__, "..", "results", "code_test", "constraint_check.txt"), String))
