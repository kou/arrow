# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

#' @include expression.R
#' @include record-batch.R
#' @include table.R

arrow_dplyr_query <- function(.data) {
  # An arrow_dplyr_query is a container for an Arrow data object (Table,
  # RecordBatch, or Dataset) and the state of the user's dplyr query--things
  # like selected columns, filters, and group vars.

  # For most dplyr methods,
  # method.Table == method.RecordBatch == method.Dataset == method.arrow_dplyr_query
  # This works because the functions all pass .data through arrow_dplyr_query()
  if (inherits(.data, "arrow_dplyr_query")) {
    return(.data)
  }
  structure(
    list(
      .data = .data$clone(),
      # selected_columns is a named list:
      # * contents are references/expressions pointing to the data
      # * names are the names they should be in the end (i.e. this
      #   records any renaming)
      selected_columns = make_field_refs(names(.data), dataset = inherits(.data, "Dataset")),
      # filtered_rows will be an Expression
      filtered_rows = TRUE,
      # group_by_vars is a character vector of columns (as renamed)
      # in the data. They will be kept when data is pulled into R.
      group_by_vars = character()
    ),
    class = "arrow_dplyr_query"
  )
}

#' @export
print.arrow_dplyr_query <- function(x, ...) {
  schm <- x$.data$schema
  cols <- get_field_names(x)
  # If cols are expressions, they won't be in the schema and will be "" in cols
  fields <- map_chr(cols, function(name) {
    if (nzchar(name)) {
      schm$GetFieldByName(name)$ToString()
    } else {
      "expr"
    }
  })
  # Strip off the field names as they are in the dataset and add the renamed ones
  fields <- paste(names(cols), sub("^.*?: ", "", fields), sep = ": ", collapse = "\n")
  cat(class(x$.data)[1], " (query)\n", sep = "")
  cat(fields, "\n", sep = "")
  cat("\n")
  if (!isTRUE(x$filtered_rows)) {
    if (query_on_dataset(x)) {
      filter_string <- x$filtered_rows$ToString()
    } else {
      filter_string <- .format_array_expression(x$filtered_rows)
    }
    cat("* Filter: ", filter_string, "\n", sep = "")
  }
  if (length(x$group_by_vars)) {
    cat("* Grouped by ", paste(x$group_by_vars, collapse = ", "), "\n", sep = "")
  }
  cat("See $.data for the source Arrow object\n")
  invisible(x)
}

get_field_names <- function(selected_cols) {
  if (inherits(selected_cols, "arrow_dplyr_query")) {
    selected_cols <- selected_cols$selected_columns
  }
  map_chr(selected_cols, function(x) {
    if (inherits(x, "Expression")) {
      out <- x$field_name
    } else if (inherits(x, "array_expression")) {
      out <- x$args$field_name
    } else {
      out <- NULL
    }
    # If x isn't some kind of field reference, out is NULL,
    # but we always need to return a string
    out %||% ""
  })
}

make_field_refs <- function(field_names, dataset = TRUE) {
  if (dataset) {
    out <- lapply(field_names, Expression$field_ref)
  } else {
    out <- lapply(field_names, function(x) array_expression("array_ref", field_name = x))
  }
  set_names(out, field_names)
}

# These are the names reflecting all select/rename, not what is in Arrow
#' @export
names.arrow_dplyr_query <- function(x) names(x$selected_columns)

#' @export
dim.arrow_dplyr_query <- function(x) {
  cols <- length(names(x))

  if (isTRUE(x$filtered)) {
    rows <- x$.data$num_rows
  } else if (query_on_dataset(x)) {
    warning("Number of rows unknown; returning NA", call. = FALSE)
    # TODO: https://issues.apache.org/jira/browse/ARROW-9697
    rows <- NA_integer_
  } else {
    # Evaluate the filter expression to a BooleanArray and count
    rows <- as.integer(sum(eval_array_expression(x$filtered_rows, x$.data), na.rm = TRUE))
  }
  c(rows, cols)
}

