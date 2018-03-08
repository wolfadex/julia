# This file is a part of Julia. License is MIT: https://julialang.org/license

nothing_sentinel(i) = i == 0 ? nothing : i

function findnext(pred::EqualTo{<:AbstractChar}, s::String, i::Integer)
    if i < 1 || i > sizeof(s)
        i == sizeof(s) + 1 && return nothing
        throw(BoundsError(s, i))
    end
    @inbounds isvalid(s, i) || string_index_err(s, i)
    c = pred.x
    c ≤ '\x7f' && return nothing_sentinel(_search(s, c % UInt8, i))
    while true
        i = _search(s, first_utf8_byte(c), i)
        i == 0 && return nothing
        s[i] == c && return i
        i = nextind(s, i)
    end
end

findfirst(pred::EqualTo{<:Union{Int8,UInt8}}, a::ByteArray) = nothing_sentinel(_search(a, pred.x))

findnext(pred::EqualTo{<:Union{Int8,UInt8}}, a::ByteArray, i::Integer) =
    nothing_sentinel(_search(a, pred.x, i))

function _search(a::Union{String,ByteArray}, b::Union{Int8,UInt8}, i::Integer = 1)
    if i < 1
        throw(BoundsError(a, i))
    end
    n = sizeof(a)
    if i > n
        return i == n+1 ? 0 : throw(BoundsError(a, i))
    end
    p = pointer(a)
    q = ccall(:memchr, Ptr{UInt8}, (Ptr{UInt8}, Int32, Csize_t), p+i-1, b, n-i+1)
    q == C_NULL ? 0 : Int(q-p+1)
end

function _search(a::ByteArray, b::AbstractChar, i::Integer = 1)
    if isascii(b)
        _search(a,UInt8(b),i)
    else
        _search(a,unsafe_wrap(Vector{UInt8},string(b)),i).start
    end
end

function findprev(pred::EqualTo{<:AbstractChar}, s::String, i::Integer)
    c = pred.x
    c ≤ '\x7f' && return nothing_sentinel(_rsearch(s, c % UInt8, i))
    b = first_utf8_byte(c)
    while true
        i = _rsearch(s, b, i)
        i == 0 && return nothing
        s[i] == c && return i
        i = prevind(s, i)
    end
end

findlast(pred::EqualTo{<:Union{Int8,UInt8}}, a::ByteArray) = nothing_sentinel(_rsearch(a, pred.x))

findprev(pred::EqualTo{<:Union{Int8,UInt8}}, a::ByteArray, i::Integer) =
    nothing_sentinel(_rsearch(a, pred.x, i))

function _rsearch(a::Union{String,ByteArray}, b::Union{Int8,UInt8}, i::Integer = sizeof(a))
    if i < 1
        return i == 0 ? 0 : throw(BoundsError(a, i))
    end
    n = sizeof(a)
    if i > n
        return i == n+1 ? 0 : throw(BoundsError(a, i))
    end
    p = pointer(a)
    q = ccall(:memrchr, Ptr{UInt8}, (Ptr{UInt8}, Int32, Csize_t), p, b, i)
    q == C_NULL ? 0 : Int(q-p+1)
end

function _rsearch(a::ByteArray, b::AbstractChar, i::Integer = length(a))
    if isascii(b)
        _rsearch(a,UInt8(b),i)
    else
        _rsearch(a,unsafe_wrap(Vector{UInt8},string(b)),i).start
    end
end

"""
    findfirst(pattern::AbstractString, string::AbstractString)
    findfirst(pattern::Regex, string::String)

Find the first occurrence of `pattern` in `string`. Equivalent to
[`findnext(pattern, string, firstindex(s))`](@ref).

# Examples
```jldoctest
julia> findfirst("z", "Hello to the world")
0:-1

julia> findfirst("Julia", "JuliaLang")
1:5
```
"""
findfirst(pattern::AbstractString, string::AbstractString) =
    findnext(pattern, string, firstindex(string))

findfirst(c::AbstractChar, s::AbstractString) = findfirst(equalto(c), s)

# AbstractString implementation of the generic findnext interface
function findnext(testf::Function, s::AbstractString, i::Integer)
    z = ncodeunits(s) + 1
    1 ≤ i ≤ z || throw(BoundsError(s, i))
    @inbounds i == z || isvalid(s, i) || string_index_err(s, i)
    for (j, d) in pairs(SubString(s, i))
        if testf(d)
            return i + j - 1
        end
    end
    return nothing
end

in(c::AbstractChar, s::AbstractString) = (findfirst(equalto(c),s)!==nothing)

