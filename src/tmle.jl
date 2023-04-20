function try_tmle!(cache; verbosity=1, threshold=1e-8)
    try
        tmle_result, _ = tmle!(cache; verbosity=verbosity, threshold=threshold)
        return tmle_result, missing
    catch e
        @warn string("Failed to run Targeted Estimation for parameter:", Ψ)
        return missing, string(e)
    end
end

function tmle_estimation(parsed_args)
    datafile = parsed_args["data"]
    paramfile = parsed_args["param-file"]
    estimatorfile = parsed_args["estimator-file"]
    verbosity = parsed_args["verbosity"]
    csv_file = parsed_args["csv-out"]
    jld2_file = parsed_args["jld2-out"]
    pval_threshold = parsed_args["pval-threshold"]
    chunksize = parsed_args["chunksize"]

    # Load dataset
    dataset = TargetedEstimation.instantiate_dataset(datafile)
    # Read parameter files
    parameters = TargetedEstimation.read_parameters(paramfile, dataset)
    optimize_ordering!(parameters)

    # Get covariate, confounder and treatment columns
    variables = TargetedEstimation.variables(parameters, dataset)
    TargetedEstimation.coerce_types!(dataset, variables)
    
    # Retrieve TMLE specifications
    tmle_spec = TargetedEstimation.tmle_spec_from_yaml(estimatorfile)

    cache = TMLECache(dataset)
    
    previous_is_binary = nothing
    nparams = size(parameters, 1)
    for partition in Iterators.partition(1:nparams, chunksize)
        partition_size = size(partition, 1)
        tmle_results = Vector{Union{TMLE.TMLEResult, Missing}}(undef, partition_size)
        logs = Vector{Union{String, Missing}}(undef, partition_size)
        for (partition_index, param_index) in enumerate(partition)
            Ψ = parameters[param_index]
            # Update cache with new Ψ
            update!(cache, Ψ)
            # Maybe update cache with new η_spec
            current_is_binary = Ψ.target ∈ variables.binarytargets
            if previous_is_binary !== current_is_binary
                Q_spec = current_is_binary ? tmle_spec.Q_binary : tmle_spec.Q_continuous
                η_spec = NuisanceSpec(Q_spec, tmle_spec.G, cache=tmle_spec.cache)
                update!(cache, η_spec)
            end
            # Run TMLE
            tmle_result, log = try_tmle!(cache; verbosity=verbosity, threshold=tmle_spec.threshold)
            # Update results
            tmle_results[partition_index] = tmle_result
            logs[partition_index] = log
            
            # Update memory
            previous_is_binary = current_is_binary
        end
        # Append CSV result with partition
        append_csv(csv_file, parameters[partition], tmle_results, logs)
        # Append HDF5 result if save-ic is true
        update_jld2_output(jld2_file, parameters, partition, tmle_results, logs, dataset; pval_threshold=pval_threshold)
    end

    verbosity >= 1 && @info "Done."
    return 0
end