#' @export
as.data.frame.arrow_dplyr_query <- function(x, row.names = NULL, optional = FALSE, ...) {
  collect.arrow_dplyr_query(x, as_data_frame = TRUE, ...)
}

#' @export
head.arrow_dplyr_query <- function(x, n = 6L, ...) {
  if (query_on_dataset(x)) {
    head.Dataset(x, n, ...)
  } else {
    out <- collect.arrow_dplyr_query(x, as_data_frame = FALSE)
    if (inherits(out, "arrow_dplyr_query")) {
      out$.data <- head(out$.data, n)
    } else {
      out <- head(out, n)
    }
    out
  }
}

#' @export
tail.arrow_dplyr_query <- function(x, n = 6L, ...) {
  if (query_on_dataset(x)) {
    tail.Dataset(x, n, ...)
  } else {
    out <- collect.arrow_dplyr_query(x, as_data_frame = FALSE)
    if (inherits(out, "arrow_dplyr_query")) {
      out$.data <- tail(out$.data, n)
    } else {
      out <- tail(out, n)
    }
    out
  }
}

#' @export
`[.arrow_dplyr_query` <- function(x, i, j, ..., drop = FALSE) {
  if (query_on_dataset(x)) {
    `[.Dataset`(x, i, j, ..., drop = FALSE)
  } else {
    stop(
      "[ method not implemented for queries. Call 'collect(x, as_data_frame = FALSE)' first",
      call. = FALSE
    )
  }
}

# The following S3 methods are registered on load if dplyr is present
tbl_vars.arrow_dplyr_query <- function(x) names(x$selected_columns)

select.arrow_dplyr_query <- function(.data, ...) {
  column_select(arrow_dplyr_query(.data), !!!enquos(...))
}
select.Dataset <- select.ArrowTabular <- select.arrow_dplyr_query

#' @importFrom tidyselect vars_rename
rename.arrow_dplyr_query <- function(.data, ...) {
  column_select(arrow_dplyr_query(.data), !!!enquos(...), .FUN = vars_rename)
}
rename.Dataset <- rename.ArrowTabular <- rename.arrow_dplyr_query

column_select <- function(.data, ..., .FUN = vars_select) {
  # .FUN is either tidyselect::vars_select or tidyselect::vars_rename
  # It operates on the names() of selected_columns, i.e. the column names
  # factoring in any renaming that may already have happened
  out <- .FUN(names(.data), !!!enquos(...))
  # Make sure that the resulting selected columns map back to the original data,
  # as in when there are multiple renaming steps
  .data$selected_columns <- set_names(.data$selected_columns[out], names(out))

  # If we've renamed columns, we need to project that renaming into other
  # query parameters we've collected
  renamed <- out[names(out) != out]
  if (length(renamed)) {
    # Massage group_by
    gbv <- .data$group_by_vars
    renamed_groups <- gbv %in% renamed
    gbv[renamed_groups] <- names(renamed)[match(gbv[renamed_groups], renamed)]
    .data$group_by_vars <- gbv
    # No need to massage filters because those contain references to Arrow objects
  }
  .data
}

