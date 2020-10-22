#' @export
fit_pois = function(z,
                    r = max(z),
                    solver = "global",
                    method = "glmnet",
                    alpha = 1,
                    use_parallel = F,
                    ncores = 7,
                    symmetrize=TRUE,
                    which_lambda = "lambda.min") {

  if (use_parallel) {
    if (requireNamespace("doParallel", quietly = TRUE)) {
      doParallel::registerDoParallel(ncores)
    } else {
      stop("doParallel package is needed to use_parallel.")
    }
  }

  ptime = proc.time()
  cat(sprintf('POIS: %s, %s %s ... ', solver, method,
              ifelse(method == "glmnet", sprintf("(%s)", which_lambda), "")))
  if (solver == "global") {
    # cat(sprintf('global: %s ... (%s) \n', method, which_lambda))
    z <- as.matrix(z)
    d <- ncol(z) # dim(z)[2]
    n <- nrow(z)
    gamh <- matrix(0,d,d)
    beth <- matrix(0,d,r)

    sig <- z2sig(z)
    for (i in 1:d) {
      Zi <-  diag(r+1)[z[,i]+1,]
      y = 1-Zi[,1]
      x = sig[,-i]
      if (method == "glmnet") {
        # require(glmnet)
        fit <- glmnet::cv.glmnet(x, y, family = "binomial",
                         standardize=F, alpha=alpha, parallel=use_parallel)
        b = as.vector( coef(fit, s = which_lambda) )
      } else if (method == "firth") {
        # require(logistf)
        x <- as.matrix(x)
        fit <- logistf::logistf(y ~ x, firth=TRUE)
        b <- as.vector(coef(fit))
      } else if (method == "bayesglm") {
        # require(arm)
        x <- as.matrix(x)
        fit <- arm::bayesglm(y ~ x, family = binomial)
        b <- fit$coefficients
      } else {
        stop('Unrecognized method. Choose either "glmnet" or "firth" or "bayesglm".')
      }

      gamh[i,-i] <- b[-1]/(-2)
      temp <- colSums(Zi[,-1])
      beth[i,] <- exp(b[1]) * temp / sum(temp)
    }
    if (symmetrize) gamh <- (gamh + t(gamh))/2
    theta = log(beth)
    # list(theta = log(beth), gamh=gamh)

  } else if (solver == "coord") {
    z <- as.matrix(z)
    d <- ncol(z) # dim(z)[2]
    gamh <- gam_estim(z, r, method = method, alpha = alpha,
                      use_parallel = use_parallel,
                      which_lambda = which_lambda)
    theta <- theta_estim(z, gamh, r)

  } else {
    stop('Unrecognized solver. Choose either "global" or "coord".')
  }

  dt = proc.time() - ptime
  cat(sprintf('%3.3f (s).\n', dt["elapsed"]))

  list(theta = theta, gam = gamh)
}

# glmnet on CV -----------------------------------------------------------
#' @export
fit_pois_glmnet_mmdcv = function(z,
                                r = max(z),
                                train_ratio = 0.7,
                                nlam = 12,
                                lambda = 10^seq(-4,-1.3, length.out = nlam),
                                nreps = 2,
                                agg_func = mean,
                                alpha = 1,
                                use_parallel = F,
                                ncores = 7,
                                symmetrize=TRUE) {

  n = nrow(z)
  nlam = length(lambda)
  mmd_res = rep(0, nlam) # vector("double", nlam)
  printf('--- Starting CV ---\n', r)
  for (r in 1:nreps) {
    printf('Rep %d/%d ... \n', r, nreps)
    row_idx = sample(n, round(train_ratio*n)) # training set

    mods = fit_pois_glmnet_nocv(z[row_idx, ],
                                nlam = nlam,
                                lambda = lambda,
                                alpha = alpha,
                                use_parallel = use_parallel,
                                ncores = ncores,
                                symmetrize = symmetrize)

    # n_mods = length(mods)
    X = z[-row_idx, ] # validation set
    for (i in 1:nlam) {
      printf('lam = %3.2e  ', lambda[i])
      Y = sample_pois(100, mods[[i]]$theta, mods[[i]]$gamh, burn_in = 5000, spacing = 100, verb = F)
      mmd_res[i] = mmd_res[i] +
        mean(pair_complement_mmd(X, Y, agg_func = agg_func, max_npairs = 200))
    }
  }
  reg_curve = mmd_res / nreps
  opt_idx = which.min(reg_curve)
  opt_lambda = lambda[opt_idx]
  printf('--- End of CV --- Chose lam = 3.2f\n', opt_lambda)

  # fitting the final model
  printf('Fitting the final model ... \n')
  mods = fit_pois_glmnet_nocv(z,
                              nlam = nlam,
                              lambda = lambda, # use all lambdas to help the warm-up
                              alpha = alpha,
                              use_parallel = use_parallel,
                              ncores = ncores,
                              symmetrize = symmetrize)

  list(lambda = lambda, reg_curve = mmd_res, models = mods,
       opt_idx = opt_idx, opt_lambda = opt_lambda)
  # reg_curve = sapply(mmd_res, mean)
}

