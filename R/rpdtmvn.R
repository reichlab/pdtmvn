#' Simulate observations from a pdTMVN distribution
#' 
#' @param n integer number of samples
#' @param x_fixed Vector or matrix of quantiles for variables to condition on.
#'   If x_fixed is a matrix, it should have one row.
#' @param mean Mean vector, default is rep(0, nrow(sigma)).
#' @param sigma Covariance matrix, default is diag(length(mean)).
#' @param precision Precision (inverse covariance) matrix.
#' @param lower Vector of lower truncation points, default is
#'   rep(-Inf, length = length(mean)).
#' @param upper Vector of upper truncation points, default is 
#'   rep(Inf, length = length(mean)).
#' @param sigma_continuous Matrix containing the marginal
#'   covariance matrix for the continuous variables.  Providing this saves a
#'   small amount of computation time if precision is provided but sigma isn't.
#' @param conditional_sigma_discrete Matrix containing the conditional covariance
#'   of the discrete variables given the continuous variables.  Providing this
#'   saves a small amount of computation time if sigma is provided but precision
#'   isn't.
#' @param conditional_mean_discrete_offset_multiplier Matrix containing
#'   Sigma_dc Sigma_c^{-1}.  This is used in computing the mean of the underlying
#'   multivariate normal distribution for the discrete variables conditioning on
#'   the continuous variables.  Providing this saves a small amount of
#'   computation time.
#' @param continuous_vars Vector containing either column names or column
#'   indices for continuous variables.
#' @param discrete_vars Vector containing either column names or column indices
#'   for discrete variables.
#' @param discrete_var_range_functions a list with one entry for each element
#'   of discrete_vars.  Each entry is a named list of length 4: the element
#'   named "a" is a character string with the name of a function that returns
#'   a(x) for any real x; the element named "b" is a character string with the
#'   name of a function that returns b(x) for any real x; the element named
#'   "in_range" is a character string with the name of a function that returns a
#'   logical, TRUE if x is in the support of the corresponding discrete variable
#'   and FALSE otherwise; and the element named "discretizer" is a function that
#'   takes continuous values and returns the corresponding discretized values.
#' @param validate_level Numeric; if 0, no validation is performed (risky!).
#'   If 1, parameters are validated but warnings about checks not performed are
#'   not issued.  If 2, parameters are validated and warnings about checks not
#'   performed are issued.
#' 
#' @return matrix of values simulated from the pdTMVN distribution
rpdtmvn <- function(n,
        x_fixed,
		mean,
		sigma,
		precision,
		lower = rep(-Inf, length = length(mean)),
		upper = rep(Inf, length = length(mean)),
		sigma_continuous,
		conditional_sigma_discrete,
		conditional_mean_discrete_offset_multiplier,
		continuous_vars,
		discrete_vars,
		discrete_var_range_functions = lapply(seq_along(discrete_vars), function(dv) {
			list(a = "floor_x_minus_1", b = "floor", in_range = "equals_integer", discretize = "ceiling")
		}),
		validate_level = TRUE) {
	
	## Convert x_fixed to matrix if a vector or data frame was passed in
    if(!missing(x_fixed) && !is.null(x_fixed)) {
        if(is.vector(x_fixed)) {
            x_fixed_names <- names(x_fixed)
            dim(x_fixed) <- c(1, length(x_fixed))
            colnames(x_fixed) <- x_fixed_names
        } else if(is.data.frame(x_fixed)) {
            x_fixed <- as.matrix(x_fixed)
        }
    }
    
    ## Ensure that mean and sigma/precision have row and/or column names
    var_names <- NA
    if(!identical(names(mean), NULL)) {
        var_names <- names(mean)
    }
    
    if(any(is.na(var_names)) && !missing(sigma)) {
        if(!identical(colnames(sigma), NULL)) {
            var_names <- colnames(sigma)
        } else if(!identical(rownames(sigma), NULL)) {
            var_names <- rownames(sigma)
        }
    }
    
    if(any(is.na(var_names)) && !missing(precision)) {
        if(!identical(colnames(precision), NULL)) {
            var_names <- colnames(precision)
        } else if(!identical(rownames(precision), NULL)) {
            var_names <- rownames(precision)
        }
    }
    
    if(any(is.na(var_names))) {
        stop("at least one of mean, sigma, and/or precision must include names, row names, or column names")
    }
    
    names(mean) <- var_names
    if(!missing(sigma) && !is.null(sigma)) {
        rownames(sigma) <- var_names
        colnames(sigma) <- var_names
    }
    if(!missing(precision) && !is.null(precision)) {
        rownames(precision) <- var_names
        colnames(precision) <- var_names
    }
    
    if(!missing(x_fixed) && !is.null(x_fixed)) {
        fixed_vars <- which(var_names %in% colnames(x_fixed))
    } else {
        fixed_vars <- NULL
    }
    free_vars <- which(!(var_names %in% fixed_vars))
    
	## Validate parameters
	if(validate_level > 0) {
        ## validate n
        n <- as.integer(n)
        if(length(n) > 1L) {
            warning("n should have length 1; using first element")
            n <- n[1]
        }
        if(n < 1) {
            stop("n must be a positive integer")
        }
        
        ## validate data type of x_fixed
        if(!missing(x_fixed) && !identical(nrow(x_fixed), 1L)) {
            stop("If supplied, x_fixed must be a vector or a matrix or data frame with one row")
        }
        
        validated_params <- validate_params_pdtmvn(x = matrix(mean, nrow = 1),
			mean = mean,
			sigma = sigma,
			precision = precision,
			lower = lower,
			upper = upper,
			norm_const = norm_const,
			trunc_const = trunc_const,
			sigma_continuous = sigma_continuous,
			conditional_sigma_discrete = conditional_sigma_discrete,
			conditional_mean_discrete_offset_multiplier = 
				conditional_mean_discrete_offset_multiplier,
			continuous_vars = continuous_vars,
			discrete_vars = discrete_vars,
			validate_level = validate_level)
		
		## validate_params_pdtmvn may update some values that were passed in.
		## Assign those updated values to the corresponding variables in the
		## current environment.
		for(var_name in names(validated_params)) {
			assign(var_name, validated_params[[var_name]])
		}
		
		rm("validated_params")
	}
	
    ## in_support are row indices for observations in x_fixed in support
    if(!missing(x_fixed)) {
        in_support <- in_pdtmvn_support(x_fixed,
            lower = lower[names(x_fixed)],
            upper = upper[names(x_fixed)],
            continuous_vars,
            discrete_vars,
            discrete_var_range_functions)
        
        if(!in_support) {
            stop("provided value for x_fixed was not in the support of the distribution")
        }
    }
    
    ## simulate values to return.  There are 3 main steps:
    ## 1) Obtain a latent variable value w_fixed corresponding to x_fixed
    ##   (a) For continuous variables, w_fixed[i] = x_fixed[i]
    ##   (b) For discrete variables, w_fixed[i] are drawn from the joint
    ##     truncated multivariate normal distribution for the fixed discrete
    ##     variables given the fixed continuous variables.  Truncation points
    ##     are determined by lower/upper bounds for the distribution overall
    ##     and lower/upper bounds for the region corresponding to the
    ##     observed values in x_fixed
    ##  2) Simulate the corresponding values for the latent variable w_free
    ##    from the truncated multivariate normal conditional on w_fixed
    ##  3) Censor the values in w_free corresponding to discrete variables
    w <- matrix(NA, nrow = n, ncol = length(mean))
    colnames(w) <- names(mean)
    
    ## Step 1) is only relevant if x_fixed was provided
    if(!missing(x_fixed) && !is.null(x_fixed) && nrow(x_fixed) > 0) {
        w <- rpdtmvn_sample_w_fixed(n,
            w,
            x_fixed,
            fixed_vars,
            mean,
            sigma,
            precision,
            lower,
            upper,
            sigma_continuous,
            conditional_sigma_discrete,
            conditional_mean_discrete_offset_multiplier,
            continuous_vars,
            discrete_vars,
            discrete_var_range_functions,
            validate_level = TRUE)
    }
    
    ## Step 2) -- sample latent w_free
    w <- rpdtmvn_sample_w_free(n,
        w,
        x_fixed,
        fixed_vars,
        free_vars,
        mean,
        sigma,
        precision,
        lower,
        upper)
    
    ## Step 3) -- censor columns of w corresponding to discrete variables
    w <- rpdtmvn_discretize_w()
    
	## Return
    return(w)
}




