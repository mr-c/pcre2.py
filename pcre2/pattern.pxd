# -*- coding:utf-8 -*-

# _____________________________________________________________________________
#                                                                       Imports

# Standard libraries.
from cpython cimport Py_buffer
from libc.stdint cimport uint8_t, uint32_t

# Local imports.
from pcre2._libs.libpcre2 cimport pcre2_code_t


# _____________________________________________________________________________
#                                                                   Definitions

cdef class Pattern:
    cdef pcre2_code_t *code
    cdef Py_buffer *pattern
    cdef readonly object flags