filter.arrow_dplyr_query <- function(.data, ..., .preserve = FALSE) {
  # TODO something with the .preserve argument
  filts <- quos(...)
  if (length(filts) == 0) {
    # Nothing to do
    return(.data)
  }

  .data <- arrow_dplyr_query(.data)
  # tidy-eval the filter expressions inside an Arrow data_mask
  filters <- lapply(filts, arrow_eval, arrow_mask(.data))
  bad_filters <- map_lgl(filters, ~inherits(., "try-error"))
  if (any(bad_filters)) {
    bads <- oxford_paste(map_chr(filts, as_label)[bad_filters], quote = FALSE)
    if (query_on_dataset(.data)) {
      # Abort. We don't want to auto-collect if this is a Dataset because that
      # could blow up, too big.
      stop(
        "Filter expression not supported for Arrow Datasets: ", bads,
        "\nCall collect() first to pull data into R.",
        call. = FALSE
      )
    } else {
      # TODO: only show this in some debug mode?
      warning(
        "Filter expression not implemented in Arrow: ", bads, "; pulling data into R",
        immediate. = TRUE,
        call. = FALSE
      )
      # Set any valid filters first, then collect and then apply the invalid ones in R
      .data <- set_filters(.data, filters[!bad_filters])
      return(dplyr::filter(dplyr::collect(.data), !!!filts[bad_filters]))
    }
  }

  set_filters(.data, filters)
}
filter.Dataset <- filter.ArrowTabular <- filter.arrow_dplyr_query

arrow_eval <- function (expr, mask) {
  # filter(), mutate(), etc. work by evaluating the quoted `exprs` to generate Expressions
  # with references to Arrays (if .data is Table/RecordBatch) or Fields (if
  # .data is a Dataset).

  # This yields an Expression as long as the `exprs` are implemented in Arrow.
  # Otherwise, it returns a try-error
  tryCatch(eval_tidy(expr, mask), error = function(e) {
    # Look for the cases where bad input was given, i.e. this would fail
    # in regular dplyr anyway, and let those raise those as errors;
    # else, for things not supported by Arrow return a "try-error",
    # which we'll handle differently
    msg <- conditionMessage(e)
    # TODO(ARROW-11700): internationalization
    if (grepl("object '.*'.not.found", msg)) {
      stop(e)
    }
    if (grepl('could not find function ".*"', msg)) {
      stop(e)
    }
    invisible(structure(msg, class = "try-error", condition = e))
  })
}

# Helper to assemble the functions that go in the NSE data mask
# The only difference between the Dataset and the Table/RecordBatch versions
# is that they use a different wrapping function (FUN) to hold the unevaluated
# expression.
build_function_list <- function(FUN) {
  wrapper <- function(operator) {
    force(operator)
    function(...) FUN(operator, ...)
  }
  all_arrow_funs <- list_compute_functions()

  c(
    # Include mappings from R function name spellings
    lapply(set_names(names(.array_function_map)), wrapper),
    # Plus some special handling where it's not 1:1
    str_trim = function(string, side = c("both", "left", "right")) {
      side <- match.arg(side)
      switch(
        side,
        left = FUN("utf8_ltrim_whitespace", string),
        right = FUN("utf8_rtrim_whitespace", string),
        both = FUN("utf8_trim_whitespace", string)
      )
    },
    between = function(x, left, right) {
      x >= left & x <= right
    },
    # Now also include all available Arrow Compute functions,
    # namespaced as arrow_fun
    set_names(
      lapply(all_arrow_funs, wrapper),
      paste0("arrow_", all_arrow_funs)
    )
  )
}

# We'll populate these at package load time.
dplyr_functions <- NULL
init_env <- function () {
  dplyr_functions <<- new.env(hash = TRUE)
}
init_env()

# Create a data mask for evaluating a dplyr expression
arrow_mask <- function(.data) {
  if (query_on_dataset(.data)) {
    f_env <- new_environment(dplyr_functions$dataset)
  } else {
    f_env <- new_environment(dplyr_functions$array)
  }

  # Add functions that need to error hard and clear.
  # Some R functions will still try to evaluate on an Expression
  # and return NA with a warning
  fail <- function(...) stop("Not implemented")
  for (f in c("mean")) {
    f_env[[f]] <- fail
  }

  # Add the column references and make the mask
  out <- new_data_mask(
    new_environment(.data$selected_columns, parent = f_env),
    f_env
  )
  # Then insert the data pronoun
  # TODO: figure out what rlang::as_data_pronoun does/why we should use it
  # (because if we do we get `Error: Can't modify the data pronoun` in mutate())
  out$.data <- .data$selected_columns
  out
}

