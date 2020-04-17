/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/split/split.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/detail/nvtx/ranges.hpp>

#include <vector>
#include <thrust/transform.h>
#include <thrust/copy.h>
#include <thrust/binary_search.h>
#include <thrust/count.h>
#include <thrust/extrema.h>

namespace cudf
{
namespace strings
{
namespace detail
{

using string_index_pair = thrust::pair<const char*,size_type>;
using position_pair = thrust::pair<size_type,size_type>;

namespace
{

//
// This will create new columns by splitting the array of strings vertically.
// All the first tokens go in the first column, all the second tokens go in the second column, etc.
// It is comparable to Pandas split with expand=True but the rows/columns are transposed.
// Example:
//   import pandas as pd
//   pd_series = pd.Series(['', None, 'a_b', '_a_b_', '__aa__bb__', '_a__bbb___c', '_aa_b__ccc__'])
//   print(pd_series.str.split(pat='_', expand=True))
//            0     1     2     3     4     5     6
//      0    ''  None  None  None  None  None  None
//      1  None  None  None  None  None  None  None
//      2     a     b  None  None  None  None  None
//      3    ''     a     b    ''  None  None  None
//      4    ''    ''    aa    ''    bb    ''    ''
//      5    ''     a    ''   bbb    ''    ''     c
//      6    ''    aa     b    ''   ccc    ''    ''
//
//   print(pd_series.str.split(pat='_', n=1, expand=True))
//            0            1
//      0    ''         None
//      1  None         None
//      2     a            b
//      3    ''         a_b_
//      4    ''    _aa__bb__
//      5    ''   a__bbb___c
//      6    ''  aa_b__ccc__
//
//   print(pd_series.str.split(pat='_', n=2, expand=True))
//            0     1         2
//      0    ''  None      None
//      1  None  None      None
//      2     a     b      None
//      3    ''     a        b_
//      4    ''        aa__bb__
//      5    ''     a  _bbb___c
//      6    ''    aa  b__ccc__
//

/**
 * @brief Base class for delimiter-based tokenizers.
 *
 * These are common methods used by both split and rsplit tokenizer functors.
 */
struct base_split_tokenizer
{
    __device__ const char* get_base_ptr() const
    { return d_strings.child(strings_column_view::chars_column_index).data<char>(); }

    __device__ string_view const get_string(size_type idx) const
    { return d_strings.element<string_view>(idx); }

    __device__ bool is_valid(size_type idx) const
    { return d_strings.is_valid(idx); }

    /**
     * @brief Initialize token elements for all strings.
     *
     * The process_tokens() only handles creating tokens for strings that contain
     * delimiters. This function will initialize the output tokens for all
     * strings by assigning null entries for null and empty strings and the
     * string itself for strings with no delimiters.
     *
     * @param idx Index of string in column
     * @param column_count Number of columns in output
     * @param d_all_tokens Tokens vector for all strings
     */
    __device__ void init_tokens( size_type idx,
                                 size_type column_count,
                                 string_index_pair* d_all_tokens ) const
    {
        auto d_tokens = d_all_tokens + (idx * column_count);
        if( is_valid(idx) )
        {
            auto d_str = get_string(idx);
            *d_tokens++ = string_index_pair{d_str.data(),d_str.size_bytes()};
            --column_count;
        }
        thrust::fill( thrust::seq, d_tokens, d_tokens + column_count, string_index_pair{nullptr,0} );
    }

