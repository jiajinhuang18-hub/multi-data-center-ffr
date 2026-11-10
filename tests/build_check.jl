# ============================================================
# BUILD CHECK ONLY: loads the benchmark, derives the parameters and builds the no-FFR and
# FFR models without solving them. Use it after editing benchmark/benchmark_params.jl to see
# quickly that the inputs are consistent (data conditions) and the model builds.
#   julia --project=. tests/build_check.jl
# ============================================================
import Pkg
lowercase(get(ENV, "FFR_SKIP_ACTIVATE", "false")) in ("1", "true", "yes") || Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "..", "ffr_include.jl"))
b = benchmark_inputs()
q = derive_params(b)
print_params(q)
all(values(q.checks)) || @warn "a data condition failed" q.checks
m0 = build_model(q; with_ffr=false)
println("no-FFR model: ", num_variables(m0.model), " variables, ",
        num_constraints(m0.model; count_variable_in_set_constraints=false), " constraints")
mf = build_model(q; with_ffr=true)
println("FFR model:    ", num_variables(mf.model), " variables, ",
        num_constraints(mf.model; count_variable_in_set_constraints=false), " constraints")
println("build check finished")
