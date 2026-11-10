# ==========================================================================================
#  BENCHMARK v6.13 -- ALL INPUT PARAMETERS
#
#  This is the only place where benchmark values are set. Edit the numbers here and rerun.
#  Hourly profiles (24 rows) are CSV files in benchmark/profiles/ and can be edited in Excel:
#      workload_fixed.csv, workload_flexible.csv   original workload trace per site (scaled, see WORKLOAD)
#      energy_price.csv                            energy price per site [USD/MWh]
#      rrs_price.csv                               RRS capacity price scenarios [USD/MW-h], one column each
#  Everything that the model PDF (Appendix A) derives from these inputs is computed in
#  ffr_params.jl and printed at the start of every run, so you can check what a change does.
#
#  Conventions: per-site vectors are [DC1, DC2, DC3]; per-class vectors are [batch, analytics].
#  Symbols in [brackets] are the symbols of the model PDF v6.13.
# ==========================================================================================

const BENCHMARK_NAME = "ffr_benchmark_v6_13"
const PROFILE_DIR = joinpath(@__DIR__, "profiles")

function benchmark_inputs()
    b = Dict{Symbol,Any}()
    b[:site_names]  = ["DC1", "DC2", "DC3"]

    # ------------------------------------------------------------------ MARKET AND EVENT
    # RRS capacity price: choose a column of benchmark/profiles/rrs_price.csv
    #   "cap_peak_5000"     (DEFAULT) ERCOT DAM RRS hourly shape of 2026-06-19 scaled so that the peak hour
    #                       equals 5,000 USD/MW-h, the present ancillary-service offer cap (HCAP, 16 TAC
    #                       25.509; NPRR1080 keeps AS clearing prices within it). Daily average about 875.
    #   "aug2023_level"     same shape scaled to the August-2023 average RRS price (132.73 USD/MW-h)
    #   "jun2026_actual"    ERCOT DAM RRS MCPC of 2026-06-19 (average about 1 USD/MW-h)
    #   "record_peak_25000" same shape, peak 25,000 USD/MW-h: AS MCPCs during Winter Storm Uri (Feb 2021),
    #                       above the cap of the time; not possible under the present rules (stress only)
    b[:rrs_scenario]   = "cap_peak_5000"
    b[:rrs_multiplier] = 1.0          # multiplies the chosen column (sensitivity)
    b[:energy_price_multiplier] = 1.0 # multiplies energy_price.csv (PLACEHOLDER profiles, not ERCOT data)
    b[:pact]      = 0.000905797101449275  # [P^act] probability that a full FFR event starts in a given hour
    b[:T_rest_h]  = 0.25              # [T^rest] h, restoration period; ERCOT: restore within 15 min (<= 0.25)
    b[:Q_lo_target] = 1.00            # [Q^lo] planned response at every stage end, share of the award (F1):
                                      #   1.00 = the full award is planned; the 95% side of the ERCOT band is
                                      #   left for control and metering error. 0.95 + M_band = the v6.12 setting
    b[:M_band]    = 0.02              # [M^band] design margin below the ERCOT upper limits:
                                      #   Q_hi = 1.05-M (stage 1) and 1.10-M (later stages)
    b[:R_mkt]     = 250.0             # [R^mkt] MW, largest fleet FFR offer (ERCOT FFR limit is 450 MW)
    b[:R_req]     = 0.0               # [R^req] MW, minimum fleet commitment per hour (0 = offer is free)
    b[:F_share]   = [0.25, 0.25, 0.25]# [F_d] FFR offer cap as share of facility load (operator policy)

    # ------------------------------------------------------------------ SITES AND IT
    b[:P_IT_max]  = [500.0, 250.0, 100.0]   # [P^IT,max] MW, IT power at full utilization
    b[:PUE]       = [1.2, 1.3, 1.4]         # [PUE_d]
    b[:ramp_share] = [0.15, 0.15, 0.15]     # [P^ramp] max IT power change per hour, share of P^IT,max (Inf = none)
    b[:ramp_cyclic] = true                  # true: the ramp limit also holds from hour 24 to hour 1 (the day repeats,
                                            #   consistent with the periodic event look-ahead and make-up). false = v6.13
    # Server curve g(u) = G0 + G1 u + G2 u^2 (SPECpower fit); normalized in the code so that g(1) = 1
    b[:server_coef] = [0.34928024621618, 0.812597801455739, -0.169143762458525]

    # ------------------------------------------------------------------ WORKLOAD AND SITE ROLES
    # workload_mode "site_roles" (DEFAULT): each site has a role and its own mix of work types.
    #   Latency-critical work (user-facing inference, cloud front ends) = fixed work: processed in its
    #   arrival hour at its own site, never migrated or capped. The flexible classes are listed below.
    # workload_mode "homogeneous": the v6.9 setting (same trace split and classes at every site), kept as a
    #   comparison case; apply_homogeneous!(b) at the end of this file sets all of its values.
    b[:workload_mode] = "site_roles"
    b[:site_roles]   = ["AI training campus", "inference / cloud", "mixed cloud"]
    b[:util_peak]    = [0.97, 0.55, 0.60]   # utilization of the busiest hour (DC1: every hour, flat profile)
    b[:flat_profile] = [true, false, false] # true = the same work every hour (training runs around the clock);
                                            #   false = shape of the workload trace (workload_*.csv)
    b[:shape_floor]  = [0.0, 0.5, 0.5]      # trace sites: lowest hour = this share of the busiest hour
                                            #   (user-facing load dips at night but does not vanish);
                                            #   shape = floor + (1 - floor) * trace / max(trace)
    b[:u_max]        = [1.00, 0.80, 0.85]   # [U^max_d] utilization cap: the inference/cloud sites keep 20% / 15%
                                            #   idle for user-facing bursts; the training campus keeps none
    b[:mix_fixed]    = [0.10, 0.70, 0.50]   # share of a site's work that is latency-critical (fixed)
    b[:mix_flex]     = [[0.80, 0.10],       # DC1 share of its work: [training, batch]
                        [0.00, 0.30],       # DC2
                        [0.20, 0.30]]       # DC3        (mix_fixed + sum(mix_flex) = 1 at every site)
    # flexible work classes
    b[:class_names] = ["training", "batch"]
    b[:T_dly]       = [6, 3]                # [T^dly_j] h, maximum delay: checkpointed training / cloud batch
    b[:C_dly]       = [0.5, 0.5]            # [C^dly_j] USD per unit and hour of delay
    b[:makeup_absorb] = [true, false]       # true: work of this class slowed in an event is absorbed by the job
                                            #   finishing slightly later (long training runs: a 20% slowdown for
                                            #   15 min delays a multi-day job by about 3 min); no make-up capacity
                                            #   is reserved in the day, the make-up energy is priced at the site's
                                            #   daily average price. false: made up within T_mk hours (below)
    b[:T_mk]        = [3, 1]                # [T^mk_j] h, make-up window of a class that is not absorbed; only work
                                            #   with at least this much slack left is eligible for capping
    b[:elig_cross_hour] = true              # (F2) true: work processed in hour t is eligible only if the make-up
                                            #   window also fits before its deadline when the event runs on into
                                            #   hour t+1 (t + 1 + T_mk <= t' + T_dly). false = v6.12 test
    b[:TB_per_unit] = [1.0, 0.3]            # [D_j] TB moved per migrated unit (training: checkpoint + data shards)
    b[:fee_USD_GB]  = [0.01, 0.01]          # private WAN marginal cost; [C^mig_j] = fee x data per unit
    b[:carry_share] = 0.25                  # [W^carry] = share x processing capacity (make-up early next day)
    b[:cls_share]   = [0.6, 0.4]            # used only in workload_mode "homogeneous"

    # ------------------------------------------------------------------ IT POWER CAPPING IN AN EVENT
    # [A_j,s] share of a class's eligible work that power capping may slow (latency-critical work: never)
    b[:A_bridge]  = [0.20, 0.15]            # [training, batch], stages before sustain (GPU power capping)
    b[:A_sustain] = [0.15, 0.10]            # [training, batch], sustain stage (field demo: 25% for 3 h)
    b[:QoS_share] = 0.15                    # [M^QoS] = share x P^IT,max, MW: largest IT reduction per site
    b[:makeup_uses_reserve] = true          # true: make-up after an event may use the idle reserve (1 - U^max);
                                            #   events are rare (about 8 a year) and make-up lasts a few hours
    b[:C_QoS]     = [150.0, 150.0, 150.0]   # [C^QoS] USD/MWh of capped IT energy, per site

    # ------------------------------------------------------------------ WAN
    b[:waves]      = 2.0                    # 400G wavelengths per site pair (0 = no migration)
    b[:Gbps_wave]  = 400.0
    b[:bg_share]   = 0.5                    # [B^bg] share of link capacity used by other traffic

    # ------------------------------------------------------------------ UPS BATTERY (BESS)
    b[:U_share]       = [0.5, 0.6, 0.8]     # [U_d] share of IT capacity and IT power on the UPS (critical IT)
    b[:runtime_min]   = [5.0, 5.0, 5.0]     # UPS runtime at full UPS power [min]
    b[:ride_min]      = [3.0, 3.0, 3.0]     # backup ride-through kept for outages [min]; sets the floor E^min
                                            #   (larger -> less BESS energy for FFR -> generators carry more)
    b[:soc_min]       = [0.10, 0.10, 0.10]  # technical minimum state of charge (not usable)
    b[:e0_share]      = 0.95                # [E^0] start/end stored energy as share of capacity (float charge)
    b[:emax_share]    = 1.00                # [E^max]
    b[:n_blocks]      = [10, 10, 10]        # UPS blocks per site (identical)
    b[:charger_share] = [0.2, 0.2, 0.2]     # [P^ch,max] = share x block discharge power
    b[:pmin_share]    = [0.1, 0.1, 0.1]     # [P^ch,min], [P^dis,min] = share x max power
    b[:eta_batt]      = [0.98489, 0.98489, 0.98489]   # [H^ch] = [H^dis] battery-only efficiency
    b[:L0] = [0.005057, 0.005057, 0.005057] # [L_0] inverter loss coefficients (Schmidt-Sauer, M5BAT fit)
    b[:L1] = [4.6e-6, 4.6e-6, 4.6e-6]       # [L_1]
    b[:L2] = [0.02058, 0.02058, 0.02058]    # [L_2]
    b[:C_B_base] = [2.0, 2.0, 2.0]          # [C^B,base] USD/MWh throughput cost of the schedule
    b[:C_B_deg]  = [20.0, 20.0, 20.0]       # degradation part of [C^B,act], USD/MWh
    b[:bess_event_modes] = true             # (F3) true: executable block setpoints in an event. A charging block
                                            #   only lowers its charge and stays at or above P^ch,min; any other
                                            #   block that adds discharge runs at or above P^dis,min in that stage
                                            #   (binary per block and stage). false = v6.12 (increments only)
    b[:fixed_event_loss] = true             # (F3) true: the inverter no-load loss L_0 P^inv of every block that
                                            #   discharges in an event stage is charged to its stored energy for
                                            #   that stage (Eqs. 13-15). With bess_event_modes = false it is the
                                            #   v6.12 variant (full-event loss on every block). false = no fixed loss

    # ------------------------------------------------------------------ GENERATORS (identical units)
    b[:G_rating]      = 3.0                 # MW per unit
    b[:G_avail_share] = 0.9                 # [P^G,avail] = share x rating
    b[:G_min_share]   = 0.3                 # [P^G,min]   = share x rating
    b[:N_FFR]   = [50, 27, 12]              # [N^FFR_d] qualified (grid-parallel, permitted) units per site;
                                            #   sized so that generators can carry the largest award
    b[:T_G_s]     = 30.0                    # [T^G] s, start and synchronize
    b[:T_load_s]  = 30.0                    # [T^G,load] s, linear ramp to the sustained output
    b[:K_L]       = 3                       # [K^L] number of loading stages
    b[:R_G_up]    = 0.10                    # [R^G,up] MW/s per unit, confirmed loading rate
    b[:T_run_h]   = 0.5                     # [T^G,run] h, minimum run time per start
    b[:T_cd_h]    = 5 / 60                  # [T^G,cd] h, unloaded cool-down
    b[:T_perm_h]  = 50.0                    # [T^perm] h per unit and year (non-emergency air permit)
    b[:C_G_st]    = 100.0                   # [C^G,st] USD per start
    b[:diesel_USD_gal] = 5.005              # fuel price
    b[:fuel_kW]  = [687.5, 1375.0, 2062.5, 2750.0]   # Cat 3516E datasheet points (output kW, fuel gal/h);
    b[:fuel_gph] = [62.6, 107.4, 147.9, 194.3]       #   line fit gives [C^G,f] and [C^G,nl]
    b[:fuel_ref_kW] = 2750.0

    # ------------------------------------------------------------------ EVENT TIMING
    b[:lat_B_s]  = [0.02, 0.003, 0.05]      # BESS detection, communication, execution [s]
    b[:lat_IT_s] = [0.02, 0.1, 1.0]         # IT capping detection, communication, execution [s]
    b[:stage1_end_s] = 2.0                  # end of the fast stage [s]
    b[:T_event_s]    = 900.0                # event length [s]

    # ------------------------------------------------------------------ HOURLY PROFILES (CSV)
    b[:fix_orig]  = _read_profile("workload_fixed.csv")
    b[:flex_orig] = _read_profile("workload_flexible.csv")
    b[:energy_price_base] = _read_profile("energy_price.csv")
    rrs = _read_profile("rrs_price.csv")      # Dict column => vector
    b[:rrs_profiles] = rrs
    return b