    base_split_tokenizer( column_device_view const& d_strings, string_view const& d_delimiter, size_type max_tokens )
    : d_strings(d_strings), d_delimiter(d_delimiter), max_tokens(max_tokens) {}

protected:
    column_device_view const d_strings;  // strings to split
    string_view const d_delimiter;       // delimiter for split
    size_type max_tokens;
};

/**
 * @brief The tokenizer functions for split().
 *
 * The methods here count delimiters, tokens, and output token elements
 * for each string in a strings column.
 */
struct split_tokenizer_fn : base_split_tokenizer
{
    /**
     * @brief This will create tokens around each delimiter honoring the string boundaries
     * in which the delimiter resides.
     *
     * @param idx Index of the delimiter in the chars column
     * @param column_count Number of output columns
     * @param d_token_counts Token counts for each string
     * @param d_positions The beginning byte position of each delimiter
     * @param positions_count Number of delimiters
     * @param d_indexes Indices of the strings for each delimiter
     * @param d_all_tokens All output tokens for the strings column
     */
    __device__ void process_tokens(size_type idx,
                                   size_type column_count,
                                   size_type const* d_token_counts,
                                   size_type const* d_positions,
                                   size_type positions_count,
                                   size_type const* d_indexes,
                                   string_index_pair* d_all_tokens ) const
    {
        size_type str_idx = d_indexes[idx];
        if( (idx > 0) && d_indexes[idx-1]==str_idx )
            return; // the first delimiter for the string rules them all
        --str_idx; // all of these are off by 1 from the upper_bound call
        string_view d_str = get_string(str_idx);
        size_type token_count = d_token_counts[str_idx]; // max_tokens already included
        auto d_tokens = d_all_tokens + (str_idx * column_count); // point to this string's tokens output
        const char* const base_ptr = get_base_ptr(); // d_positions values are based on this ptr
        const char* str_ptr = d_str.data();                     // beginning of the string
        const char* const str_end_ptr = str_ptr + d_str.size_bytes(); // end of the string
        // build the index-pair of each token for this string
        for( size_type col=0; col < token_count; ++col )
        {
            auto next_delim = ((idx+col) < positions_count) // boundary check for delims in last string
                              ? (base_ptr + d_positions[idx+col]) // start of next delimiter
                              : str_end_ptr;                      // or end of this string
            auto eptr = (next_delim < str_end_ptr)   // make sure delimiter is inside this string
                         && (col+1 < token_count)    // and this is not the last token
                        ? next_delim : str_end_ptr;
            // store the token into the output vector
            d_tokens[col] = string_index_pair{ str_ptr, static_cast<size_type>(eptr-str_ptr)};
            str_ptr = eptr + d_delimiter.size_bytes();
        }
    }

    /**
     * @brief Returns `true` if the byte at `idx` is the start of the delimiter.
     *
     * @param idx Index of a byte in the chars column.
     * @param d_offsets Offsets values to locate the chars ranges.
     * @param chars_bytes Total number of characters to process.
     * @return true if delimiter is found starting at position `idx`
     */
    __device__ bool is_delimiter( size_type idx,  // chars index
                                  int32_t const* d_offsets,
                                  size_type chars_bytes ) const
    {
        auto d_chars = get_base_ptr() + d_offsets[0];
        if( idx + d_delimiter.size_bytes() > chars_bytes )
            return false;
        return d_delimiter.compare(d_chars+idx,d_delimiter.size_bytes())==0;
    }

    /**
     * @brief This counts the tokens for strings that contain delimiters.
     *
     * @param idx Index of a delimiter
     * @param d_positions Start positions of all the delimiters
     * @param positions_count The number of delimiters
     * @param d_indexes Indices of the strings for each delimiter
     * @param d_counts The token counts for all the strings
     */
    __device__ void count_tokens(size_type idx, // delimiter index
                                 size_type const* d_positions,
                                 size_type positions_count,
                                 size_type const* d_indexes,
                                 size_type* d_counts ) const
    {
        size_type str_idx = d_indexes[idx];
        if( (idx > 0) && d_indexes[idx-1]==str_idx )
            return; // first delimiter found handles all of them for this string
        auto const delim_length = d_delimiter.size_bytes();
        string_view const d_str = get_string(str_idx-1);
        const char* const base_ptr = get_base_ptr();
        size_type delim_count = 0; // re-count delimiters to compute the token-count
        size_type last_pos = d_positions[idx] - delim_length;
        while( (idx < positions_count) && (d_indexes[idx] == str_idx) )
        {
            // make sure the whole delimiter is inside the string before counting it
            auto d_pos = d_positions[idx];
            if( ((base_ptr + d_pos + delim_length -1) < (d_str.data() + d_str.size_bytes()))
                && ((d_pos - last_pos) >= delim_length) )
            {
                ++delim_count;    // only count if the delimiter fits
                last_pos = d_pos; // overlapping delimiters are ignored too
            }
            ++idx;
        }
        // the number of tokens is delim_count+1 but capped to max_tokens
        d_counts[str_idx-1] = ((max_tokens > 0) && (delim_count+1 > max_tokens))
                              ? max_tokens : delim_count+1;
    }

