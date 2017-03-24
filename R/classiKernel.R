#' Create a kernel estimator for functional data classification
#'
#' @description Creates an efficient kernel estimator for functional data
#' classification. Currently
#' supported distance measures are all \code{metrics} implemented in \code{\link[proxy]{dist}}
#' and all semimetrics suggested in
#' Fuchs et al. 2015, Nearest neighbor ensembles for functional data with
#' interpretable feature selection,
#' (\url{http://www.sciencedirect.com/science/article/pii/S0169743915001100})
#' Additionally, all (semi-)metrics can be used on an arbitrary order of derivation.
#' For kernel functions all kernels implemented in \code{\link[fda.usc]{fda.usc}}
#' are admissible as well as custom kernel functions.
#'
#' @inheritParams classiKnn
#' @param h [numeric(1)]\cr
#'     the bandwidth of the kernel function. All kernel functions \code{K} must be
#'     implemented to have bandwidth = 1. The bandwidth is controlled via \code{K(x/h)}.
#' @param ker [numeric(1)]\cr
#'     character describing the kernel function to use. Admissible are
#'     amongst others all kernel functions from \code{\link[fda.usc]{Kernel}}.
#'     For the full list execute \code{\link{ker.choices}}.
#'     The usage of customized kernel function is symbolized by
#'     \code{ker = "custom.ker"}. The customized function can be specified in
#'     \code{custom.ker}
#' @param custom.ker [function(u)]\cr
#'     customized kernel function. This has to a function with exactly one parameter
#'     \code{u}. This function is only used if \code{ker == "custom.ker"}.
#'
#' @importFrom fda.usc Ker.norm Ker.cos Ker.epa Ker.tri Ker.quar Ker.unif
#' AKer.norm AKer.cos AKer.epa AKer.tri AKer.quar AKer.unif
#' @importFrom stats aggregate dnorm
#'
#' @examples
#' # How to implement your own kernel function
#' data("ArrowHead")
#' classes = ArrowHead[,"target"]
#'
#' set.seed(123)
#' train_inds = sample(1:nrow(ArrowHead), size = 0.8 * nrow(ArrowHead), replace = FALSE)
#' test_inds = (1:nrow(ArrowHead))[!(1:nrow(ArrowHead)) %in% train_inds]
#'
#' ArrowHead = ArrowHead[,!colnames(ArrowHead) == "target"]
#'
#' # custom kernel
#' myTriangularKernel = function(u) {
#'   return((1 - abs(u)) * (abs(u) < 1))
#' }
#'
#' # create the models
#' mod1 = classiKernel(classes = classes[train_inds], fdata = ArrowHead[train_inds,],
#'                     ker = "custom.ker", h = 2, custom.ker = myTriangularKernel)
#'
#' # calculate the model predictions
#' pred1 = predict(mod1, newdata = ArrowHead[test_inds,], predict.type = "response")
#'
#' # prediction accuracy
#' mean(pred1 == classes[test_inds])
#' @export
classiKernel = function(classes, fdata, grid = 1:ncol(fdata), h = 1,
                        metric = "Euclidean", ker = "Ker.norm",
                        nderiv = 0L, derived = FALSE,
                        deriv.method = "base.diff",
                        custom.metric = function(x, y, ...) {
                          return(sqrt(sum((x - y)^2)))},
                        custom.ker = function(u) {
                          return(dnorm(u))
                        },
                        ...) {
  # check inputs
  if(class(fdata) == "data.frame")
    fdata = as.matrix(fdata)
  assert_numeric(fdata)
  assertClass(fdata, "matrix")

  if(is.numeric(classes))
    classes = factor(classes)
  assertFactor(classes, any.missing = FALSE, len = nrow(fdata))
  assertNumeric(grid, any.missing = FALSE, len = ncol(fdata))
  assertNumeric(h, lower = 0, len = 1L)
  assertIntegerish(nderiv, lower = 0L)
  assertFlag(derived)
  assertChoice(deriv.method, c("base.diff", "fda.deriv.fd"))
  assertChoice(ker, choices = ker.choices())
  assertChoice(metric, choices = metric.choices())


  # check if data is evenly spaced  -> respace
  evenly.spaced = all.equal(grid, seq(grid[1], grid[length(grid)], length.out = length(grid)))
  no.missing = !checkmate::anyMissing(fdata)

  # TODO write better warning message
  if(!no.missing) {
    warning("There are missing values in fdata. They will be filled using a spline representation!")
  }

  # create a model specific preprocessing function for the data
  # here the data will be derived, respaced equally and missing values will be filled
  this.fdataTransform = fdataTransform(fdata = fdata, grid = grid,
                                       nderiv = nderiv, derived = derived,
                                       evenly.spaced = evenly.spaced,
                                       no.missing = no.missing,
                                       deriv.method = deriv.method, ...)
  proc.fdata = this.fdataTransform(fdata)

  # delete the custom.metric function from output if not needed
  if (metric != "custom.metric")
    custom.metric = character(0)
  if (ker != "custom.ker")
    custom.ker = character(0)

  ret = list(classes = classes,
             fdata = fdata,
             proc.fdata = proc.fdata,
             grid = grid,
             h = h,
             metric = metric,
             ker = ker,
             custom.metric = custom.metric,
             custom.ker = custom.ker,
             nderiv = nderiv,
             this.fdataTransform = this.fdataTransform,
             call = as.list(match.call(expand.dots = FALSE)))
  class(ret) = "classiKernel"

  return(ret)
}


#' @export
predict.classiKernel = function(object, newdata = NULL, predict.type = "response", ...) {
  # input checking
  if(!is.null(newdata)) {
    if(class(newdata) == "data.frame")
      newdata = as.matrix(newdata)
    assertClass(newdata, "matrix")
    newdata = object$this.fdataTransform(newdata)
  }
  assertChoice(predict.type, c("response", "prob"))

  # create distance metric
  # note, that additional arguments from the original model are handed over
  # to computeDistMat using object$call$...
  dist.mat = do.call("computeDistMat", c(list(x = object$proc.fdata, y = newdata,
                                              method = object$metric,
                                              custom.metric = object$custom.metric, ...),
                                         object$call$...))
  # apply kernel function
  if(object$ker == "custom.ker") {
    this.ker = object$custom.ker
  } else {
    this.ker = object$ker
  }

  # Apply distance function after dividing by bandwidth
  dist.kernel = apply(dist.mat / object$h, c(1,2), this.ker)

  raw.result = aggregate(dist.kernel, by = list(classes = object$classes), sum, drop = FALSE)

  if (predict.type == "response") {
    # return class with highest probability
    if(ncol(dist.mat) == 1L) { # exactly one observation in newdata
      result = raw.result$classes[which.max(raw.result[,-1])]
    } else {
      result = raw.result$classes[apply(raw.result[,-1], 2, which.max)]
    }
  } else  if (predict.type == "prob") {
    # probabilities for the classes
    if(ncol(dist.mat) == 1L) { # exactly one observation in newdata
      result = raw.result[,-1] / sum(raw.result[,-1])
      names(result) = raw.result$classes
    } else {
      result = t(apply(raw.result[,-1], 2, function(x) {
        if(sum(x) > 0) x / sum(x)
        else rep(1 / length(x), length(x)) # if all ker(dist(x,y)) == 0
      }))
      colnames(result) = raw.result$classes
    }
  }
  return(result)
}