#' Simulate observations from the latent TMVN distribution corresponding to
#' observations from a pdTMVN distribution.
#' 
#' @param n integer number of samples
#' @param w matrix with column names specified; the values are ignored.
#' @param x_fixed Vector or matrix of quantiles for variables to condition on.
#'   If x_fixed is a matrix, it should have one row.
#' @param fixed_vars Vector containing column indices for fixed variables.
#' @param mean Mean vector, default is rep(0, nrow(sigma)).
#' @param sigma Covariance matrix, default is diag(length(mean)).
#' @param precision Precision (inverse covariance) matrix.
#' @param lower Vector of lower truncation points, default is
#'   rep(-Inf, length = length(mean)).
#' @param upper Vector of upper truncation points, default is 
#'   rep(Inf, length = length(mean)).
#' @param continuous_vars Vector containing either column names or column
#'   indices for continuous variables.
#' @param discrete_vars Vector containing either column names or column indices
#'   for discrete variables.
#' @param discrete_var_range_functions a list with one entry for each element
#'   of discrete_vars.  Each entry is a named list with at least two elements:
#'   the element named "a" is a function that returns a(x) for any real x; the
#'   element named "b" is a function that returns b(x) for any real x.
#' 
#' @return matrix of values where columns corresponding to variables included in
#'   x_fixed are filled in with samples from the joint distribution of the
#'   corresponding latent TMVN distribution.  For continuous variables, these
#'   are the same as the values in x_fixed.  For discrete variables, these are
#'   samples from the regions that are integrated over to discretize those
#'   variables.
rpdtmvn_sample_w_fixed <- function(
    n,
    w,
    x_fixed,
    fixed_vars,
    mean,
    sigma,
    precision,
    lower,
    upper,
    continuous_vars,
    discrete_vars,
    discrete_var_range_functions) {
    
    fixed_continuous_vars <- fixed_vars[fixed_vars %in% continuous_vars]
    fixed_discrete_vars <- fixed_vars[fixed_vars %in% discrete_vars]
    
    ## Step 1) (a)
    w[, fixed_continuous_vars] <- rep(x_fixed[1, fixed_continuous_vars],
        each = n)
    
    ## Step 1) (b)
    lower_gen_w_fixed_disc <- sapply(
        fixed_discrete_vars,
        function(discrete_var_ind) {
            discrete_var_name <- colnames(x_fixed)[discrete_var_ind]
            do.call(discrete_var_range_functions[[discrete_var_name]][["a"]],
                list(x=x_fixed[1, discrete_var_name])
            )
        }
    )
    lower_gen_w_fixed_disc <- apply(rbind(lower, lower_gen_w_fixed_disc),
        2,
        max)
    
    upper_gen_w_fixed_disc <- sapply(
        which(colnames(x_fixed) %in% x_fixed_discrete_names),
        function(discrete_var_ind) {
            discrete_var_name <- colnames(x_fixed)[discrete_var_ind]
            do.call(discrete_var_range_functions[[discrete_var_name]][["b"]],
                list(x=x_fixed[1, discrete_var_name])
            )
        }
    )
    upper_gen_w_fixed_disc <- apply(rbind(upper, upper_gen_w_fixed_disc),
        2,
        max)
    
    temp <- get_conditional_mvn_params(x_fixed = x_fixed[, fixed_continuous_vars, drop = FALSE],
        mean = mean[fixed_vars],
        sigma = sigma[fixed_vars, fixed_vars, drop = FALSE],
        fixed_vars = which(fixed_vars %in% fixed_continuous_vars),
        free_vars = which(fixed_vars %in% fixed_discrete_vars))
    mean_gen_w_fixed_disc <- temp$conditional_mean
    sigma_gen_w_fixed_disc <- temp$conditional_sigma
    
    w[, x_fixed_discrete_names] <- tmvtnorm::rtmvnorm(n = n,
        mean = mean_gen_w_fixed_disc,
        sigma = sigma_gen_w_fixed_disc,
        lower = lower_gen_w_fixed_disc,
        upper = upper_gen_w_fixed_disc)
    
    return(w)
}