    split_tokenizer_fn( column_device_view const& d_strings, string_view const& d_delimiter, size_type max_tokens )
    : base_split_tokenizer(d_strings,d_delimiter,max_tokens) {}
};

/**
 * @brief The tokenizer functions for split().
 *
 * The methods here count delimiters, tokens, and output token elements
 * for each string in a strings column.
 * 
 * Same as split_tokenizer_fn except tokens are counted from the end of each string.
 */
struct rsplit_tokenizer_fn : base_split_tokenizer
{
    /**
     * @brief This will create tokens around each delimiter honoring the string boundaries
     * in which the delimiter resides.
     *
     * The tokens are processed from the end of each string so the `max_tokens`
     * is honored correctly.
     *
     * @param idx Index of the delimiter in the chars column
     * @param column_count Number of output columns
     * @param d_token_counts Token counts for each string
     * @param d_positions The ending byte position of each delimiter
     * @param positions_count Number of delimiters
     * @param d_indexes Indices of the strings for each delimiter
     * @param d_all_tokens All output tokens for the strings column
     */
    __device__ void process_tokens(size_type idx, // delimiter position index
                                   size_type column_count, // number of output columns
                                   size_type const* d_token_counts, // token counts for each string
                                   size_type const* d_positions, // end of each delimiter
                                   size_type positions_count, // total number of delimiters
                                   size_type const* d_indexes, // string indices for each delimiter
                                   string_index_pair* d_all_tokens ) const
    {
        size_type str_idx = d_indexes[idx];
        if( (idx+1 < positions_count) && d_indexes[idx+1]==str_idx )
            return; // the last delimiter for the string rules them all
        --str_idx; // all of these are off by 1 from the upper_bound call
        size_type token_count = d_token_counts[str_idx]; // max_tokens already included
        auto d_tokens = d_all_tokens + (str_idx * column_count); // point to this string's tokens output
        const char* const base_ptr = get_base_ptr(); // d_positions values are based on this ptr
        const string_view d_str = get_string(str_idx);
        const char* const str_begin_ptr = d_str.data(); // beginning of the string
        const char* str_ptr = str_begin_ptr + d_str.size_bytes(); // end of the string
        // build the index-pair of each token for this string
        for( size_type col=0; col < token_count; ++col )
        {
            auto prev_delim = (idx >= col) // boundary check for delims in first string
                              ? (base_ptr + d_positions[idx-col] +1) // end of prev delimiter
                              : str_begin_ptr;                       // or the start of this string
            auto sptr = (prev_delim > str_begin_ptr)  // make sure delimiter is inside the string
                         && (col+1 < token_count)     // and this is not the last token
                        ? prev_delim : str_begin_ptr;
            // store the token into the output -- building the array backwards
            d_tokens[token_count-1-col] = string_index_pair{ sptr, static_cast<size_type>(str_ptr-sptr)};
            str_ptr = sptr - d_delimiter.size_bytes(); // get ready for the next prev token
        }
    }

    /**
     * @brief Returns `true` if the byte at `idx` is the end of the delimiter.
     *
     * @param idx Index of a byte in the chars column.
     * @param d_offsets Offsets values to locate the chars ranges.
     * @param chars_bytes Total number of characters to process.
     * @return true if delimiter is found ending at position `idx`
     */
    __device__ bool is_delimiter( size_type idx,
                                  int32_t const* d_offsets,
                                  size_type chars_bytes ) const
    {
        auto delim_length = d_delimiter.size_bytes();
        if( idx < delim_length-1 )
            return false;
        auto d_chars = get_base_ptr() + d_offsets[0];
        return d_delimiter.compare(d_chars+idx-(delim_length-1),delim_length)==0;
    }