function _searchindex(s::Union{AbstractString,ByteArray},
                      t::Union{AbstractString,AbstractChar,Int8,UInt8},
                      i::Integer)
    if isempty(t)
        return 1 <= i <= nextind(s,lastindex(s)) ? i :
               throw(BoundsError(s, i))
    end
    t1, trest = Iterators.peel(t)
    while true
        i = findnext(equalto(t1),s,i)
        if i === nothing return 0 end
        ii = nextind(s, i)
        a = Iterators.Stateful(trest)
        matched = all(splat(==), zip(SubString(s, ii), a))
        (isempty(a) && matched) && return i
        i = ii
    end
end

_searchindex(s::AbstractString, t::AbstractChar, i::Integer) = coalesce(findnext(equalto(t), s, i), 0)

function _search_bloom_mask(c)
    UInt64(1) << (c & 63)
end

_nthbyte(s::String, i) = codeunit(s, i)
_nthbyte(a::Union{AbstractVector{UInt8},AbstractVector{Int8}}, i) = a[i]

function _searchindex(s::String, t::String, i::Integer)
    # Check for fast case of a single byte
    lastindex(t) == 1 && return coalesce(findnext(equalto(t[1]), s, i), 0)
    _searchindex(unsafe_wrap(Vector{UInt8},s), unsafe_wrap(Vector{UInt8},t), i)
end

function _searchindex(s::ByteArray, t::ByteArray, i::Integer)
    n = sizeof(t)
    m = sizeof(s)

    if n == 0
        return 1 <= i <= m+1 ? max(1, i) : 0
    elseif m == 0
        return 0
    elseif n == 1
        return coalesce(findnext(equalto(_nthbyte(t,1)), s, i), 0)
    end

    w = m - n
    if w < 0 || i - 1 > w
        return 0
    end

    bloom_mask = UInt64(0)
    skip = n - 1
    tlast = _nthbyte(t,n)
    for j in 1:n
        bloom_mask |= _search_bloom_mask(_nthbyte(t,j))
        if _nthbyte(t,j) == tlast && j < n
            skip = n - j - 1
        end
    end

    i -= 1
    while i <= w
        if _nthbyte(s,i+n) == tlast
            # check candidate
            j = 0
            while j < n - 1
                if _nthbyte(s,i+j+1) != _nthbyte(t,j+1)
                    break
                end
                j += 1
            end

            # match found
            if j == n - 1
                return i+1
            end

            # no match, try to rule out the next character
            if i < w && bloom_mask & _search_bloom_mask(_nthbyte(s,i+n+1)) == 0
                i += n
            else
                i += skip
            end
        elseif i < w
            if bloom_mask & _search_bloom_mask(_nthbyte(s,i+n+1)) == 0
                i += n
            end
        end
        i += 1
    end

    0
end

function _search(s::Union{AbstractString,ByteArray},
                 t::Union{AbstractString,AbstractChar,Int8,UInt8},
                 i::Integer)
    idx = _searchindex(s,t,i)
    if isempty(t)
        idx:idx-1
    elseif idx > 0
        idx:(idx + lastindex(t) - 1)
    else
        nothing
    end
end

"""
    findnext(pattern::AbstractString, string::AbstractString, start::Integer)
    findnext(pattern::Regex, string::String, start::Integer)

Find the next occurrence of `pattern` in `string` starting at position `start`.
`pattern` can be either a string, or a regular expression, in which case `string`
must be of type `String`.

The return value is a range of indices where the matching sequence is found, such that
`s[findnext(x, s, i)] == x`:

`findnext("substring", string, i)` = `start:end` such that
`string[start:end] == "substring"`, or `nothing` if unmatched.

# Examples
```jldoctest
julia> findnext("z", "Hello to the world", 1) === nothing
true

julia> findnext("o", "Hello to the world", 6)
8:8

julia> findnext("Lang", "JuliaLang", 2)
6:9
```
"""
findnext(t::AbstractString, s::AbstractString, i::Integer) = _search(s, t, i)

"""
    findlast(pattern::AbstractString, string::AbstractString)
    findlast(pattern::Regex, string::String)

Find the last occurrence of `pattern` in `string`. Equivalent to
[`findlast(pattern, string, lastindex(s))`](@ref).

# Examples
```jldoctest
julia> findlast("o", "Hello to the world")
15:15

julia> findfirst("Julia", "JuliaLang")
1:5
```
"""
findlast(pattern::AbstractString, string::AbstractString) =
    findprev(pattern, string, lastindex(string))

# AbstractString implementation of the generic findprev interface
function findprev(testf::Function, s::AbstractString, i::Integer)
    if i < 1
        return i == 0 ? nothing : throw(BoundsError(s, i))
    end
    n = ncodeunits(s)
    if i > n
        return i == n+1 ? nothing : throw(BoundsError(s, i))
    end
    # r[reverseind(r,i)] == reverse(r)[i] == s[i]
    # s[reverseind(s,j)] == reverse(s)[j] == r[j]
    r = reverse(s)
    j = findnext(testf, r, reverseind(r, i))
    j === nothing ? nothing : reverseind(s, j)