#' @export
fit_pois_glmnet_nocv = function(z,
                                r = max(z),
                                nlam = 12,
                                lambda = 10^seq(-4,-1.3, length.out = nlam),
                                alpha = 1,
                                use_parallel = F,
                                ncores = 7,
                                symmetrize=TRUE) {

  if (use_parallel) {
    if (requireNamespace("doParallel", quietly = TRUE)) {
      doParallel::registerDoParallel(ncores)
    } else {
      stop("doParallel package is needed to use_parallel.")
    }
  }

  ptime = proc.time()
  cat('POIS: glment, global, nocv ... ')

  z <- as.matrix(z)
  d <- ncol(z) # dim(z)[2]
  n <- nrow(z)
  nlam <- length(lambda)
  models = lapply(1:nlam, function(i) list(gamh = matrix(0,d,d),
                                           beth = matrix(0,d,r),
                                           theta = matrix(0,d,r)))
  # models = lapply(1:3, function(i) list(gamh = matrix(0,4,4),  beth = matrix(0,4,5)))

  sig <- z2sig(z)
  for (i in 1:d) {
    Zi <-  diag(r+1)[z[,i]+1,]
    y = 1-Zi[,1]
    x = sig[,-i]
    fit <- glmnet::glmnet(x, y, family = "binomial", lambda = lambda,
                          standardize = F, alpha = 1, parallel = use_parallel)
    # fit <- glmnet::cv.glmnet(x, y, family = "binomial",
    #                          standardize=F, alpha=alpha, parallel=use_parallel)
    # print(dim(coef(fit)))
    temp <- colSums(Zi[,-1])
    for (li in 1:nlam) {
      # b = as.vector( coef(fit)[, li] )
      b = as.vector( coef(fit, s = lambda[li]) )
      models[[li]]$gamh[i,-i] <- b[-1]/(-2)
      models[[li]]$beth[i,] <- exp(b[1]) * temp / sum(temp)
    }
  }

  for (li in 1:nlam) {
    if (symmetrize) models[[li]]$gamh <- symmetrize_matrix(models[[li]]$gamh)
    models[[li]]$theta = log(models[[li]]$beth)
    models[[li]]$beth = NULL
  }

  dt = proc.time() - ptime
  cat(sprintf('%3.3f (s).\n', dt["elapsed"]))

  if (nlam == 1) return(models[[1]])

  return(models)
}


z2sig <- function(z) 2*(z == 0)-1

theta_estim <- function(data, gamma=NULL, r){
  n <- dim(data)[1]
  d <- dim(data)[2]
  theta_hat <- mat.or.vec(d,r)

  # a = z2sig(data) %*% gamma
  sig <- z2sig(data)
  for (i in 1:d) {
    n0 <- sum(data[,i]==0)
    if (is.null(gamma)) {
      C <- n0
    } else {
      a <- sig[, -i] %*% gamma[i, -i]
      C <- bisection_betaestim(0, 50000, 200, n, n0, a)$midpoint
    }
    for (k in 1:r){
      theta_hat[i,k] = log(sum(data[,i]==k)/C)
      #theta_hat[i,k] = log(sum(data[,i]==k)/n0)
    }
  }
  return(theta_hat)
}

gam_estim <- function(data, r, method, alpha = alpha,
                      use_parallel = use_parallel,
                      which_lambda = which_lambda) {
  n = dim(data)[1]
  d = dim(data)[2]
  fit = NULL
  # coeff = c()
  theta_init = mat.or.vec(d,r)
  gamh <- matrix(0,d,d)

  # cat(sprintf('coordinate descent: %s ... (fixed intercept)\n',method))
  for(i in 1:d) {
    # print(i)
    y = (data[,i]!=0)*1
    x = 2*(data[,-i]==0)-1
    # dat = as.data.frame(cbind(y,x))
    # dat = data.frame(y=y,x=x)
    n0 = sum(data[,i]==0)
    for (k in 1:r){
      theta_init[i,k] = log(sum(data[,i]==k)/n0)
    }
    b0 = log(sum(exp(theta_init[i,])))
    # dat$b0 <- b0
    # colnames(dat) <- c(1:d,"b0")
    if (method == "glmnet") {
      # require(glmnet)
      fit <- glmnet::cv.glmnet(x, y, offset=rep(b0,n), intercept=F,
                       family = "binomial", standardize=F,
                       alpha=alpha, parallel = use_parallel)
      b = as.vector( coef(fit, s = which_lambda) )
      # print(b)
      # plot(fit)
      gamh[i,-i] <- -b[-1]/2
    } else if (method == "firth") {
      # require(logistf)
      x <- as.matrix(x)
      # fit <- logistf(y~x-1+offset(b0), dat, firth=TRUE)
      fit <- logistf::logistf(y~x-1+offset(rep(b0,n)), firth=TRUE)
      b <- fit$coefficients
      gamh[i,-i] <- -b/2
    } else if (method == "bayesglm") {
      # require(arm)
      x <- as.matrix(x)
      # fit <- bayesglm(y ~ x-1+offset(b0), dat, family = binomial)
      fit <- arm::bayesglm(y ~ x-1+offset(rep(b0,n)), family = binomial)
      #       #fit <- logistf(b ~ . ,data=df, firth=TRUE)
      b <- fit$coefficients
      gamh[i,-i] <- -b/2
    } else {
      stop('Unrecognized method. Choose either "glmnet" or "firth" or "bayesglm".')
    }
  }

  gam_estim <- (gamh + t(gamh))/2
  colnames(gam_estim) = colnames(data)
  return(gam_estim)
  # colnames(gamh) = colnames(data)
  # return(gamh)
}

bisection_betaestim = function(a,b,max_iter,n,n0,s){
  f <-  function(x) sum(exp(-2*s)/(x+t)) - 1
  ndiff = n-n0
  t= ndiff*exp(-2*s)
  xa=a
  xb=b
  for(i in 1:max_iter){
    if(f(xa)*f((xa+xb)/2)< 0) {xb=(xa+xb)/2
    } else {
      xa=(xa+xb)/2
    }
  }
  list(left=xa,right=xb, midpoint=(xa+xb)/2)
}