    /**
     * @brief This counts the tokens for strings that contain delimiters.
     *
     * Token counting starts at the end of the string to honor the `max_tokens`
     * appropriately.
     *
     * @param idx Index of a delimiter
     * @param d_positions End positions of all the delimiters
     * @param positions_count The number of delimiters
     * @param d_indexes Indices of the strings for each delimiter
     * @param d_counts The token counts for all the strings
     */
    __device__ void count_tokens(size_type idx,
                                 size_type const* d_positions,
                                 size_type positions_count,
                                 size_type const* d_indexes,
                                 size_type* d_counts ) const
    {
        size_type str_idx = d_indexes[idx];
        if( (idx > 0) && d_indexes[idx-1]==str_idx )
            return; // first delimiter found handles all of them for this string
        auto const delim_length = d_delimiter.size_bytes();
        string_view const d_str = get_string(str_idx-1);
        const char* const base_ptr = get_base_ptr();
        size_type delim_count = 0;
        size_type last_pos = d_positions[idx] - delim_length;
        while( (idx < positions_count) && (d_indexes[idx] == str_idx) )
        {
            // make sure the whole delimiter is inside the string before counting it
            auto d_pos = d_positions[idx];
            if( ((base_ptr + d_pos + 1 - delim_length) >= d_str.data())
                && ((d_pos - last_pos) >= delim_length) )
            {
                ++delim_count;    // only count if the delimiter fits
                last_pos = d_pos; // overlapping delimiters are also ignored
            }
            ++idx;
        }
        // the number of tokens is delim_count+1 but capped to max_tokens
        d_counts[str_idx-1] = ((max_tokens > 0) && (delim_count+1 > max_tokens))
                              ? max_tokens : delim_count+1;
    }

    rsplit_tokenizer_fn( column_device_view const& d_strings, string_view const& d_delimiter, size_type max_tokens )
    : base_split_tokenizer(d_strings,d_delimiter,max_tokens) {}
};

/**
 * @brief Generic split function called by split() and rsplit().
 *
 * This function will first count the number of delimiters in the entire strings
 * column. Next it records the position of all the delimiters. These positions
 * are used for the remainder of the code to build string_index_pair elements
 * for each output column.
 *
 * The number of tokens for each string is computed by analyzing the delimiter
 * position values and mapping them to each string.
 * The number of output columns is determined by the string with the most tokens.
 * Next the string_index_pairs for the entire column is created using the
 * delimiter positions and their string indices vector.
 *
 * Finally, each column is built by creating a vector of tokens (string_index_pairs)
 * according to their position in each string. The first token from each string goes
 * into the first output column, the 2nd token from each string goes into the 2nd
 * output column, etc.
 *
 * @tparam Tokenizer provides unique functions for split/rsplit.
 * @param strings_column The strings to split
 * @param tokenizer Tokenizer for counting and producing tokens
 * @return table of columns for the output of the split
 */
template<typename Tokenizer>
std::unique_ptr<experimental::table> split_fn( strings_column_view const& strings_column,
                                               Tokenizer tokenizer,
                                               rmm::mr::device_memory_resource* mr,
                                               cudaStream_t stream )
{
    std::vector<std::unique_ptr<column>> results;
    auto strings_count = strings_column.size();

    auto execpol = rmm::exec_policy(stream);
    auto d_offsets = strings_column.offsets().data<int32_t>();
    d_offsets += strings_column.offset(); // nvbug-2808421 : do not combine with the previous line
    auto chars_bytes = thrust::device_pointer_cast(d_offsets)[strings_count]
                     - thrust::device_pointer_cast(d_offsets)[0];

    // count the number of delimiters in the entire column
    size_type delimiter_count = thrust::count_if( execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0),
        thrust::make_counting_iterator<size_type>(chars_bytes),
        [tokenizer, d_offsets, chars_bytes] __device__ (size_type idx) {
            return tokenizer.is_delimiter(idx,d_offsets,chars_bytes);
        });

    // create vector of every delimiter position in the chars column
    rmm::device_vector<size_type> delimiter_positions(delimiter_count);
    auto d_positions = delimiter_positions.data().get();
    auto copy_end = thrust::copy_if( execpol->on(stream), thrust::make_counting_iterator<size_type>(0),
        thrust::make_counting_iterator<size_type>(chars_bytes), delimiter_positions.begin(),
        [tokenizer, d_offsets, chars_bytes] __device__ (size_type idx) {
            return tokenizer.is_delimiter(idx,d_offsets,chars_bytes);
        });

    // create vector of string indices for each delimiter
    rmm::device_vector<size_type> string_indices(delimiter_count); // these will be strings that
    auto d_string_indices = string_indices.data().get();           // only contain delimiters
    thrust::upper_bound( execpol->on(stream),
        d_offsets, d_offsets + strings_count,
        delimiter_positions.begin(), copy_end, string_indices.begin() );