end

function _rsearchindex(s::AbstractString,
                       t::Union{AbstractString,AbstractChar,Int8,UInt8},
                       i::Integer)
    if isempty(t)
        return 1 <= i <= nextind(s, lastindex(s)) ? i :
               throw(BoundsError(s, i))
    end
    t1, trest = Iterators.peel(Iterators.reverse(t))
    while true
        i = findprev(equalto(t1), s, i)
        i === nothing && return 0
        ii = prevind(s, i)
        a = Iterators.Stateful(trest)
        b = Iterators.Stateful(Iterators.reverse(
            pairs(SubString(s, 1, ii))))
        matched = all(splat(==), zip(a, (x[2] for x in b)))
        if matched && isempty(a)
            isempty(b) && return firstindex(s)
            return nextind(s, popfirst!(b)[1])
        end
        i = ii
    end
end

function _rsearchindex(s::String, t::String, i::Integer)
    # Check for fast case of a single byte
    if lastindex(t) == 1
        return coalesce(findprev(equalto(t[1]), s, i), 0)
    elseif lastindex(t) != 0
        j = i ≤ ncodeunits(s) ? nextind(s, i)-1 : i
        return _rsearchindex(unsafe_wrap(Vector{UInt8}, s), unsafe_wrap(Vector{UInt8}, t), j)
    elseif i > sizeof(s)
        return 0
    elseif i == 0
        return 1
    else
        return i
    end
end

function _rsearchindex(s::ByteArray, t::ByteArray, k::Integer)
    n = sizeof(t)
    m = sizeof(s)

    if n == 0
        return 0 <= k <= m ? max(k, 1) : 0
    elseif m == 0
        return 0
    elseif n == 1
        return coalesce(findprev(equalto(_nthbyte(t,1)), s, k), 0)
    end

    w = m - n
    if w < 0 || k <= 0
        return 0
    end

    bloom_mask = UInt64(0)
    skip = n - 1
    tfirst = _nthbyte(t,1)
    for j in n:-1:1
        bloom_mask |= _search_bloom_mask(_nthbyte(t,j))
        if _nthbyte(t,j) == tfirst && j > 1
            skip = j - 2
        end
    end

    i = min(k - n + 1, w + 1)
    while i > 0
        if _nthbyte(s,i) == tfirst
            # check candidate
            j = 1
            while j < n
                if _nthbyte(s,i+j) != _nthbyte(t,j+1)
                    break
                end
                j += 1
            end

            # match found
            if j == n
                return i
            end

            # no match, try to rule out the next character
            if i > 1 && bloom_mask & _search_bloom_mask(_nthbyte(s,i-1)) == 0
                i -= n
            else
                i -= skip
            end
        elseif i > 1
            if bloom_mask & _search_bloom_mask(_nthbyte(s,i-1)) == 0
                i -= n
            end
        end
        i -= 1
    end

    0
end

function _rsearch(s::Union{AbstractString,ByteArray},
                  t::Union{AbstractString,AbstractChar,Int8,UInt8},
                  i::Integer)
    idx = _rsearchindex(s,t,i)
    if isempty(t)
        idx:idx-1
    elseif idx > 0
        idx:(idx + lastindex(t) - 1)
    else
        nothing
    end
end

"""
    findprev(pattern::AbstractString, string::AbstractString, start::Integer)
    findprev(pattern::Regex, string::String, start::Integer)

Find the previous occurrence of `pattern` in `string` starting at position `start`.
`pattern` can be either a string, or a regular expression, in which case `string`
must be of type `String`.

The return value is a range of indices where the matching sequence is found, such that
`s[findprev(x, s, i)] == x`:

`findprev("substring", string, i)` = `start:end` such that
`string[start:end] == "substring"`, or `nothing` if unmatched.

# Examples
```jldoctest
julia> findprev("z", "Hello to the world", 18) === nothing
true

julia> findprev("o", "Hello to the world", 18)
15:15

julia> findprev("Julia", "JuliaLang", 6)
1:5
```
"""
findprev(t::AbstractString, s::AbstractString, i::Integer) = _rsearch(s, t, i)

"""
    contains(haystack::AbstractString, needle::Union{AbstractString,Regex,AbstractChar})

Determine whether the second argument is a substring of the first. If `needle`
is a regular expression, checks whether `haystack` contains a match.

# Examples
```jldoctest
julia> contains("JuliaLang is pretty cool!", "Julia")
true

julia> contains("JuliaLang is pretty cool!", 'a')
true

julia> contains("aba", r"a.a")
true

julia> contains("abba", r"a.a")
false
```
"""
function contains end

contains(haystack::AbstractString, needle::Union{AbstractString,AbstractChar}) =
    _searchindex(haystack, needle, firstindex(haystack)) != 0

in(::AbstractString, ::AbstractString) = error("use contains(x,y) for string containment")
