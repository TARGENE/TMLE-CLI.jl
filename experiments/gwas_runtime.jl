using CSV
using DataFrames
using ArgParse
using TargetedEstimation
using TMLE
using Optim
using MLJLinearModels
using Statistics
using MLJBase

function parse_commandline()
    s = ArgParseSettings(
        description = "Runs TMLE for 100 SNPs, 1 binary and one continuous trait. Runtime will depend on the platform.",
        commands_are_required = false)

    @add_arg_table s begin
        "data"
            help = string("Path to the dataset, a copy is stored on datastore at: ",
                   "/exports/igmm/datastore/ponting-lab/olivier/misc_datasets/gwas_sample_data.csv")
            required = true
            default = "/exports/igmm/datastore/ponting-lab/olivier/misc_datasets/gwas_sample_data.csv"
        "--limit"
            arg_type = Int
            help = string("Limit the number of SNPs (max 100) used for runtime estimation. The actual number will be: ",
                    "limit - 1, to remove compilation bias."
            )
            required = false
        "--target"
            arg_type = String
            help = "Either: continuous/binary"
            required = false
    end

    return parse_args(s)
end

logistic_classifier(;fit_intercept=true) = LogisticClassifier(
    fit_intercept=fit_intercept,
    solver=MLJLinearModels.LBFGS(optim_options=Optim.Options(f_tol=1e-4))
    )

xgboost_classifier() = GridSearchXGBoostClassifier(
    resampling  = Dict(:type => "StratifiedCV", :nfolds => 3),
    tree_method = "hist",
    num_round   = 100,
    goal        = 10,
    max_depth   = "5, 7", 
    lambda      = "1e-5,10,log",
    alpha       = "1e-5,10,log")

xgboost_regressor() = GridSearchXGBoostRegressor(
    resampling  = Dict(:type => "CV", :nfolds => 3),
    tree_method = "hist",
    num_round   = 100,
    goal        = 10,
    max_depth   = "5, 7", 
    lambda      = "1e-5,10,log",
    alpha       = "1e-5,10,log")

function regression_nuisance_specs()
    return [
        ("GLM", NuisanceSpec(
            LinearRegressor(),
            logistic_classifier(;fit_intercept=true),
        )),
        ("GLMNet", NuisanceSpec(
            GLMNetRegressor(nfolds=3),
            GLMNetClassifier(nfolds=3),
        )),
        ("XGBoost", NuisanceSpec(
            xgboost_regressor(),
            xgboost_classifier(),
        )),
        ("SL: GLMNet+XGBoost", NuisanceSpec(
            Stack(
                metalearner = LinearRegressor(fit_intercept=false),
                xgboost     = xgboost_regressor(),
                glmnet      = GLMNetRegressor(nfolds=3),
                resampling  = CV(nfolds=3)),
            Stack(
                metalearner = LogisticClassifier(
                    fit_intercept=false, 
                    solver=MLJLinearModels.LBFGS(optim_options=Optim.Options(f_tol=1e-4))
                    ),
                xgboost     = xgboost_classifier(),
                glmnet      = GLMNetClassifier(nfolds=3),
                resampling  = StratifiedCV(nfolds=3)
                )
        ))
    ]
end

function classification_nuisance_specs()
    return [
        ("GLM", NuisanceSpec(
            logistic_classifier(;fit_intercept=true),
            logistic_classifier(;fit_intercept=true),
        )),
        ("GLMNet", NuisanceSpec(
            GLMNetClassifier(nfolds=3),
            GLMNetClassifier(nfolds=3),
        )),
        ("XGBoost", NuisanceSpec(
            xgboost_classifier(),
            xgboost_classifier(),
        )),
        ("SL: GLMNet+XGBoost", NuisanceSpec(
            Stack(
                metalearner = logistic_classifier(;fit_intercept=false),
                xgboost     = xgboost_classifier(),
                glmnet      = GLMNetClassifier(nfolds=3),
                resampling  = StratifiedCV(nfolds=3)),
            Stack(
                metalearner = logistic_classifier(;fit_intercept=false),
                xgboost     = xgboost_classifier(),
                glmnet      = GLMNetClassifier(nfolds=3),
                resampling  = StratifiedCV(nfolds=3)
                )
        ))
    ]
end

function main(parsed_args)
    # Load data
    dataset = CSV.read(parsed_args["data"], DataFrame)

    # Roles of columns
    rsids = Symbol.(filter(x -> startswith(x, "rs"), names(dataset)))
    ys_cat = Symbol.(["depression", "E66 Obesity", "D73 Diseases of spleen"])
    ys_cont = Symbol.(["Lymphocyte count", "Neutrophill count", "Body mass index (BMI)"])
    W = Symbol.(["Age-Assessment", "Genetic-Sex" ,"PC1" ,"PC2" ,"PC3" ,"PC4" ,"PC5" ,"PC6"])
    
    # Coerce data types
    TargetedEstimation.make_categorical!(dataset, Tuple(vcat(rsids, ys_cat)), true)
    dataset[!, "Age-Assessment"] = float(dataset[!, "Age-Assessment"])
    dataset[!, "Genetic-Sex"] = float(dataset[!, "Genetic-Sex"])
    
    nsnps = size(rsids, 1)
    if parsed_args["limit"] !== nothing
        nsnps = parsed_args["limit"]
    end
    @info string("Runtime estimation running over: ", nsnps - 1, " SNPs.")
    if parsed_args["target"] === nothing
        targets_specs = [
            (Symbol("Lymphocyte count"), regression_nuisance_specs()), 
            (Symbol("E66 Obesity"), classification_nuisance_specs())
            ]
    elseif parsed_args["target"] == "continuous"
        targets_specs = [
            (Symbol("Lymphocyte count"), regression_nuisance_specs()), 
            ]
    else
        targets_specs = [
            (Symbol("E66 Obesity"), classification_nuisance_specs())
            ]
    end
    for (target, η_specs) in targets_specs
        @info ("Target: ", target)
        for (spec_name, η_spec) in η_specs
            times = Vector{Float64}(undef, nsnps)
            for snpid in 1:nsnps
                snp    = rsids[snpid]
                treatment = NamedTuple{(snp, )}([(case=0, control = 1)])
                Ψ = ATE(
                    target      = target,
                    treatment   = treatment,
                    confounders = W
                )
                t = time()
                tmle(Ψ, η_spec, dataset, verbosity=0)
                times[snpid] = time() - t
            end
            # First run includes compilation
            times = times[2:end]
            @info string(spec_name, " runtime: ", mean(times), " ± ", 1.98*std(times), " seconds (95% CI).")
        end
    end
end

parsed_args = parse_commandline()

main(parsed_args)