    // compute the number of tokens per string
    rmm::device_vector<size_type> token_counts(strings_count);
    auto d_token_counts = token_counts.data().get();
    // first, initialize token counts for strings without delimiters in them
    thrust::transform( execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0),
        thrust::make_counting_iterator<size_type>(strings_count),
        d_token_counts,
        [tokenizer] __device__ (size_type idx) {
            // null are 0, all others 1
            return static_cast<size_type>(tokenizer.is_valid(idx));
        } );
    // now compute the number of tokens in each string
    thrust::for_each_n( execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0), delimiter_count,
        [tokenizer, d_positions, delimiter_count, d_string_indices, d_token_counts] __device__(size_type idx) {
            tokenizer.count_tokens(idx,d_positions,delimiter_count,d_string_indices,d_token_counts);
        } );

    // the columns_count is the maximum number of tokens for any string
    size_type columns_count =
        *thrust::max_element(execpol->on(stream), token_counts.begin(), token_counts.end() );
    // boundary case: if no columns, return one null column (custrings issue #119)
    if( columns_count==0 )
    {
        results.push_back(std::make_unique<column>( data_type{STRING}, strings_count,
                          rmm::device_buffer{0,stream,mr}, // no data
                          create_null_mask(strings_count, mask_state::ALL_NULL, stream, mr), strings_count ));
    }

    // create working area to hold token positions
    rmm::device_vector<string_index_pair> tokens( columns_count * strings_count );
    string_index_pair* d_tokens = tokens.data().get();
    // initialize the token positions -- accounts for nulls, empty, and strings with no delimiter in them
    thrust::for_each_n(execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0), strings_count,
        [tokenizer, columns_count, d_tokens] __device__ (size_type idx) {
            tokenizer.init_tokens(idx,columns_count,d_tokens);
        });

    // get the positions for every token using the delimiter positions
    thrust::for_each_n(execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0), delimiter_count,
        [tokenizer, columns_count, d_token_counts, d_positions, delimiter_count, d_string_indices, d_tokens] __device__ (size_type idx) {
            tokenizer.process_tokens(idx,columns_count,d_token_counts,d_positions,delimiter_count,d_string_indices,d_tokens );
        });

    // Create each column.
    // Build a vector of string_index_pair's for each column.
    // Each pair points to the strings for that column for each row.
    // Create the strings column from the vector using the strings factory.
    for( size_type col=0; col < columns_count; ++col )
    {
        rmm::device_vector<string_index_pair> indexes(strings_count);
        string_index_pair* d_indexes = indexes.data().get();
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_indexes,
            [col, columns_count, d_tokens] __device__ (size_type idx) {
                return d_tokens[ col + (idx * columns_count) ];
            });
        auto column = make_strings_column(indexes,stream,mr);
        results.emplace_back(std::move(column));
    }
    return std::make_unique<experimental::table>(std::move(results));
}

//
// This section is the whitespace-delimiter version of the column split function.
// Like the one above, it can be compared to Pandas split with expand=True but
// with the rows/columns transposed.
//
// The main difference between whitespace tokenizing and delimiter-based tokenizing
// is that all contiguous whitespace is treated as a single delimiter and leading
// and trailing whitespace is ignored (mostly).
//
//  import pandas as pd
//  pd_series = pd.Series(['', None, 'a b', ' a b ', '  aa  bb  ', ' a  bbb   c', ' aa b  ccc  '])
//  print(pd_series.str.split(pat=None, expand=True))
//            0     1     2
//      0  None  None  None
//      1  None  None  None
//      2     a     b  None
//      3     a     b  None
//      4    aa    bb  None
//      5     a   bbb     c
//      6    aa     b   ccc
//
//  print(pd_series.str.split(pat=None, n=1, expand=True))
//            0         1
//      0  None      None
//      1  None      None
//      2     a         b
//      3     a        b
//      4    aa      bb
//      5     a   bbb   c
//      6    aa  b  ccc
//
//  print(pd_series.str.split(pat=None, n=2, expand=True))
//            0     1      2
//      0  None  None   None
//      1  None  None   None
//      2     a     b   None
//      3     a     b   None
//      4    aa    bb   None
//      5     a   bbb      c
//      6    aa     b  ccc
//
//

/**
 * @brief Base class for whitespace tokenizers.
 *
 * These are common methods used by both split and rsplit tokenizer functors.
 */
