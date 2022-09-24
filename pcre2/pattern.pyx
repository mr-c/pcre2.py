# -*- coding:utf-8 -*-

# Standard libraries.
from enum import IntEnum
from libc.stdint cimport uint32_t
from libc.stdlib cimport malloc, free
from cpython cimport Py_buffer, PyBuffer_Release
from cpython.unicode cimport PyUnicode_Check

# Local imports.
from .utils cimport *
from .libpcre2 cimport *
from .match cimport Match
from .consts import BsrChar, NewlineChar
from .exceptions import MatchError


cdef class Pattern:
    """

    Attributes:

        See pattern.pxd for attribute definitions.
        Dynamic attributes are enabled for this class.

        code: Compiled PCRE2 code.
        opts: PCRE2 compilation options.
        patn: Buffer containing source pattern expression including byte string
            and a reference to source object.
    """

    # =================================== #
    #         Lifetime management         #
    # =================================== #

    def __cinit__(self):
        self._code = NULL
        self._patn = NULL
        self._opts = 0


    def __init__(self, *args, **kwargs):
        # Prevent accidental instantiation from normal Python code since we
        # cannot pass pointers into a Python constructor.
        module = self.__class__.__module__
        qualname = self.__class__.__qualname__
        raise TypeError(f"Cannot create '{module}.{qualname}' instances")


    def __dealloc__(self):
        if self._patn is not NULL:
            PyBuffer_Release(self._patn)
        if self._code is not NULL:
            pcre2_code_free(self._code)


    @staticmethod
    cdef Pattern _from_data(pcre2_code_t *code, Py_buffer *patn, uint32_t opts):
        """ Factory function to create Pattern objects from C-type fields.

        The ownership of the given pointers are stolen, which causes the
        extension type to free them when the object is deallocated.
        """
        # Fast call to __new__() that bypasses the __init__() constructor.
        cdef Pattern pattern = Pattern.__new__(Pattern)
        pattern._code = code
        pattern._patn = patn
        pattern._opts = opts
        return pattern


    # =================================== #
    #         Pattern information         #
    # =================================== #

    @staticmethod
    cdef uint32_t _info_uint(pcre2_code_t *code, uint32_t what):
        """ Safely access pattern info returned as uint32_t. 
        """
        cdef uint32_t where
        pattern_info_rc = pcre2_pattern_info(code, what, &where)
        if pattern_info_rc < 0:
            raise_from_rc(pattern_info_rc, None)
        return where

    @staticmethod
    cdef bint _info_bint(pcre2_code_t *code, uint32_t what):
        """ Safely access pattern info returned as bint. 
        """
        cdef bint where
        pattern_info_rc = pcre2_pattern_info(code, what, &where)
        if pattern_info_rc < 0:
            raise_from_rc(pattern_info_rc, None)
        return where


    @property
    def pattern(self):
        """ Return the pattern the object was compiled with.
        """
        return self._patn.obj


    @property
    def options(self):
        """ Returns the compile options as modified by any top-level (*XXX)
        option settings such as (*UTF) at the start of the pattern itself.
        """
        return Pattern._info_uint(self._code, PCRE2_INFO_ALLOPTIONS)


    @property
    def backslash_r(self):
        """ Return an indicator to what character sequences the \R escape
        sequence matches.
        """
        bsr = Pattern._info_uint(self._code, PCRE2_INFO_BSR)
        return BsrChar(bsr)


    @property
    def capture_count(self):
        """ Return the highest capture group number in the pattern. In patterns
        where (?| is not used, this is also the total number of capture groups.
        """
        return Pattern._info_uint(self._code, PCRE2_INFO_CAPTURECOUNT)


    @property
    def jit_size(self):
        """ If the compiled pattern was successfully JIT compiled, return the
        size of the JIT compiled code, otherwise return zero.
        """
        return Pattern._info_uint(self._code, PCRE2_INFO_JITSIZE)

    
    @property
    def name_count(self):
        """ Returns the number of named capture groups.
        """
        return Pattern._info_uint(self._code, PCRE2_INFO_NAMECOUNT)


    @property
    def newline(self):
        """ Returns the type of character sequence that will be recognized as 
        meaning "newline" while matching.
        """
        newline = Pattern._info_uint(self._code, PCRE2_INFO_NEWLINE)
        return NewlineChar(newline)


    @property
    def size(self):
        """ Return the size of the compiled pattern in bytes.
        """
        return Pattern._info_uint(self._code, PCRE2_INFO_SIZE)


    def name_dict(self):
        """ Returns a dictionary mapping capture group number to capture group
        name.
        """
        # Get name table related information.
        name_count = Pattern._info_uint(self._code, PCRE2_INFO_NAMECOUNT)
        name_entry_size = Pattern._info_uint(self._code, PCRE2_INFO_NAMEENTRYSIZE)

        cdef pcre2_sptr_t name_table
        pattern_info_rc = pcre2_pattern_info(self._code, PCRE2_INFO_NAMETABLE, &name_table)
        if pattern_info_rc < 0:
            raise_from_rc(pattern_info_rc, None)

        # Convert byte table to dictionary.
        name_dict = {}
        cdef uint32_t i
        for i in range(name_count):
            offset = i * name_entry_size

            # First two bytes of name table contain index, followed by possibly
            # unicode byte string.
            entry_idx = int((name_table[offset] << 8) | name_table[offset + 1])
            entry_name = name_table[offset + 2:offset + name_entry_size]

            # Clean up entry and convert to unicode as appropriate.
            entry_name = entry_name.strip(b"\x00")
            if PyUnicode_Check(self._patn.obj):
                entry_name = entry_name.decode("utf-8")

            name_dict[entry_idx] = entry_name

        return name_dict


    # ======================= #
    #         Methods         #
    # ======================= #

    def jit_compile(self):
        """ JIT compile the compiled pattern.
        """
        jit_compile_rc = pcre2_jit_compile(self._code, PCRE2_JIT_COMPLETE)
        if jit_compile_rc < 0:
            raise_from_rc(jit_compile_rc, None)

    
    @staticmethod
    cdef pcre2_match_data_t * _create_match_data(pcre2_code_t *code):
        return pcre2_match_data_create_from_pattern(code, NULL)

    @staticmethod
    cdef pcre2_match_data_t * _match(
        pcre2_code_t *code, Py_buffer *subj, size_t ofst, uint32_t opts, int *rc
    ):
        """ Returns error code.
        """
        # Allocate memory for match.
        mtch = Pattern._create_match_data(code)
        if mtch is NULL:
            rc[0] = PCRE2_ERROR_NOMEMORY
            return NULL

        # Attempt match of pattern onto subject.
        rc[0] = pcre2_match(
            code,
            <pcre2_sptr_t>subj.buf, <size_t>subj.len,
            ofst, opts, mtch, NULL
        )
        return mtch


    def match(self, subject, offset=0, options=0):
        """
        """
        cdef bint is_patn_utf = PyUnicode_Check(self._patn.obj)
        cdef bint is_subj_utf = PyUnicode_Check(subject)
        if is_patn_utf ^ is_subj_utf:
            patn_type = "string" if is_patn_utf else "bytes-like"
            subj_type = "string" if is_subj_utf else "bytes-like"
            raise ValueError(f"Cannot use a {patn_type} pattern with a {subj_type} subject")

        cdef Py_buffer *subj = get_buffer(subject)
        cdef size_t obj_ofst = <size_t>offset
        cdef size_t ofst = obj_ofst
        cdef uint32_t opts = <uint32_t>options

        # Convert indices accordingly.
        if is_subj_utf:
            ofst, obj_ofst = codepoint_to_codeunit(subj, obj_ofst, 0, 0)

        cdef int match_rc = 0 
        cdef pcre2_match_data_t *mtch = Pattern._match(self._code, subj, ofst, opts, &match_rc)
        if match_rc < 0:
            raise_from_rc(match_rc, None)
            
        return Match._from_data(mtch, self, subj, ofst, opts)


    def scan(self, subject, offset=0):
        """
        """
        cdef bint is_patn_utf = PyUnicode_Check(self._patn.obj)
        cdef bint is_subj_utf = PyUnicode_Check(subject)
        if is_patn_utf ^ is_subj_utf:
            patn_type = "string" if is_patn_utf else "bytes-like"
            subj_type = "string" if is_subj_utf else "bytes-like"
            raise ValueError(f"Cannot use a {patn_type} pattern with a {subj_type} subject")

        patn_opts = Pattern._info_bint(self._code, PCRE2_INFO_ALLOPTIONS)
        is_patn_utf = (patn_opts & PCRE2_UTF) != 0
        newline = Pattern._info_uint(self._code, PCRE2_INFO_NEWLINE)
        is_crlf_newline = (
            newline == PCRE2_NEWLINE_ANY or
            newline == PCRE2_NEWLINE_CRLF or
            newline == PCRE2_NEWLINE_ANYCRLF
        )

        # Set offsets to keep track of object and byte offset indices.
        next_obj_ofst = <size_t>offset
        obj_ofst = 0
        ofst = 0

        opts = <unint32_t>0
        match_rc = <int>0
        subj_len = <size_t>len(subject)
        
        while next_obj_ofst <= subj_len:
            subj = get_buffer(subject)

            # Convert indices accordingly.
            if is_patn_utf:
                ofst, obj_ofst = codepoint_to_codeunit(subj, next_obj_ofst, ofst, obj_ofst)
            else:
                obj_ofst = next_obj_ofst
                ofst = obj_ofst

            # Attempt match of pattern onto subject.
            mtch = Pattern._match(self._code, subj, ofst, opts, &match_rc)

            if match_rc == PCRE2_ERROR_NOMATCH:
                if opts == 0:
                    break

                # Reset options so empty strings can match at next offset.
                opts = 0
                next_obj_ofst += 1

                # If we are at a CRLF that is matched as a newline.
                if is_crlf_newline and (ofst + 1) < <size_t>subj.len:
                    if subj.buf[ofst] == b"\r" and subj.buf[ofst + 1] == b"\n":
                        next_obj_ofst += 1
            elif match_rc < 0:
                raise_from_rc(match_rc, None)
            else:
                # If the matched string is empty ensure next is not. Otherwise
                # reset options and allow for empty matches.
                ovec_table = pcre2_get_ovector_pointer(mtch)
                mtch_end = ovec_table[1]

                if ofst == mtch_end:
                    opts = PCRE2_NOTEMPTY_ATSTART | PCRE2_ANCHORED
                else:
                    opts = 0
                    ofst, obj_ofst = codeunit_to_codepoint(subj, mtch_end, ofst, obj_ofst)
                    next_obj_ofst = obj_ofst

                yield Match._from_data(mtch, self, subj, ofst, opts)


    @staticmethod
    cdef (uint8_t *, size_t) _substitute(
        pcre2_code_t *code, Py_buffer *repl, Py_buffer *subj, size_t res_buf_len,
        size_t ofst, uint32_t opts, pcre2_match_data_t *mtch, int *rc
    ):
        """
        """
        cdef size_t res_len = 0
        cdef uint8_t *res = <uint8_t *>malloc(res_buf_len * sizeof(uint8_t))
        substitute_rc = pcre2_substitute(
            code,
            <pcre2_sptr_t>subj.buf, <size_t>subj.len,
            ofst, opts | PCRE2_SUBSTITUTE_OVERFLOW_LENGTH, mtch, NULL,
            <pcre2_sptr_t>repl.buf, <size_t>repl.len,
            res, &res_len
        )
        if substitute_rc == PCRE2_ERROR_NOMEMORY:
            free(res)
            res = <uint8_t *>malloc(res_len * sizeof(uint8_t))
            substitute_rc = pcre2_substitute(
                code,
                <pcre2_sptr_t>subj.buf, <size_t>subj.len,
                ofst, opts, mtch, NULL,
                <pcre2_sptr_t>repl.buf, <size_t>repl.len,
                res, &res_len
            )

        if substitute_rc < 0:
            free(res)
            PyBuffer_Release(subj)
            PyBuffer_Release(repl)
            rc[0] = substitute_rc
            return NULL, 0
        
        return res, res_len


    def substitute(self, replacement, subject, offset=0, options=0, low_memory=False):
        """ The type of the subject determines the type of the returned string.
        """
        is_patn_utf = <bint>PyUnicode_Check(self._patn.obj)
        is_subj_utf = <bint>PyUnicode_Check(subject)
        is_repl_utf = <bint>PyUnicode_Check(replacement)
        if is_subj_utf ^ is_repl_utf:
            subj_type = "string" if is_subj_utf else "bytes-like"
            repl_type = "string" if is_repl_utf else "bytes-like"
            raise ValueError(f"Cannot use a {subj_type} subject with a {repl_type} replacement")
        if is_patn_utf ^ is_subj_utf:
            patn_type = "string" if is_patn_utf else "bytes-like"
            subj_type = "string" if is_subj_utf else "bytes-like"
            raise ValueError(f"Cannot use a {patn_type} pattern with a {subj_type} subject")

        # Convert Python objects to C types.
        subj = get_buffer(subject)
        repl = get_buffer(replacement)
        cdef size_t obj_ofst = <size_t>offset
        cdef size_t ofst = obj_ofst
        cdef uint32_t opts = <uint32_t>options
        if is_subj_utf:
            ofst, obj_ofst = codepoint_to_codeunit(subj, obj_ofst, 0, 0)

        cdef size_t res_buf_len = 0
        if not low_memory:
            res_buf_len = 2 * (subj.len)

        cdef int rc = 0
        res, res_len = Pattern._substitute(
            self._code, repl, subj, res_buf_len, ofst, opts, NULL, &rc
        )
        if res is NULL:
            raise_from_rc(rc, None)

        # Clean up result and convert to unicode as appropriate.
        result = (<pcre2_sptr_t>res)[:res_len]
        result = result.strip(b"\x00")
        if is_subj_utf:
            result = result.decode("utf-8")
        
        free(res)
        PyBuffer_Release(subj)
        PyBuffer_Release(repl)
        return result
