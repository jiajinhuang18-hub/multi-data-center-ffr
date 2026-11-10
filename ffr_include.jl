# Loads all project files (used by main.jl, experiments and tests).
using JuMP
include(joinpath(@__DIR__, "benchmark", "benchmark_params.jl"))
include(joinpath(@__DIR__, "ffr_params.jl"))
include(joinpath(@__DIR__, "ffr_solver.jl"))
include(joinpath(@__DIR__, "ffr_model_v613.jl"))
include(joinpath(@__DIR__, "ffr_case.jl"))
include(joinpath(@__DIR__, "ffr_report.jl"))