struct base_whitespace_split_tokenizer
{
    // count the 'words' only between non-whitespace characters
    __device__ size_type count_tokens(size_type idx) const
    {
        if( d_strings.is_null(idx) )
            return 0;
        string_view d_str = d_strings.element<string_view>(idx);
        size_type token_count = 0;
        bool spaces = true; // need to treat a run of whitespace as a single delimiter
        auto itr = d_str.begin();
        while( itr != d_str.end() )
        {
            char_utf8 ch = *itr;
            if( spaces == (ch <= ' ') )
                itr++;
            else
            {
                token_count += static_cast<size_type>(spaces);
                spaces = !spaces;
            }
        }
        if( max_tokens && (token_count > max_tokens) )
            token_count = max_tokens;
        if( token_count==0 )
            token_count = 1; // always at least 1 token
        //printf(" tokens[%d]=%d\n",idx,token_count);
        return token_count;
    }

    base_whitespace_split_tokenizer( column_device_view const& d_strings, size_type max_tokens )
    : d_strings(d_strings), max_tokens(max_tokens) {}

protected:
    column_device_view const d_strings;
    size_type max_tokens; // maximum number of tokens
};

/**
 * @brief Instantiated for each string to manage navigating tokens from
 * the beginning or the end of that string.
 */
struct whitespace_string_tokenizer
{
    /**
     * @brief Identifies the position range of the next token in the given
     * string at the specified iterator position.
     *
     * Tokens are delimited by one or more whitespace characters.
     *
     * @return true if a token has been found
     */
    __device__ bool next_token()
    {
        if( itr != d_str.begin() )
        {   // skip these 2 lines the first time through
            start_position = end_position + 1;
            ++itr;
        }
        if( start_position >= d_str.length() )
            return false;
        // continue search for the next token
        end_position = d_str.length();
        for( ; itr < d_str.end(); ++itr )
        {
            if( spaces == (*itr <= ' ') )
            {
                if( spaces )
                    start_position = itr.position()+1;
                else
                    end_position = itr.position()+1;
                continue;
            }
            spaces = !spaces;
            if( spaces )
            {
                end_position = itr.position();
                break;
            }
        }
        return start_position < end_position;
    }

    /**
     * @brief Identifies the position range of the previous token in the given
     * string at the specified iterator position.
     *
     * Tokens are delimited by one or more whitespace characters.
     *
     * @return true if a token has been found
     */
    __device__ bool prev_token()
    {
        end_position = start_position - 1;
        --itr;
        if( end_position <= 0 )
            return false;
        // continue search for the next token
        start_position = 0;
        for( ; itr >= d_str.begin(); --itr )
        {
            if( spaces == (*itr <= ' ') )
            {
                if( spaces )
                    end_position = itr.position();
                else
                    start_position = itr.position();
                continue;
            }
            spaces = !spaces;
            if( spaces )
            {
                start_position = itr.position()+1;
                break;
            }
        }
        return start_position < end_position;
    }

    __device__ position_pair token_byte_positions()
    {
        return position_pair{d_str.byte_offset(start_position),
                             d_str.byte_offset(end_position)};
    }

    __device__ whitespace_string_tokenizer( string_view const& d_str, bool reverse = false )
    : d_str{d_str}, spaces(true),
      start_position{reverse ? d_str.length()+1 : 0}, end_position{d_str.length()},
      itr{ reverse ? d_str.end() : d_str.begin()} {}

private:
    string_view const d_str;
    bool spaces; // true if current position is whitespace
    cudf::string_view::const_iterator itr;
    size_type start_position;
    size_type end_position;
};

/**
 * @brief The tokenizer functions for split() with whitespace.
 *
 * The whitespace tokenizer has no delimiter and handles one or more
 * consecutive whitespace characters as a single delimiter.
 */
struct whitespace_split_tokenizer_fn : base_whitespace_split_tokenizer
{
    /**
     * @brief This will create tokens around each runs of whitespace characters.
     *
     * @param idx Index of the string to process
     * @param column_count Number of output columns
     * @param d_token_counts Token counts for each string
     * @param d_all_tokens All output tokens for the strings column
     */
    __device__ void process_tokens(size_type idx,
                                   size_type column_count,
                                   size_type const* d_token_counts,
                                   string_index_pair* d_all_tokens ) const
    {
        string_index_pair* d_tokens = d_all_tokens + (idx * column_count);
        thrust::fill( thrust::seq, d_tokens, d_tokens + column_count, string_index_pair{nullptr,0} );
        if( d_strings.is_null(idx) )
            return;
        string_view const d_str = d_strings.element<cudf::string_view>(idx);
        if( d_str.empty() )
            return;
        whitespace_string_tokenizer tokenizer(d_str);
        size_type token_count = d_token_counts[idx];
        size_type token_idx = 0;
        position_pair token{0,0};
        while( tokenizer.next_token() && (token_idx < token_count) )
        {
            token = tokenizer.token_byte_positions();
            d_tokens[token_idx++] = string_index_pair{ d_str.data() + token.first, (token.second-token.first) };
        }
        if( token_count == max_tokens )
            d_tokens[--token_idx] = string_index_pair{ d_str.data() + token.first, (d_str.size_bytes()-token.first) };
    }