#' Simulate observations from the conditional distribution of a subset of
#' variables in a random vector jointly following a TMVN distribution given
#' observations of the other variables.
#' 
#' @param n integer number of samples
#' @param w matrix with column names specified with observations of some of the
#'   variables from a tmvn distribution.
#' @param x_fixed Vector or matrix of quantiles for variables to condition on.
#'   If x_fixed is a matrix, it should have one row.
#' @param fixed_vars Vector containing column indices for fixed variables.
#' @param free_vars Vector containing column indices for free variables.
#' @param mean Mean vector, default is rep(0, nrow(sigma)).
#' @param sigma Covariance matrix, default is diag(length(mean)).
#' @param precision Precision (inverse covariance) matrix.
#' @param lower Vector of lower truncation points, default is
#'   rep(-Inf, length = length(mean)).
#' @param upper Vector of upper truncation points, default is 
#'   rep(Inf, length = length(mean)).
#' 
#' @return matrix of values simulated from the TMVN distribution
rpdtmvn_sample_w_free <- function(
    n,
    w,
    x_fixed,
    fixed_vars,
    free_vars,
    mean,
    sigma,
    precision,
    lower,
    upper) {
    
    temp <- get_conditional_mvn_params(x_fixed = x_fixed,
        mean = mean,
        sigma = sigma,
        fixed_vars = fixed_vars,
        free_vars = free_vars)
    mean_w_free <- as.vector(temp$conditional_mean)
    sigma_w_free <- temp$conditional_sigma
    
    w[, free_vars] <- tmvtnorm::rtmvnorm(n = n,
        mean = mean_w_free,
        sigma = sigma_w_free,
        lower = lower[free_vars],
        upper = upper[free_vars])
    
    return(w)
}


#' Discretize observations from a TMVN distribution to obtain observations from
#' a pdTMVN distribution
#' 
#' @param w matrix with column names specified with observations of latent
#'   variables from a tmvn distribution.
#' @param discrete_vars Vector containing column indices for discrete variables.
#' @param discrete_var_range_functions a list with one entry for each element
#'   of discrete_vars.  Each entry is a named list which must contain an element
#'   named "discretizer", which is a function that takes continuous values and
#'   returns the corresponding discretized values.
#' 
#' @return matrix of values where columns corresponding to discrete variables
#'   have been discretized.
rpdtmvn_discretize_w <- function(w,
    discrete_vars,
    discrete_var_range_functions) {
    
    for(discrete_var in discrete_vars) {
        discrete_var_name <- colnames(w)[discrete_var]
        w[, discrete_var] <- do.call(
            discrete_var_range_functions[[discrete_var_name]][["discretizer"]],
            list(x=w[, discrete_var])
        )
    }
}