end

# ---------------- comparison case: the v6.9 homogeneous workload ----------------
"Set the v6.9 workload: the same trace split and classes (batch, analytics) at every site, no idle reserve."
function apply_homogeneous!(b)
    n = length(b[:P_IT_max])
    b[:workload_mode] = "homogeneous"
    b[:class_names] = ["batch", "analytics"]
    b[:T_dly] = [3, 1]; b[:C_dly] = [0.5, 1.0]; b[:T_mk] = [1, 1]; b[:makeup_absorb] = [false, false]
    b[:TB_per_unit] = [0.3, 4.0]; b[:fee_USD_GB] = [0.02, 0.02]
    b[:cls_share] = [0.6, 0.4]
    b[:A_bridge] = [0.20, 0.20]; b[:A_sustain] = [0.15, 0.15]
    b[:util_peak] = fill(0.75, n); b[:u_max] = fill(1.0, n); b[:flat_profile] = fill(false, n)
    return b
end

# ---------------- comparison case: the v6.12 formulation (before the F1-F3 repairs) ----------------
"Switch off the three v6.13 repairs: 97% planned response, one-hour slack test, BESS increments without modes."
function apply_v612_formulation!(b)
    b[:Q_lo_target] = 0.95 + b[:M_band]
    b[:elig_cross_hour] = false
    b[:bess_event_modes] = false
    b[:fixed_event_loss] = false
    return b
end

# ---------------- helper: read a 24-row profile CSV (first column = hour) ----------------
function _read_profile(file::AbstractString)
    lines = filter(!isempty, strip.(readlines(joinpath(PROFILE_DIR, file))))
    header = strip.(split(lines[1], ','))
    data = [parse.(Float64, strip.(split(l, ','))) for l in lines[2:end]]
    if file == "rrs_price.csv"
        return Dict(String(header[c]) => [row[c] for row in data] for c in 2:length(header))
    end
    return permutedims(hcat([row[2:end] for row in data]...))   # 24 x nSites matrix
end