    whitespace_split_tokenizer_fn( column_device_view const& d_strings, size_type max_tokens )
    : base_whitespace_split_tokenizer(d_strings,max_tokens) {}
};

/**
 * @brief The tokenizer functions for rsplit() with whitespace.
 *
 * The whitespace tokenizer has no delimiter and handles one or more
 * consecutive whitespace characters as a single delimiter.
 * 
 * This one processes tokens from the end of each string.
 */
struct whitespace_rsplit_tokenizer_fn : base_whitespace_split_tokenizer
{
    /**
     * @brief This will create tokens around each runs of whitespace characters.
     * 
     * @param idx Index of the string to process
     * @param column_count Number of output columns
     * @param d_token_counts Token counts for each string
     * @param d_all_tokens All output tokens for the strings column
     */
    __device__ void process_tokens(size_type idx, // string position index
                                   size_type column_count,
                                   size_type const* d_token_counts,
                                   string_index_pair* d_all_tokens ) const
    {
        string_index_pair* d_tokens = d_all_tokens + (idx * column_count);
        thrust::fill( thrust::seq, d_tokens, d_tokens + column_count, string_index_pair{nullptr,0} );
        if( d_strings.is_null(idx) )
            return;
        string_view const d_str = d_strings.element<cudf::string_view>(idx);
        if( d_str.empty() )
            return;
        whitespace_string_tokenizer tokenizer(d_str,true);
        size_type token_count = d_token_counts[idx];
        size_type token_idx = 0;
        position_pair token{0,0};
        while( tokenizer.prev_token() && (token_idx < token_count) )
        {
            token = tokenizer.token_byte_positions();
            //printf(" %d(%d): (%d,%d)\n",idx,token_idx,token.first,token.second);
            d_tokens[token_count-1-token_idx] = string_index_pair{ d_str.data() + token.first, (token.second-token.first) };
            ++token_idx;
        }
        if( token_count == max_tokens )
            d_tokens[token_count-token_idx] = string_index_pair{ d_str.data(), token.second };
    }

    whitespace_rsplit_tokenizer_fn( column_device_view const& d_strings, size_type max_tokens )
    : base_whitespace_split_tokenizer(d_strings,max_tokens) {}
};

/**
 * @brief Generic split function called by split() and rsplit() using whitespace as a delimiter.
 *
 * The number of tokens for each string is computed by counting consecutive characters
 * between runs of whitespace in each string. The number of output columns is determined
 * by the string with the most tokens. Next the string_index_pairs for the entire column
 * is created.
 *
 * Finally, each column is built by creating a vector of tokens (string_index_pairs)
 * according to their position in each string. The first token from each string goes
 * into the first output column, the 2nd token from each string goes into the 2nd
 * output column, etc.
 *
 * @tparam Tokenizer provides unique functions for split/rsplit.
 * @param strings_count The number of strings in the column
 * @param tokenizer Tokenizer for counting and producing tokens
 * @return table of columns for the output of the split
 */