set_filters <- function(.data, expressions) {
  # expressions is a list of Expressions. AND them together and set them on .data
  new_filter <- Reduce("&", expressions)
  if (isTRUE(.data$filtered_rows)) {
    # TRUE is default (i.e. no filter yet), so we don't need to & with it
    .data$filtered_rows <- new_filter
  } else {
    .data$filtered_rows <- .data$filtered_rows & new_filter
  }
  .data
}

collect.arrow_dplyr_query <- function(x, as_data_frame = TRUE, ...) {
  x <- ensure_group_vars(x)
  # Pull only the selected rows and cols into R
  if (query_on_dataset(x)) {
    # See dataset.R for Dataset and Scanner(Builder) classes
    tab <- Scanner$create(x)$ToTable()
  } else {
    # This is a Table or RecordBatch

    # Filter and select the data referenced in selected columns
    if (isTRUE(x$filtered_rows)) {
      filter <- TRUE
    } else {
      filter <- eval_array_expression(x$filtered_rows, x$.data)
    }
    # TODO: shortcut if identical(names(x$.data), find_array_refs(x$selected_columns))?
    tab <- x$.data[filter, find_array_refs(x$selected_columns), keep_na = FALSE]
    # Now evaluate those expressions on the filtered table
    cols <- lapply(x$selected_columns, eval_array_expression, data = tab)
    if (length(cols) == 0) {
      tab <- tab[, integer(0)]
    } else {
      if (inherits(x$.data, "Table")) {
        tab <- Table$create(!!!cols)
      } else {
        tab <- RecordBatch$create(!!!cols)
      }
    }
  }
  if (as_data_frame) {
    df <- as.data.frame(tab)
    tab$invalidate()
    restore_dplyr_features(df, x)
  } else {
    restore_dplyr_features(tab, x)
  }
}
collect.ArrowTabular <- as.data.frame.ArrowTabular
collect.Dataset <- function(x, ...) dplyr::collect(arrow_dplyr_query(x), ...)

#' @importFrom rlang .data
ensure_group_vars <- function(x) {
  if (inherits(x, "arrow_dplyr_query")) {
    # Before pulling data from Arrow, make sure all group vars are in the projection
    gv <- set_names(setdiff(dplyr::group_vars(x), names(x)))
    if (length(gv)) {
      # Add them back
      x$selected_columns <- c(
        x$selected_columns,
        make_field_refs(gv, dataset = query_on_dataset(.data))
      )
    }
  }
  x
}

restore_dplyr_features <- function(df, query) {
  # An arrow_dplyr_query holds some attributes that Arrow doesn't know about
  # After calling collect(), make sure these features are carried over

  grouped <- length(query$group_by_vars) > 0
  renamed <- ncol(df) && !identical(names(df), names(query))
  if (renamed) {
    # In case variables were renamed, apply those names
    names(df) <- names(query)
  }
  if (grouped) {
    # Preserve groupings, if present
    if (is.data.frame(df)) {
      df <- dplyr::grouped_df(df, dplyr::group_vars(query))
    } else {
      # This is a Table, via collect(as_data_frame = FALSE)
      df <- arrow_dplyr_query(df)
      df$group_by_vars <- query$group_by_vars
    }
  }
  df
}

#' @importFrom tidyselect vars_pull
pull.arrow_dplyr_query <- function(.data, var = -1) {
  .data <- arrow_dplyr_query(.data)
  var <- vars_pull(names(.data), !!enquo(var))
  .data$selected_columns <- set_names(.data$selected_columns[var], var)
  dplyr::collect(.data)[[1]]
}
pull.Dataset <- pull.ArrowTabular <- pull.arrow_dplyr_query

