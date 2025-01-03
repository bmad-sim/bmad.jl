# utilities.jl
# Utility routines that involve structures from struct.jl
# Also see core.jl

#---------------------------------------------------------------------------------------------------
# lat_sanity_check

"""
    lat_sanity_check(lat::Lattice)

Does some self consistency checks on a lattice and throws an error if there is a problem.
""" lat_sanity_check

function lat_sanity_check(lat::Lattice)
  for (ib, branch) in enumerate(lat.branch)
    if ib != branch.ix_branch; error("SanityCheck: Branch with branch index: $ib has branch.ix_branch set to $(branch.ix_branch)"); end
    if lat !== branch.lat; error("SanityCheck: Branch $ib has branch.lat not pointing to parient lat."); end

    for (ie, ele) in enumerate(branch.ele)
      if ie != ele.ix_ele; error("SanityCheck: Ele $(ele.name) in branch $ib with"*
                                      " element index: $ie has ele.ix_ele set to $(ele.ix_ele)"); end

      if branch !== ele.branch; error("SanityCheck: Ele $(ele_name(ele)) has ele.branch not pointing to parient branch."); end

      if branch.type == TrackingBranch
        if !haskey(ele.pdict, :LengthParams) error("Sanity check: Ele $(ele_name(ele)) does not have a LengthParams group."); end
      end
    end
  end

end

#---------------------------------------------------------------------------------------------------
# Base.isless

"""
    Base.isless(a::Type{T1}, b::Type{T2}) where {T1 <: EleParameterParams, T2 <: EleParameterParams} -> Bool
    Base.isless(x::Type{T}, y::Type{U}) where {T <: Ele, U <: Ele} = isless(string(x), string(y)) -> Bool

Used to sort output alphabetically by name.
""" Base.isless

function Base.isless(a::Type{T1}, b::Type{T2}) where {T1 <: EleParameterParams, T2 <: EleParameterParams}
  return Symbol(a) < Symbol(b)
end

Base.isless(x::Type{T}, y::Type{U}) where {T <: Ele, U <: Ele} = isless(string(x), string(y))

#---------------------------------------------------------------------------------------------------
# eles_sort!

"""
  eles_sort!(vec_ele::Vector{T}; order::Order.T = Order.BY_S) where T <: Ele -> Vector{T}

Sort vector of elements.

If `order` is `Order.BY_INDEX`, sort in index order. That is, element `lat.branch[i].ele[j]` is sorted
based upon `i` and `j` with all elements of a given branch grouped together and then elements
of a given branch are sorted by `j` index

If 'order` is `Order.BY_S`, sort in increasing s-position. If more than one branch is involved, sort
is done branch-by-branch. Super or multipass lord elements are sorted with the branch they
are associated with. If a multipass lord is associated with multiple branches, it is placed
among the elements of the branch of its first slave.
""" eles_sort(vec_ele::Vector{T}) where T <: Ele

function eles_sort!(vec_ele::Vector{T}; order::Order.T = Order.BY_S) where T <: Ele
  if length(vec_ele) == 0 || order == Order.NONE; return vec_ele; end

  lat = lattice(vec_ele[1])
  bv = Vector(undef, length(lat.branch))  # Vector of element vectors one for each branch

  # sort eles in different branches

  for ele in vec_ele
    if order == Order.BY_S && (ele.lord_status == Lord.SUPER || ele.lord_status == Lord.MULTIPASS)
      sort_ele = ele.slaves[1]
      if sort_ele.lord_status == Lord.SUPER; sort_ele = ele.slaves[1]; end
    else
      sort_ele = ele
    end

    ix = sort_ele.branch.ix_branch
    if !isassigned(bv, ix)
      bv[ix] = Vector{@NamedTuple{ele::T, s::Float64}}([(ele, sort_ele.s)])
      continue
    end

    this_b = bv[ix]
    for ie in range(length(this_b), 0, step = -1)
      if ie == 0 || (order == Order.BY_S && this_b[ie].s < sort_ele.s) || 
                    (order == Order.BY_INDEX && this_b[ie].ele.ix_ele < sort_ele.ix_ele)
        insert!(this_b, ie+1, (ele, sort_ele.s))
        break
      elseif order == Order.BY_S && this_b[ie].s == sort_ele.s
        if this_b[ie].ele.ix_ele < sort_ele.ix_ele
          insert!(this_b, ie+1, (ele, sort_ele.s))
        else
          insert!(this_b, ie, (ele, sort_ele.s))
        end
        break
      end
    end
  end

  # Combine branches and return

  ie = 0
  for ib in range(1, length(bv))
    if !isassigned(bv, ib); continue; end
    for ee in bv[ib]
      ie += 1
      vec_ele[ie] = ee.ele
    end
  end

  return vec_ele
end

#---------------------------------------------------------------------------------------------------
# eles_substitute_lords!

"""
    eles_substitute_lords!(vec_ele::Vector{T}; remove_slaves = true) where T <: Ele -> Vector{T}

Add super and multipass lords to `vec_ele` for all slave elements in `vec_ele`.
An element that is both a super lord and a multipass slave is not added to the list
but the multipass lord of this element is.

If `remove_slaves` is true, remove the slave elements in `vec_ele`.

Note: lord elements are pushed to just after the corresponding slave.

""" eles_substitute_lords!

function eles_substitute_lords!(vec_ele::Vector{T}; remove_slaves = true) where T <: Ele
  # Search lord branches
  ie = 0
  while ie < length(vec_ele)
    ie += 1
    ele = vec_ele[ie]
    if ele.slave_status == Slave.SUPER
      for lord in ele.super_lords
        if lord.slave_status == Slave.MULTIPASS; lord = lord.multipass_lord; end
        if lord in vec_ele; continue; end
        insert(vec_ele, ie+1, lord)
      end
    elseif ele.slave_status == Slave.MULTIPASS
      lord = ele.multipass_lord
      if lord in vec_ele; continue; end
      insert!(vec_ele, ie+1, lord)
    end

    if remove_slaves && (ele.slave_status == Slave.SUPER || ele.slave_status == Slave.MULTIPASS)
      pop!(vec_ele, ie)
    end
  end

  return vec_ele
end

