# ============================================================
# Experiments for model v6.13
#   julia --project=. experiments/run_experiments.jl
#
#   FFR_EXPERIMENTS   comma-separated groups to run, default "all", e.g. "E1,E2,E7"
#   FFR_EXP_OUTPUT    default experiments/results
#   FFR_RRS           base RRS price column for every case (default: cap_peak_5000)
#
# Each case solves the no-FFR model (C0) and the FFR model. C0 is reused when only
# FFR-side inputs change (generators, prices of RRS, band, ...), so those groups cost
# one solve per case. Results are appended to summary.csv after every case; cases
# already in summary.csv are skipped (delete the file to rerun everything).
# Base values: benchmark/benchmark_params.jl. Every case changes only what is listed.
# ============================================================
import Pkg
lowercase(get(ENV, "FFR_SKIP_ACTIVATE", "false")) in ("1", "true", "yes") || Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "..", "ffr_include.jl"))

setv(b, key, val) = (b[key] = val isa AbstractVector ? copy(val) : fill(val, length(b[key])); b)
scalev(b, key, f) = (b[key] = round.(Int, b[key] .* f); b)

"Case list: (group, case name, function that modifies the input dict, keyword options)."
function experiment_cases()
    C = Any[]
    add!(g, name, f; kw...) = push!(C, (group=g, name=name, modify=f, kw=(; kw...)))
    # E1 base case
    add!("E1", "base", b -> b)
    # E2 number of qualified generators (share of the base N_FFR = 50/27/12)
    for f in (0.0, 0.25, 0.5, 0.75, 1.0)
        add!("E2", "N_FFR_x$(f)", b -> scalev(b, :N_FFR, f))
    end
    # E3 generators take over the whole sustain stage (compare with E2)
    for f in (0.0, 0.25, 0.5, 0.75, 1.0)   # 0.0 and 0.25 added for Fig. 3(a)
        add!("E3", "takeover_N_FFR_x$(f)", b -> scalev(b, :N_FFR, f); gen_takeover=true)
    end
    # E4 backup ride-through kept in the UPS: sets how much BESS energy is left for FFR
    for rmin in (2.0, 2.5, 3.0, 3.5, 4.0)
        add!("E4", "ride=$(rmin)min", b -> setv(b, :ride_min, rmin))
    end
    # E5 RRS price scenario (column of rrs_price.csv)
    for sc in ("cap_peak_5000", "aug2023_level", "jun2026_actual", "record_peak_25000")
        add!("E5", "rrs=$(sc)", b -> (b[:rrs_scenario] = sc; b))
    end
    # E6 generator start + synchronization time
    for tg in (15.0, 30.0, 60.0)
        add!("E6", "T_G=$(Int(tg))s", b -> (b[:T_G_s] = tg; b))
    end
    # E7 generator loading time (linear ramp to the sustained output)
    for tl in (10.0, 30.0, 60.0, 120.0)
        add!("E7", "T_load=$(Int(tl))s", b -> (b[:T_load_s] = tl; b[:R_G_up] = max(b[:R_G_up], 3.0 / tl); b))
    end
    # E8 number of loading stages: with BESS linear in each stage K_L = 1 is already exact
    for kl in (1, 3, 6)
        add!("E8", "K_L=$(kl)", b -> (b[:K_L] = kl; b))
    end
    # E9 design margin below the ERCOT upper limits (v6.13: the lower side is the full award, Q_lo = 1.00)
    for mb in (0.0, 0.02, 0.04)
        add!("E9", "M_band=$(mb)", b -> (b[:M_band] = mb; b))
    end
    # E10 IT capping in the sustain stage, both classes (0 = IT only bridges)
    for a in (0.0, 0.10, 0.20, 0.30)
        add!("E10", "A_sustain=$(a)", b -> setv(b, :A_sustain, a))
    end
    # E11 fleet FFR limit
    for rm in (100.0, 250.0, 400.0)
        add!("E11", "R_mkt=$(Int(rm))MW", b -> (b[:R_mkt] = rm; b))
    end
    # E12 FFR offer cap as share of facility load
    for fs in (0.15, 0.25, 0.35)
        add!("E12", "F=$(fs)", b -> setv(b, :F_share, fs))
    end
    # E13 UPS coverage U (same value at all sites; changes C0)
    for us in (0.4, 0.6, 0.8)
        add!("E13", "U=$(us)", b -> setv(b, :U_share, us))
    end
    # E14 WAN wavelengths per site pair (0 = no migration; changes C0)
    for w in (0.0, 1.0, 2.0, 4.0)
        add!("E14", "waves=$(Int(w))", b -> (b[:waves] = w; b))
    end
    # E15 IT power ramp limit (share of IT capacity per hour; Inf = none; changes C0)
    for rs in (Inf, 0.30, 0.15, 0.10)
        add!("E15", "ramp=$(rs)", b -> setv(b, :ramp_share, rs))
    end
    # E16 no-load inverter loss of the blocks that are on in an event stage (v6.13 base: on)
    add!("E16", "fixed_loss=off", b -> (b[:fixed_event_loss] = false; b))
    add!("E16", "fixed_loss=on", b -> (b[:fixed_event_loss] = true; b))
    # E17 inverter loss: exact equality vs convex relaxation (Appendix B)
    add!("E17", "inv=exact", b -> b; inv_loss=:exact)
    add!("E17", "inv=relaxed", b -> b; inv_loss=:relaxed)
    # ---------------- new in v6.10 - v6.12 ----------------
    # E18 IT flexibility: site roles (training campus / inference / mixed cloud) vs the v6.9 homogeneous
    #     workload, migration, training deadline slack, capping share, QoS cap and the idle reserve
    add!("E18", "homogeneous_v6.9", b -> apply_homogeneous!(b))
    add!("E18", "roles_base", b -> b)
    add!("E18", "roles_no_migration", b -> (b[:waves] = 0.0; b))
    for td in (3, 12)
        add!("E18", "train_delay=$(td)h", b -> (b[:T_dly] = [td, b[:T_dly][2]]; b[:T_mk] = [min(b[:T_mk][1], td), b[:T_mk][2]]; b))
    end
    add!("E18", "train_absorb=off", b -> (b[:makeup_absorb] = [false, b[:makeup_absorb][2]]; b))
    add!("E18", "train_absorb=off_makeup=6h", b -> (b[:makeup_absorb] = [false, b[:makeup_absorb][2]]; b[:T_mk] = [6, b[:T_mk][2]]; b))
    add!("E18", "makeup_reserve=off", b -> (b[:makeup_uses_reserve] = false; b))
    for a in (0.10, 0.20, 0.25)
        add!("E18", "train_A_sustain=$(a)", b -> (b[:A_sustain] = [a, b[:A_sustain][2]]; b[:A_bridge] = [a + 0.05, b[:A_bridge][2]]; b))
    end
    for qs in (0.10, 0.25)
        add!("E18", "QoS_cap=$(Int(qs * 100))%", b -> (b[:QoS_share] = qs; b))
    end
    for (nm, um) in (("idle_reserve=0", [1.0, 1.0, 1.0]), ("idle_reserve=30%", [1.0, 0.70, 0.70]))
        add!("E18", nm, b -> (b[:u_max] = um; b))
    end
    # ---------------- new in v6.13: reviewer repairs F1-F3 ----------------
    # E19 each repair switched off alone, and all three off (= the v6.12 formulation, same benchmark)
    add!("E19", "v6.13_base", b -> b)
    add!("E19", "v6.12_formulation", b -> apply_v612_formulation!(b))
    add!("E19", "F1_off_Q_lo=0.97", b -> (b[:Q_lo_target] = 0.95 + b[:M_band]; b))
    add!("E19", "F2_off_one_hour_slack", b -> (b[:elig_cross_hour] = false; b))
    add!("E19", "F3_off_increments_only", b -> (b[:bess_event_modes] = false; b[:fixed_event_loss] = false; b))
    add!("E19", "F3_modes_without_fixed_loss", b -> (b[:fixed_event_loss] = false; b))
    # largest UPS reserve (E4 ride = 4 min) with the v6.12 formulation, to compare with E4/ride=4.0min
    add!("E19", "ride=4.0min_v6.12_formulation", b -> (apply_v612_formulation!(b); setv(b, :ride_min, 4.0)))
    return C
