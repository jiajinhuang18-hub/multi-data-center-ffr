# Day-Ahead Fast Frequency Response Scheduling for Multiple Data Centers

This repository contains the Julia implementation of a day-ahead fast frequency response (FFR) scheduling model for multiple data centers. The model coordinates UPS batteries, IT power capping, workload migration, and standby generators while accounting for their different response times and operational constraints.

## Repository Structure

- `main.jl`: Runs the base case.
- `ffr_model_v613.jl`: Optimization model and constraints.
- `ffr_params.jl`: Model parameters.
- `ffr_solver.jl`: Solver configuration.
- `benchmark/`: Benchmark parameters and input profiles.
- `experiments/`: Scripts for running experiments and generating plots.
- `tests/`: Model construction and code checks.

Additional model and benchmark details are provided in `BENCHMARK.md`, `EXPERIMENT_DESIGN.md`, and `MODEL_MAPPING.md`.

## Requirements

- Julia 1.12.5
- Gurobi with a valid license
- Julia dependencies specified in `Project.toml` and `Manifest.toml`

## Running the Code

Install the dependencies:

`julia --project=. -e "import Pkg; Pkg.instantiate()"`

Check that the model can be constructed:

`julia --project=. tests/build_check.jl`

Run the base case:

`julia --project=. main.jl`

Run the experiments:

`julia --project=. experiments/run_experiments.jl`

The full experiment suite may require substantial computation time.

## Benchmark Data

The repository includes a three-data-center benchmark with workload profiles, electricity prices, reserve price scenarios, UPS battery parameters, and generator characteristics. Some inputs are illustrative modeling assumptions rather than measured operating data.

## Notes

This repository provides the model, input data, and experiment scripts. Precomputed simulation results are not included.