template<typename Tokenizer>
std::unique_ptr<experimental::table> whitespace_split_fn( size_type strings_count,
                                                          Tokenizer tokenizer,
                                                          rmm::mr::device_memory_resource* mr,
                                                          cudaStream_t stream )
{
    auto execpol = rmm::exec_policy(stream);

    // compute the number of tokens per string
    size_type columns_count = 0;
    rmm::device_vector<size_type> token_counts(strings_count);
    auto d_token_counts = token_counts.data().get();
    if( strings_count > 0 )
    {
        thrust::transform( execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_token_counts,
            [tokenizer] __device__ (size_type idx) { return tokenizer.count_tokens(idx); });
        // column count is the maximum number of tokens for any string
        columns_count = *thrust::max_element(execpol->on(stream),
                                             token_counts.begin(), token_counts.end() );
    }

    std::vector<std::unique_ptr<column>> results;
    // boundary case: if no columns, return one null column (issue #119)
    if( columns_count==0 )
    {
        results.push_back(std::make_unique<column>( data_type{STRING}, strings_count,
                          rmm::device_buffer{0,stream,mr}, // no data
                          create_null_mask(strings_count, mask_state::ALL_NULL, stream, mr), strings_count ));
    }

    // get the positions for every token
    rmm::device_vector<string_index_pair> tokens( columns_count * strings_count );
    string_index_pair* d_tokens = tokens.data().get();
    thrust::for_each_n(execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0), strings_count,
        [tokenizer, columns_count, d_token_counts, d_tokens] __device__ (size_type idx) {
            tokenizer.process_tokens(idx,columns_count,d_token_counts,d_tokens );
        });

    // Create each column.
    // Build a vector of string_index_pair's for each column.
    // Each pair points to a string for that column for each row.
    // Create the strings column from the vector using the strings factory.
    for( size_type col=0; col < columns_count; ++col )
    {
        rmm::device_vector<string_index_pair> indexes(strings_count);
        string_index_pair* d_indexes = indexes.data().get();
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_indexes,
            [col, columns_count, d_tokens] __device__ (size_type idx) {
                return d_tokens[ col + (idx * columns_count) ];
            });
        auto column = make_strings_column(indexes,stream,mr);
        results.emplace_back(std::move(column));
    }
    return std::make_unique<experimental::table>(std::move(results));
}

} // namespace


std::unique_ptr<experimental::table> split( strings_column_view const& strings_column,
                                            string_scalar const& delimiter = string_scalar(""),
                                            size_type maxsplit=-1,
                                            rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                            cudaStream_t stream = 0 )
{
    CUDF_EXPECTS( delimiter.is_valid(), "Parameter delimiter must be valid");

    size_type max_tokens = 0;
    if( maxsplit > 0 )
        max_tokens = maxsplit + 1; // makes consistent with Pandas

    auto strings_device_view = column_device_view::create(strings_column.parent(),stream);
    if( delimiter.size()==0 )
    {
        return whitespace_split_fn( strings_column.size(),
                                    whitespace_split_tokenizer_fn{*strings_device_view,max_tokens},
                                    mr, stream);
    }

    string_view d_delimiter( delimiter.data(), delimiter.size() );
    return split_fn( strings_column, split_tokenizer_fn{*strings_device_view,d_delimiter,max_tokens},
                     mr, stream);
}

std::unique_ptr<experimental::table> rsplit( strings_column_view const& strings_column,
                                             string_scalar const& delimiter = string_scalar(""),
                                             size_type maxsplit=-1,
                                             rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                             cudaStream_t stream = 0 )
{
    CUDF_EXPECTS( delimiter.is_valid(), "Parameter delimiter must be valid");

    size_type max_tokens = 0;
    if( maxsplit > 0 )
        max_tokens = maxsplit + 1; // makes consistent with Pandas

    auto strings_device_view = column_device_view::create(strings_column.parent(),stream);
    if( delimiter.size()==0 )
    {
        return whitespace_split_fn( strings_column.size(),
                                    whitespace_rsplit_tokenizer_fn{*strings_device_view,max_tokens},
                                    mr, stream);
    }

    string_view d_delimiter( delimiter.data(), delimiter.size() );
    return split_fn( strings_column, rsplit_tokenizer_fn{*strings_device_view,d_delimiter,max_tokens},
                     mr, stream);
}

} // namespace detail

// external APIs

std::unique_ptr<experimental::table> split( strings_column_view const& strings_column,
                                            string_scalar const& delimiter,
                                            size_type maxsplit,
                                            rmm::mr::device_memory_resource* mr )
{
    CUDF_FUNC_RANGE();
    return detail::split( strings_column, delimiter, maxsplit, mr );
}

std::unique_ptr<experimental::table> rsplit( strings_column_view const& strings_column,
                                             string_scalar const& delimiter,
                                             size_type maxsplit,
                                             rmm::mr::device_memory_resource* mr)
{
    CUDF_FUNC_RANGE();
    return detail::rsplit( strings_column, delimiter, maxsplit, mr );
}

} // namespace strings
} // namespace cudf