summarise.arrow_dplyr_query <- function(.data, ...) {
  .data <- arrow_dplyr_query(.data)
  if (query_on_dataset(.data)) {
    not_implemented_for_dataset("summarize()")
  }
  # Only retain the columns we need to do our aggregations
  vars_to_keep <- unique(c(
    unlist(lapply(quos(...), all.vars)), # vars referenced in summarise
    dplyr::group_vars(.data)             # vars needed for grouping
  ))
  .data <- dplyr::select(.data, vars_to_keep)
  # TODO: determine whether work can be pushed down to Arrow
  dplyr::summarise(dplyr::collect(.data), ...)
}
summarise.Dataset <- summarise.ArrowTabular <- summarise.arrow_dplyr_query

group_by.arrow_dplyr_query <- function(.data,
                                       ...,
                                       .add = FALSE,
                                       add = .add,
                                       .drop = TRUE) {
  if (!isTRUE(.drop)) {
    stop(".drop argument not supported for Arrow objects", call. = FALSE)
  }
  .data <- arrow_dplyr_query(.data)
  # ... can contain expressions (i.e. can add (or rename?) columns)
  # Check for those (they show up as named expressions)
  new_groups <- enquos(...)
  new_groups <- new_groups[nzchar(names(new_groups))]
  if (length(new_groups)) {
    # TODO(ARROW-11658): either find a way to let group_by_prepare handle this
    # (it may call mutate() for us)
    # or essentially reimplement it here (see dplyr:::add_computed_columns)
    stop("Cannot create or rename columns in group_by on Arrow objects", call. = FALSE)
  }
  if (".add" %in% names(formals(dplyr::group_by))) {
    # dplyr >= 1.0
    gv <- dplyr::group_by_prepare(.data, ..., .add = .add)$group_names
  } else {
    gv <- dplyr::group_by_prepare(.data, ..., add = add)$group_names
  }
  .data$group_by_vars <- gv
  .data
}
group_by.Dataset <- group_by.ArrowTabular <- group_by.arrow_dplyr_query

groups.arrow_dplyr_query <- function(x) syms(dplyr::group_vars(x))
groups.Dataset <- groups.ArrowTabular <- function(x) NULL

group_vars.arrow_dplyr_query <- function(x) x$group_by_vars
group_vars.Dataset <- group_vars.ArrowTabular <- function(x) NULL

ungroup.arrow_dplyr_query <- function(x, ...) {
  x$group_by_vars <- character()
  x
}
ungroup.Dataset <- ungroup.ArrowTabular <- force

