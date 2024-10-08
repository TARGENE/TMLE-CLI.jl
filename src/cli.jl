function cli_settings()
    s = ArgParseSettings(
        description="TMLECLI.",
        add_version = true,
        commands_are_required = false,
        version=string(pkgversion(TMLECLI))
    )

    @add_arg_table! s begin
        "tmle"
            action = :command
            help = "Run TMLE."

        "merge"
            action = :command
            help = "Merges TMLE outputs together."
    end

    @add_arg_table! s["tmle"] begin
        "dataset"
            arg_type = String
            required = true
            help = "Path to the dataset (either .csv or .arrow)"

        "--estimands"
            arg_type = String
            help = "A string (`factorialATE`) or a serialized TMLE.Configuration (accepted formats: .json | .yaml | .jls)"
            default = "factorialATE"

        "--estimators"
            arg_type = String
            help = "A julia file containing the estimators to use."
            default = "wtmle-ose"

        "--verbosity"
            arg_type = Int
            default = 0
            help = "Verbosity level"

        "--hdf5-output"
            arg_type = String
            help = "HDF5 file output."
        
        "--json-output"
            arg_type = String
            help = "JSON file output."

        "--jls-output"
            arg_type = String
            help = "JLS file output."
        
        "--chunksize"
            arg_type = Int
            help = "Results are written in batches of size chunksize."
            default = 100

        "--rng"
            arg_type = Int
            help = "Random seed (Only used for estimands ordering at the moment)."
            default = 123

        "--cache-strategy"
            arg_type = String
            help = "Caching Strategy for the nuisance functions, any of (`release-unusable`, `no-cache`, `max-size`)."
            default = "release-unusable"
        
        "--sort-estimands"
            help = "Sort estimands to minimize cache usage (A brute force approach will be used, resulting in exponentially long sorting time)."
            action = :store_true
        
        "--save-sample-ids"
            help = "If hdf5-output is provided, save sample ids (SAMPLE_ID column) used for each estimand (only used by TarGene)."
            action = :store_true

        "--pvalue-threshold"
            arg_type = Float64
            help = "Save influence curves for estimates with pvalue < pvalue-threshold."

    end

    @add_arg_table! s["merge"] begin
        "prefix"
            arg_type = String
            help = "Prefix to .hdf5 files to be used to create the summary file."

        "--hdf5-output"
            arg_type = String
            help = "HDF5 file output."
        
        "--json-output"
            arg_type = String
            help = "JSON file output."
    
        "--jls-output"
            arg_type = String
            help = "JLS file output."
    end

    return s
end

function julia_main()::Cint
    settings = parse_args(ARGS, cli_settings())
    cmd = settings["%COMMAND%"]
    cmd_settings = settings[cmd]
    if cmd ∈ ("tmle", "merge")
        outputs = Outputs(
            hdf5=cmd_settings["hdf5-output"], 
            json=cmd_settings["json-output"], 
            jls=cmd_settings["jls-output"]
        )
        if cmd == "tmle"
            tmle(cmd_settings["dataset"];
                estimands=cmd_settings["estimands"], 
                estimators=cmd_settings["estimators"],
                verbosity=cmd_settings["verbosity"], 
                outputs=outputs,
                chunksize=cmd_settings["chunksize"],
                rng=cmd_settings["rng"],
                cache_strategy=cmd_settings["cache-strategy"],
                sort_estimands=cmd_settings["sort-estimands"],
                save_sample_ids=cmd_settings["save-sample-ids"],
                pvalue_threshold=cmd_settings["pvalue-threshold"]
            )
        else
            make_summary(cmd_settings["prefix"];
                outputs=outputs
            )
        end
    else
        throw(ArgumentError(string("Unknown command: ", cmd)))
    end
    return 0
end