end

function _append_summary(summary_file, k)
    row = DataFrame(Dict(kk => [vv isa Number ? vv : string(vv)] for (kk, vv) in k))
    if isfile(summary_file)
        old = CSV.read(summary_file, DataFrame)
        row = vcat(old, row; cols=:union)
    end
    CSV.write(summary_file, row)
end

function main()
    outdir = get(ENV, "FFR_EXP_OUTPUT", joinpath(@__DIR__, "results"))
    mkpath(outdir)
    sel = uppercase(get(ENV, "FFR_EXPERIMENTS", "all"))
    groups = sel == "ALL" ? nothing : Set(strip.(split(sel, ',')))
    summary_file = joinpath(outdir, "summary.csv")
    done = Set{String}()
    if isfile(summary_file)
        old = CSV.read(summary_file, DataFrame)
        for rr in eachrow(old); push!(done, string(rr.group, "/", rr.case)); end
    end
    seen = Dict{UInt,Any}()   # identical inputs in several groups (e.g. the base case) are solved once
    for c in experiment_cases()
        groups !== nothing && !(c.group in groups) && continue
        id = string(c.group, "/", c.name)
        id in done && (println("skip (already in summary.csv): ", id); continue)
        b0 = benchmark_inputs()
        haskey(ENV, "FFR_RRS") && (b0[:rrs_scenario] = ENV["FFR_RRS"])   # base RRS column for all cases (E5 still varies it)
        b = c.modify(b0)
        label = replace("$(c.group)_$(c.name)", r"[^A-Za-z0-9_.=-]" => "_")
        ckey = hash((repr(sort(collect(b); by=first)), c.kw))
        if haskey(seen, ckey)
            k = copy(seen[ckey]); k["group"] = c.group; k["case"] = c.name; k["same_as"] = k["label_solved"]
            _append_summary(summary_file, k)
            println("same inputs as ", k["label_solved"], " -> reused for ", id)
            continue
        end
        kw = c.kw
        if lowercase(get(ENV, "FFR_CODE_TEST", "false")) in ("1", "true", "yes")
            kw = merge(kw, (; server=:linear_test, inv_loss=:linear_test))   # code test only, not results
        end
        res = try
            solve_case(b; label=label, verbose=!(lowercase(get(ENV, "FFR_VERBOSE", "true")) in ("0", "false", "no")), kw...)
        catch err
            @error "case failed" id err
            continue
        end
        k = write_reports(res, joinpath(outdir, "cases", label))
        k["group"] = c.group; k["case"] = c.name; k["label_solved"] = label; k["same_as"] = ""
        seen[ckey] = k
        _append_summary(summary_file, k)
        println("finished ", id, ": f_FFR = ", get(k, "f_FFR_USD", NaN))
    end
    println("Summary: ", summary_file)
end

main()