mutate.arrow_dplyr_query <- function(.data,
                                     ...,
                                     .keep = c("all", "used", "unused", "none"),
                                     .before = NULL,
                                     .after = NULL) {
  call <- match.call()
  exprs <- quos(...)

  .keep <- match.arg(.keep)
  .before <- enquo(.before)
  .after <- enquo(.after)

  if (.keep %in% c("all", "unused") && length(exprs) == 0) {
    # Nothing to do
    return(.data)
  }

  .data <- arrow_dplyr_query(.data)

  # Restrict the cases we support for now
  if (!quo_is_null(.before) || !quo_is_null(.after)) {
    # TODO(ARROW-11701)
    return(abandon_ship(call, .data, '.before and .after arguments are not supported in Arrow'))
  } else if (length(dplyr::group_vars(.data)) > 0) {
    # mutate() on a grouped dataset does calculations within groups
    # This doesn't matter on scalar ops (arithmetic etc.) but it does
    # for things with aggregations (e.g. subtracting the mean)
    return(abandon_ship(call, .data, 'mutate() on grouped data not supported in Arrow'))
  }

  # Check for unnamed expressions and fix if any
  unnamed <- !nzchar(names(exprs))
  # Deparse and take the first element in case they're long expressions
  names(exprs)[unnamed] <- map_chr(exprs[unnamed], as_label)

  is_dataset <- query_on_dataset(.data)
  mask <- arrow_mask(.data)
  results <- list()
  for (i in seq_along(exprs)) {
    # Iterate over the indices and not the names because names may be repeated
    # (which overwrites the previous name)
    new_var <- names(exprs)[i]
    results[[new_var]] <- arrow_eval(exprs[[i]], mask)
    if (inherits(results[[new_var]], "try-error")) {
      msg <- paste('Expression', as_label(exprs[[i]]), 'not supported in Arrow')
      return(abandon_ship(call, .data, msg))
    } else if (is_dataset &&
               !inherits(results[[new_var]], "Expression") &&
               !is.null(results[[new_var]])) {
      # We need some wrapping to handle literal values
      if (length(results[[new_var]]) != 1) {
        msg <- paste0('In ', new_var, " = ", as_label(exprs[[i]]), ", only values of size one are recycled")
        return(abandon_ship(call, .data, msg))
      }
      results[[new_var]] <- Expression$scalar(results[[new_var]])
    }
    # Put it in the data mask too
    mask[[new_var]] <- mask$.data[[new_var]] <- results[[new_var]]
  }

  # Assign the new columns into the .data$selected_columns, respecting the .keep param
  if (.keep == "none") {
    .data$selected_columns <- results
  } else {
    if (.keep != "all") {
      # "used" or "unused"
      used_vars <- unlist(lapply(exprs, all.vars), use.names = FALSE)
      old_vars <- names(.data$selected_columns)
      if (.keep == "used") {
        .data$selected_columns <- .data$selected_columns[intersect(old_vars, used_vars)]
      } else {
        # "unused"
        .data$selected_columns <- .data$selected_columns[setdiff(old_vars, used_vars)]
      }
    }
    # Note that this is names(exprs) not names(results):
    # if results$new_var is NULL, that means we are supposed to remove it
    for (new_var in names(exprs)) {
      .data$selected_columns[[new_var]] <- results[[new_var]]
    }
  }
  # Even if "none", we still keep group vars
  ensure_group_vars(.data)
}
mutate.Dataset <- mutate.ArrowTabular <- mutate.arrow_dplyr_query

transmute.arrow_dplyr_query <- function(.data, ...) dplyr::mutate(.data, ..., .keep = "none")
transmute.Dataset <- transmute.ArrowTabular <- transmute.arrow_dplyr_query

# Helper to handle unsupported dplyr features
# * For Table/RecordBatch, we collect() and then call the dplyr method in R
# * For Dataset, we just error
abandon_ship <- function(call, .data, msg = NULL) {
  dplyr_fun_name <- sub("^(.*?)\\..*", "\\1", as.character(call[[1]]))
  if (query_on_dataset(.data)) {
    if (is.null(msg)) {
      # Default message: function not implemented
      not_implemented_for_dataset(paste0(dplyr_fun_name, "()"))
    } else {
      stop(msg, "\nCall collect() first to pull data into R.", call. = FALSE)
    }
  }

  # else, collect and call dplyr method
  if (!is.null(msg)) {
    warning(msg, "; pulling data into R", immediate. = TRUE, call. = FALSE)
  }
  call$.data <- dplyr::collect(.data)
  call[[1]] <- get(dplyr_fun_name, envir = asNamespace("dplyr"))
  eval.parent(call, 2)
}

arrange.arrow_dplyr_query <- function(.data, ...) {
  .data <- arrow_dplyr_query(.data)
  if (query_on_dataset(.data)) {
    not_implemented_for_dataset("arrange()")
  }
  # TODO(ARROW-11703) move this to Arrow
  call <- match.call()
  abandon_ship(call, .data)
}
arrange.Dataset <- arrange.ArrowTabular <- arrange.arrow_dplyr_query

query_on_dataset <- function(x) inherits(x$.data, "Dataset")

not_implemented_for_dataset <- function(method) {
  stop(
    method, " is not currently implemented for Arrow Datasets. ",
    "Call collect() first to pull data into R.",
    call. = FALSE
  )
}
