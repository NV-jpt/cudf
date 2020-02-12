# Copyright (c) 2020, NVIDIA CORPORATION.

import pandas as pd
import numba
import numpy as np
from libcpp.string cimport string
from cudf.utils import cudautils

from cudf._libxx.lib cimport *

from cudf._libxx.column import np_to_cudf_types
from cudf._libxx.aggregation cimport *

# need to update as and when we add new aggregations with additional options
cdef unique_ptr[aggregation] get_aggregation(op, kwargs):

    cdef type_id tid
    cdef data_type out_dtype
    cdef string cpp_str

    if op is "sum":
        return make_sum_aggregation()
    elif op is "min":
        return make_min_aggregation()
    elif op is "max":
        return make_max_aggregation()
    elif op is "mean":
        return make_mean_aggregation()
    elif op is "count":
        return make_count_aggregation()
    elif callable(op):
        # Handling UDF type
        nb_type = numba.numpy_support.from_dtype(kwargs['dtype'])
        type_signature = (nb_type[:],)
        compiled_op = cudautils.compile_udf(op, type_signature)
        output_np_dtype = np.dtype(compiled_op[1])
        cpp_str = compiled_op[0].encode('UTF-8')
        if output_np_dtype not in np_to_cudf_types:
            raise TypeError(
                "Result of window function has unsupported dtype {}"
                .format(op[1])
            )
        tid = np_to_cudf_types[output_np_dtype]

        out_dtype = data_type(tid)

        return make_udf_aggregation(udf_type.PTX, cpp_str, out_dtype)
    else:
        assert False, "Invalid aggreagtion operation"
