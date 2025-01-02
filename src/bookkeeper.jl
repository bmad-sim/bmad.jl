#---------------------------------------------------------------------------------------------------
# bookkeeper!(Lattice)

"""
    bookkeeper!(lat::Lattice)

All Lattice bookkeeping. For example, if the reference energy is changed at the start of a branch the 
bookkeeping code will propagate that change through the reset of the lattice. 
""" bookkeeper!(lat::Lattice)

function bookkeeper!(lat::Lattice)
  if !lat.parameters_have_changed; return; end
  lat.parameters_have_changed = false
  push_bookkeeping_state!(lat, autobookkeeping = false, auditing_enabled = false)

  try
    # Tracking branch bookkeeping
    for (ix, branch) in enumerate(lat.branch)
      if branch.type != TrackingBranch; continue; end
      branch.pdict[:ix_branch] = ix
      bookkeeper_tracking_branch!(branch)
    end

    # Check for unbookkeeped parameters
    for branch in lat.branch
      for ele in branch.ele
        for param in keys(ele.pdict[:changed])
          println("WARNING! Unbookkeeped parameter: $(repr(param)) in element $(ele_name(ele)). Please report this!")
        end
      end
    end

  catch this_err
    pop_bookkeeping_state!(lat)
    rethrow(this_err)
  end

  pop_bookkeeping_state!(lat)
  return
end

#---------------------------------------------------------------------------------------------------
# check_if_settable

"""
    Internal: check_is_settable(ele::Ele, sym::Symbol, pinfo::Union{ParamInfo, Nothing})

Check that it is valid to have varied element parameters.
For example, parameters of a super slave element cannot be directly changed.
Or dependent parameters cannot be directly changed.
""" check_if_settable

function check_if_settable(ele::Ele, sym::Symbol, pinfo::Union{ParamInfo, Nothing})
  branch = lat_branch(ele)
  lat = lattice(ele)
  if !isnothing(lat) && !lat.auditing_enabled; return; end

  if !isnothing(lat)
    if get(ele, :slave_status, 0) == Slave.MULTIPASS || get(ele, :slave_status, 0) == Slave.SUPER
      if sym == :multipass_phase; return; end
      error("Changing component $sym in multipass or super slave $(ele_name(ele)) not allowed.")
    end
  end

  if sym in DEPENDENT_ELE_PARAMETERS
    error("Parameter is not user settable: $sym. For element: $(ele_name(ele)).")
  end

  return
end

#---------------------------------------------------------------------------------------------------
# bookkeeper_tracking_branch!(Branch)

"""
    Internal: bookkeeper_tracking_branch!(branch::Branch)

Branch bookkeeping. This function is called by `bookkeeper_tracking_branch!(lat::Lattice)`.
This processes tracking branches only. Lord branches are ignored.
""" bookkeeper_tracking_branch!(branch::Branch)

function bookkeeper_tracking_branch!(branch::Branch)
  if branch.pdict[:type] == LordBranch; return; end

  ix_min = branch.pdict[:ix_ele_min_changed]
  if ix_min > length(branch.ele); return; end
  ix_min == 1 ? previous_ele = NULL_ELE : previous_ele = branch.ele[ix_min-1]
  ix_max = branch.pdict[:ix_ele_max_changed]
  changed = ChangedLedger()

  for ele in branch.ele[ix_min:end]
    # If UnionEle or the first super slave then process super lord(s).
    if typeof(ele) == UnionEle
      bookkeeper_unionele!(ele, changed, previous_ele)
    elseif ele.slave_status == Slave.SUPER
      bookkeeper_superslave!(ele, changed, previous_ele)
    elseif ele.slave_status == Slave.MULTIPASS
      bookkeeper_multipass_slave!(ele, changed, previous_ele)
    else
      bookkeeper_ele!(ele, changed, previous_ele)
    end

    previous_ele = ele
    if ix_max > 0 && ele.ix_ele == ix_max && changed == ChangedLedger(); break; end
  end

  branch.pdict[:ix_ele_min_changed] = typemax(Int)
  branch.pdict[:ix_ele_max_changed] = 0

  return
end

#---------------------------------------------------------------------------------------------------
# bookkeeper_ele!(ele, changed, previous_ele)

"""
    Internal: bookkeeper_ele!(ele::Ele, changed::ChangedLedger, previous_ele::Ele)

Lattice element bookkeeping. For example, propagating the floor geometry from one element to the next. 
These low level routines (there are several with this signature) are called via `bookkeeper!(lat::Lattice)`.

## Arguments

- `ele`           -- Element to do bookkeeping on.
- `previous_ele`  -- Element in the branch before `ele`. Will be `NULL_ELE` if this is the first branch element.
""" bookkeeper_ele!(ele::Ele)

function bookkeeper_ele!(ele::Ele, changed::ChangedLedger, previous_ele::Ele)
  for group in PARAM_GROUPS_LIST[typeof(ele)]
    if !haskey(ELE_PARAM_GROUP_INFO, group) || !ELE_PARAM_GROUP_INFO[group].bookkeeping_needed; continue; end

    try
      elegroup_bookkeeper!(ele, group, changed, previous_ele)
    catch this_err
      reinstate_changed!(ele, group)    # Try to undo the dammage.
      rethrow(this_err)
    end
  end

  # Throw out changed parameters that don't need bookkeeping

  cdict = ele.pdict[:changed]

  for param in copy(keys(cdict))
    if typeof(param) != Symbol    # Something like param = `ReferenceGroup`
      group = param
    else
      pinfo = ele_param_info(param, throw_error = false)
      if isnothing(pinfo); continue; end
      group = pinfo.parent_group
    end

    if group in keys(ELE_PARAM_GROUP_INFO) && !ELE_PARAM_GROUP_INFO[group].bookkeeping_needed
      pop!(cdict, param)
    end
  end

  if AllGroup in keys(cdict); pop!(cdict, AllGroup); end
  return
end

#---------------------------------------------------------------------------------------------------
# bookkeeper_unionele!

function bookkeeper_unionele!(ele::Ele, changed::ChangedLedger, previous_ele::Ele)
  for lord in ele.super_lords
    bookkeeper_ele!(ele, changed, previous_ele) 
  end

  return
end

#---------------------------------------------------------------------------------------------------
# bookkeeper_superslave!

"""
    Internal: bookkeeper_superslave!(slave::Ele, changed::ChangedLedger, previous_ele::Ele)

Internal bookkeeping for a non-`UnionEle` super slave.
""" bookkeeper_superslave!

function bookkeeper_superslave!(slave::Ele, changed::ChangedLedger, previous_ele::Ele)
  # A non-UnionEle super slave has only one lord
  lord = slave.super_lords[1]
  ix_slave = slave_index(slave)
  L_rel = slave.L / lord.L

  # Bookkeeping of the super lord is only done if the slave is the first superslave of the lord.
  if ix_slave == 1
    bookkeeper_ele!(lord, changed, previous_ele) 
  end

  # Transfer info from lord to slave
  for group in PARAM_GROUPS_LIST[typeof(lord)]
    if group == LengthGroup; continue; end     # Do not modify length of slave
    if group == DownstreamReferenceGroup; continue; end
    if group == OrientationGroup; continue; end
    if group == LordSlaveStatusGroup; continue; end

    group_changed = has_changed(lord, group)
    if group_changed && group != AlginmentGroup
      slave.pdict[Symbol(group)] = copy(lord.pdict[Symbol(group)])
      slave.pdict[:changed][group] = "changed"
    end

    # Note: BodyLoc.CENTER cannot be handled. 
    # Possible solution: Add aperture_offset parameter to group.
    if group == ApertureGroup && group_changed && length(lord.slaves) > 1
      lord.orientation == 1 ? ixs = ix_slave : ixs = length(lord.slaves) + 1 - ix_slave
      if slave.aperture_at == BodyLoc.ENTRANCE_END
        if ixs > 1; slave.aperture_at = BodyLoc.NOWHERE; end
      elseif slave.aperture_at == BodyLoc.EXIT_END
        if ixs > length(lord.slaves); slave.aperture_at = BodyLoc.NOWHERE; end
      elseif slave.aperture_at == BodyLoc.BOTH_ENDS
        if ixs == 1
          slave.aperture_at = BodyLoc.ENTRANCE_END
        elseif ixs == length(lord.slaves)
          slave.aperture_at = BodyLoc.EXIT_END
        else
          slave.aperture_at = BodyLoc.NOWHERE
        end
      end
    end

    if group == EMultipoleGroup && (group_changed ||changed.this_ele_length)
      for (ix, elord) in enumerate(lord.pdict[:EMultipoleGroup].pole)
        if !elord.Eintegrated; continue; end
        eslave = deepcopy(slave.pdict[:EMultipoleGroup].pole[ix])
        eslave.En = elord.En * L_rel
        eslave.Es = elord.Es * L_rel
      end
    end

    if group == TrackingGroup && (group_changed ||changed.this_ele_length)
      if lord.num_steps > 0
        slave.num_steps = nint(lord.num_steps * L_rel)
      end
    end

    if group == AlignmentGroup && (group_changed ||changed.this_ele_length)
      if haskey(lord.pdict, :BendGroup)
        bgl = lord.pdict[:BendGroup]
        bgs = slave.pdict[:BendGroup]
        # Need transformation from lord alignment point to slave alignment point
        # Translate from lord alignment point to beginning of lord point
        ct = OrientationGroup(r = [0.0, 0.0, -0.5*bgl.l_chord])
        # Rotate from z parallel to lord chord to z tangent to bend curve.
        ct = rot(ct, bend_quaternion(-0.5*bgl.angle, bg.ref_tilt))
        # Transform from beginning of lord to beginning of slave
        ct = coord_transform(slave.s - lord.s, bgl.g, bgl.ref_tilt)
        # Rotate from z tangent to bend curve to z parallel to slave chord.
        ct = rot(ct, bend_quaternion(0.5*bgs.angle, bg.ref_tilt))
        # translate from beginning of slave to center of slave chord.
        ct.r = ct.r + [0.0, 0.0, 0.5*bgs.l_chord]
        # Apply total transformation of AlignmentGroup.
        slave.AlignmentGroup = coord_transform(lord.pdict[:AlignmentGroup], ct)
      end
    end
  end

  # Now bookkeep the slave
  bookkeeper_ele!(slave, changed, previous_ele)  # In case slave parameters have changed.

  # If last slave of lord, clear lord.changed dict.
  if ix_slave == length(lord.slaves); lord.pdict[:changed] = Dict{Symbol,Any}(); end

  return
end

#---------------------------------------------------------------------------------------------------
# bookkeeper_multipass_slave!(ele, changed, previous_ele)

"""
    Internal: bookkeeper_multipass_slave!(slave::Ele, changed::ChangedLedger, previous_ele::Ele)

Internal bookkeeping for multipass slave.

""" bookkeeper_multipass_slave!

function bookkeeper_multipass_slave!(slave::Ele, changed::ChangedLedger, previous_ele::Ele)
  lord = slave.multipass_lord
  cdict = lord.changed

  ## To Do: Bookkeep the lord. What is the reference energy?

  # Transfer info from lord to slave
  for param in copy(keys(lord.pdict[:changed]))
    if typeof(param) != Symbol; continue; end
    pinfo = ele_param_info(param)
    if isnothing(pinfo); continue; end
    group = pinfo.parent_group
    if group ∉ keys(ELE_PARAM_GROUP_INFO); continue; end  # Ignore custom stuff
    if group == LengthGroup; continue; end     # Do not modify length of slave
    if group == ReferenceGroup; continue; end  # Slave ReferenceGroup independent of lord
    if group == DownstreamReferenceGroup; continue; end

    slave.pdict[Symbol(group)] = deepcopy(lord.pdict[Symbol(group)])
    slave.pdict[:changed][group] = "changed"
  end

  # Now bookkeep the slave
  changed2 = ChangedLedger()
  bookkeeper_ele!(slave, changed2, previous_ele)  # In case slave parameters have changed.

  # If last slave of lord, clear lord.changed dict.
  if lord.slaves[end] == slave; lord.pdict[:changed] = Dict{Symbol,Any}(); end

  return
end

#---------------------------------------------------------------------------------------------------
# index_and_s_bookkeeper!(Branch)

"""
    Internal: index_and_s_bookkeeper!(branch::Branch, ix_start = 1)

Does "quick" element index and s-position bookkeeping for a given branch starting
at index `ix_start` to the end of `branch.ele`.

  Used by lattice manipulation routines that need reindexing but do not need (or want) a full bookkeeping.
""" index_and_s_bookkeeper!

function index_and_s_bookkeeper!(branch::Branch, ix_start = 1)
  for ix in range(ix_start, length(branch.ele))
    pdict = branch.ele[ix].pdict
    pdict[:ix_ele] = ix
    pdict[:branch] = branch
  end

  if branch.type <: LordBranch; return; end

  ix_start == 1 ?  s_now = branch.ele[ix_start].s : s_now = branch.ele[ix_start-1].s_downstream
  for ix in range(ix_start, length(branch.ele))
    ele = branch.ele[ix]
    set_param!(ele, :s, s_now)
    s_now = s_now + ele.L
    set_param!(ele, :s_downstream, s_now)
  end

  return
end

#---------------------------------------------------------------------------------------------------
# param_conflict_check

"""
    param_conflict_check(ele::Ele, syms...)

Checks if there is a symbol conflict in `ele`.
A symbol conflict occurs when two keys in `ele.changed[]` are not allowed to both be simultaneously set.
For example, `L` and `L_chord` for a `Bend` cannot be simultaneously set.

Returns an array of the names of the parameters present. 
"""  param_conflict_check

function param_conflict_check(ele::Ele, syms...)
  sym_in = []

  for sym in syms
    if haskey(ele.changed, sym); push!(sym_in, sym); end
  end
  if length(sym_in) > 1; error(f"Conflict: {s[1]} and {s[2]} cannot both " * 
                                    f"be specified for a {typeof(ele)} element: {ele.name}"); end
  return sym_in

  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{T}, ...)
# Essentially no bookkeeping is needed for groups not covered by a specific method.

function elegroup_bookkeeper!(ele::Ele, group::Type{T}, changed::ChangedLedger, 
                                      previous_ele::Ele) where T <: EleParameterGroup
  clear_changed!(ele, group)
  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{BMultipoleGroup}, ...)
# BMultipoleGroup bookkeeping.

function elegroup_bookkeeper!(ele::Ele, group::Type{BMultipoleGroup}, changed::ChangedLedger, previous_ele::Ele)
  bmg = ele.BMultipoleGroup
  cdict = ele.changed
  if !has_changed(ele, BMultipoleGroup) && !changed.this_ele_length && !changed.ref_group; return; end

  ff = ele.pc_ref / (C_LIGHT * charge(ele.species_ref))

  if ele.slave_status == Slave.SUPER
    lord = ele.super_lords[1]
    L_rel = ele.L / lord.L
    for (ix, lpole) in enumerate(lord.pdict[:BMultipoleGroup].pole)
      epole = deepcopy(ele.pdict[:BMultipoleGroup].pole[ix])
      if lpole.integrated
        epole.Kn = lpole.Kn * L_rel
        epole.Bn = lpole.Bn * L_rel
        epole.Ks = lpole.Ks * L_rel
        epole.Bs = lpole.Bs * L_rel
      else
        ele.pdict[:BMultipoleGroup].pole[ix] = deepcopy(lpole)
      end
    end

  # Not a slave case
  else
    for param in keys(cdict)
      if typeof(param) == DataType; continue; end
      (mtype, order, group) = multipole_type(param)
      if isnothing(group) || group != BMultipoleGroup || mtype == "tilt"; continue; end
      mul = multipole!(bmg, order)

      if     mtype[1:2] == "Kn"; mul.Bn = mul.Kn * ff
      elseif mtype[1:2] == "Ks"; mul.Bs = mul.Ks * ff
      elseif mtype[1:2] == "Bn"; mul.Kn = mul.Bn / ff
      elseif mtype[1:2] == "Bs"; mul.Ks = mul.Bs / ff
      end
    end

    # Update multipoles if the reference energy has changed.
    if changed.ref_group
      if ele.field_master
        for mul in bmg.pole
          mul.Kn = mul.Bn / ff
          mul.Ks = mul.Bs / ff
        end
      else
        for mul in bmg.pole
          mul.Bn = mul.Kn * ff
          mul.Bs = mul.Ks * ff
        end
      end
    end
  end

  clear_changed!(ele, BMultipoleGroup)
  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{BendGroup}, ...)
# BendGroup bookkeeping.

function elegroup_bookkeeper!(ele::Ele, group::Type{BendGroup}, changed::ChangedLedger, previous_ele::Ele)
  bg = ele.BendGroup
  cdict = ele.changed

  if !has_changed(ele, BendGroup) && !changed.this_ele_length && !changed.ref_group; return; end

  if ele.slave_status == Slave.SUPER
    lord = ele.super_lords[1]
    L_rel = ele.L / lord.L
    ix_slave = slave_index(ele)
    ele.BendGroup = copy(lord.BendGroup)
    bg = ele.BendGroup
    bg.angle = lord.angle * L_rel
    if ix_slave < length(lord.slaves)
      bg.e2 = 0
      bg.e2_rect = 0.5 * bg.angle
    elseif ix_slave > 1
      bg.e1 = 0
      bg.e1_rect = 0.5 * bg.angle
    end
    ele.g == 0 ? ele.L_chord = ele.L : ele.L_chord = 2 * sin(ele.angle/2) / ele.g 

  # Not a slave
  else
    sym1 = param_conflict_check(ele, :L, :L_chord)
    param_conflict_check(ele, :e1, :e1_rect)
    param_conflict_check(ele, :e2, :e2_rect)

    if haskey(cdict, :angle) && haskey(cdict, :g) && length(sym1) == 1
      error("Conflict: $(sym1[1]), g, and angle cannot simultaneously be specified for a Bend element $(ele.name)"); end

    if  haskey(cdict, :angle) && haskey(cdict, :g)
      L = bg.g * bg.angle
    elseif haskey(cdict, :angle) && haskey(cdict, :L_chord)
      if bg.L_chord == 0 && bg.angle != 0; 
                          error(f"Bend cannot have finite angle and zero length: {ele_name(ele)}"); end
      bg.angle == 0 ? bg.g = 0.0 : bg.g = 2.0 * sin(bg.angle/2) / bg.L_chord
      L = bg.angle * bg.g
    elseif haskey(cdict, :angle)
      L = ele.L
      if L == 0 && bg.angle != 0; error(f"Bend cannot have finite angle and zero length: {ele_name(ele)}"); end
        bg.angle == 0 ? bg.g = 0 : bg.g = bg.angle / L
    else
      L = ele.L
      bg.angle = L * bg.g
    end

    bg.bend_field_ref = bg.g * ele.pc_ref / (C_LIGHT * charge(ele.species_ref))

    if haskey(cdict, :L_chord)
      bg.angle = 2 * asin(bg.L_chord * bg.g / 2)
      bg.g == 0 ? bg.L =  bg.L_chord : bg.L = bg.angle / bg.g
    else
      bg.angle = L * bg.g
      bg.g == 0 ? bg.L_chord = L : bg.L_chord = 2 * sin(bg.angle/2) / bg.g 
    end

    if ele.L != L
      ele.L = L
      elegroup_bookkeeper!(ele, LengthGroup, changed, previous_ele)
    end

    if haskey(cdict, :e1)
      bg.e1_rect = bg.e1 - 0.5 * bg.angle
    elseif haskey(cdict, :e1_rect)
      bg.e1 = bg.e1_rect + 0.5 * bg.angle
    elseif bg.bend_type == BendType.SECTOR
      bg.e1_rect = bg.e1 + 0.5 * bg.angle
    else
      bg.e1 = bg.e1_rect - 0.5 * bg.angle
    end

    if haskey(cdict, :e2)
      bg.e2_rect = bg.e2 - 0.5 * bg.angle
    elseif haskey(cdict, :e2_rect)
      bg.e2 = bg.e2_rect + 0.5 * bg.angle
    elseif bg.bend_type == BendType.SECTOR
      bg.e2_rect = bg.e2 + 0.5 * bg.angle
    else
      bg.e2 = bg.e2_rect - 0.5 * bg.angle
    end

    clear_changed!(ele, BendGroup)
  end

  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{LengthGroup}, ...)
# Low level LengthGroup bookkeeping.

function elegroup_bookkeeper!(ele::Ele, group::Type{LengthGroup}, changed::ChangedLedger, previous_ele::Ele)
  lg = ele.LengthGroup
  cdict = ele.changed

  if haskey(cdict, :L)
    changed.this_ele_length = true
    changed.s_position = true
    pop!(cdict, :L)
  end

  if is_null(previous_ele)
    if haskey(cdict, :s)
      changed.s_position = true
      pop!(cdict, :s)
    end

    lg.s_downstream = lg.s + lg.L
    return
  end

  if !changed.s_position && !changed.this_ele_length; return; end

  lg.s = previous_ele.s_downstream
  lg.s_downstream = lg.s + lg.L

  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{RFGroup}, ...)

"""
    elegroup_bookkeeper!(ele::Ele, group::Type{RFGroup}, changed::ChangedLedger, previous_ele::Ele)

`RFGroup` bookkeeping.
"""

function elegroup_bookkeeper!(ele::Ele, group::Type{RFGroup}, changed::ChangedLedger, previous_ele::Ele)
  rg = ele.RFGroup
  cdict = ele.changed

  if !has_changed(ele, RFGroup) && !has_changed(ele, ReferenceGroup) && !changed.this_ele_length
    return
  end

  if ele.slave_status == Slave.SUPER
    lord = ele.super_lords[1]
    L_rel = ele.L / lord.L
    rg.voltage = lord.voltage * L_rel
  end

  if ele.field_master
    rg.voltage = rg.gradient * ele.L
  elseif ele.L == 0
    rg.gradient = NaN
  else
    rg.gradient = rg.voltage / ele.L
  end

  clear_changed!(ele, RFGroup)
  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{ReferenceGroup}, ...)

"""
    elegroup_bookkeeper!(ele::Ele, group::Type{ReferenceGroup}, changed::ChangedLedger, previous_ele::Ele)

`ReferenceGroup` bookkeeping. This also includes `DownstreamReferenceGroup` bookkeeping.
"""

function elegroup_bookkeeper!(ele::Ele, group::Type{ReferenceGroup}, changed::ChangedLedger, previous_ele::Ele)
  rg = ele.ReferenceGroup
  drg = ele.DownstreamReferenceGroup
  cdict = ele.changed

  if has_changed(ele, ReferenceGroup); changed.ref_group = true; end

  if ele.slave_status == Slave.SUPER
    lord = ele.super_lords[1]
    L_rel = ele.L / lord.L
    ele.dE_ref = lord.dE_ref * L_rel
    ele.extra_dtime_ref = lord.extra_dtime_ref * L_rel
  end

  #

  if is_null(previous_ele)   # implies BeginningEle
    if !changed.ref_group; return; end
    if rg.species_ref == Species(); error(f"Species not set for first element in branch: {ele_name(ele)}"); end
    drg.species_ref_downstream = rg.species_ref

    rg.time_ref_downstream = rg.time_ref + rg.extra_dtime_ref

    if count([haskey(cdict, :pc_ref), haskey(cdict, :E_tot_ref), haskey(cdict, :β_ref), haskey(cdict, :γ_ref)]) > 1
      error(f"Beginning element has more than one of pc_ref, E_tot_ref, β_ref, and γ_ref set in {ele_name(ele)}")
    elseif haskey(cdict, :E_tot_ref)
      rg.pc_ref = calc_pc(rg.species_ref, E_tot = rg.E_tot_ref)
    elseif haskey(cdict, :pc_ref)
      rg.E_tot_ref = calc_E_tot(rg.species_ref, pc = rg.pc_ref)
    elseif haskey(cdict, :β_ref)
      rg.pc_ref = calc_pc(rg.species_ref, β = rg.γ_ref)
      rg.E_tot_ref = calc_E_tot(rg.species_ref, pc = rg.pc_ref)
    elseif haskey(cdict, :γ_ref)
      rg.pc_ref = calc_pc(rg.species_ref, β = rg.γ_ref)
      rg.E_tot_ref = calc_E_tot(rg.species_ref, pc = rg.pc_ref)
    else
      error("Neither pc_ref E_tot_ref, β_ref, nor γ_ref set for: $(ele_name(ele))")
    end

    drg.pc_ref_downstream = rg.pc_ref
    drg.E_tot_ref_downstream = rg.E_tot_ref

    clear_changed!(ele, ReferenceGroup)
    return
  end

  # Propagate from previous ele

  if !changed.this_ele_length && !changed.ref_group; return; end

  old_drg = copy(drg)

  rg.pc_ref           = previous_ele.pc_ref_downstream
  rg.E_tot_ref        = previous_ele.E_tot_ref_downstream
  rg.time_ref         = previous_ele.time_ref_downstream
  rg.species_ref      = previous_ele.species_ref_downstream
  drg.species_ref_downstream = rg.species_ref

  if rg.dE_ref == 0
    drg.pc_ref_downstream      = rg.pc_ref
    drg.E_tot_ref_downstream   = rg.E_tot_ref
    rg.time_ref_downstream     = rg.time_ref + rg.extra_dtime_ref + ele.L * rg.E_tot_ref / (C_LIGHT * rg.pc_ref)
  else
    drg.pc_ref_downstream, drg.E_tot_ref_downstream = calc_changed_energy(rg.species_ref, rg.pc_ref, rg.dE_ref)
    rg.time_ref_downstream     = rg.time_ref + rg.extra_dtime_ref + ele.L *
             (rg.E_tot_ref + drg.E_tot_ref_downstream) / (C_LIGHT * (rg.pc_ref + drg.pc_ref_downstream))
  end

  # Multipass lord bookkeeping if this is a slave

  if ele.slave_status == Slave.MULTIPASS
    lord = ele.pdict[:multipass_lord]
    if lord.pdict[:slaves][1] === ele 
      lord.ReferenceGroup = rg
      haskey(lord.pdict, :changed) ? lord.changed = Dict(ReferenceGroup => "changed") : 
                                                           lord.changed[ReferenceGroup] = "changed" 
    end
  end

  # End stuff

  clear_changed!(ele, ReferenceGroup)
  changed.ref_group = (old_drg != drg)

  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{OrientationGroup}, ...)
# OrientationGroup bookkeeper

function elegroup_bookkeeper!(ele::Ele, group::Type{OrientationGroup}, 
                                              changed::ChangedLedger, previous_ele::Ele)
  fpg = ele.OrientationGroup
  cdict = ele.changed

  if has_changed(ele, OrientationGroup) || changed.this_ele_length; changed.floor_position = true; end
  if !changed.floor_position; return; end

  ele.OrientationGroup = propagate_ele_geometry(previous_ele)
  clear_changed!(ele, OrientationGroup)

  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{SolenoidGroup}, ...)
# SolenoidGroup bookkeeping.

function elegroup_bookkeeper!(ele::Ele, group::Type{SolenoidGroup}, changed::ChangedLedger, previous_ele::Ele)
  sg = ele.SolenoidGroup
  cdict = ele.changed
  if !has_changed(ele, SolenoidGroup) && !changed.ref_group; return; end

  ff = ele.pc_ref / (C_LIGHT * charge(ele.species_ref))

  if has_key(cdict, :Ksol)
    sg.Bsol = sg.Ksol * ff
  elseif has_key(cdict, :Bsol)
    sg.Ksol = sg.Bsol / ff
  elseif ele.field_master   # Ref energy has changed
    sg.Ksol = sg.Bsol / ff
  else
    sg.Bsol = sg.Ksol * ff
  end

  clear_changed!(ele, SolenoidGroup)
  return
end

#---------------------------------------------------------------------------------------------------
# elegroup_bookkeeper!(ele::Ele, group::Type{TrackingGroup}, ...)
# Low level LengthGroup bookkeeping.

function elegroup_bookkeeper!(ele::Ele, group::Type{TrackingGroup}, changed::ChangedLedger, previous_ele::Ele)
  tg = ele.TrackingGroup
  cdict = ele.changed

  if haskey(cdict, :num_steps)
    pop!(cdict, :num_steps)
    tg.ds_step = ele.L / tg.num_steps
  end

  if haskey(cdict, :ds_step)
    pop!(cdict, :ds_step)
    tg.num_steps = ele.L / tg.ds_step
  end

  return
end

#---------------------------------------------------------------------------------------------------
# has_changed

"""
    has_changed(ele::Ele, group::Type{T}) where T <: EleParameterGroup -> Bool

Has any parameter in `group` changed since the last bookkeeping?
"""

function has_changed(ele::Ele, group::Type{T}) where T <: EleParameterGroup
  if ele.slave_status == Slave.SUPER
    lord = ele.super_lords[1]         # UnionEle slave handled elsewhere.
    for param in keys(lord.changed)
      if param == AllGroup; return true; end
      if param == group; return true; end
      info = ele_param_info(param, lord, throw_error = false)
      if isnothing(info); continue; end
      if info.parent_group == group; return true; end
    end
  end

  for param in keys(ele.changed)
    if param == AllGroup; return true; end
    if param == group; return true; end
    info = ele_param_info(param, ele, throw_error = false)
    if isnothing(info); continue; end
    if info.parent_group == group; return true; end
  end

  return false
end

#---------------------------------------------------------------------------------------------------
# clear_changed!

"""
    clear_changed!(ele::Ele, group::Type{T}; clear_lord::Bool = false) where T <: EleParameterGroup
    clear_changed!(ele::Ele)

Clear record of any parameter in `ele` as having been changed that is associated with `group`.
If group is not present, clear all records.

Exception: A super lord or multipasslord is not touched since these lords must retain changed
information until bookkeeping has finished for all slaves. The appropriate lord/slave
bookkeeping code will handle this.
""" clear_changed!

function clear_changed!(ele::Ele, group::Type{T}; clear_lord::Bool = false) where T <: EleParameterGroup
  if !clear_lord && (ele.lord_status == Lord.SUPER || 
                     ele.lord_status == Lord.MULTIPASS); return; end

  for param in keys(ele.changed)
    if param == group
      pop!(ele.changed, param)
    else
      info = ele_param_info(param, ele, throw_error = false)
      if isnothing(info) || info.parent_group != group; continue; end
      pop!(ele.changed, param)
    end
  end

  return
end

function clear_changed!(ele::Ele)
  ele.pdict[:changed] = Dict{Union{Symbol,DataType},Any}()
end

#---------------------------------------------------------------------------------------------------
# reinstate_changed

"""
Reinstate values for parameters associated with `group`.
This is used to try to back out of changes that cause an error.
"""

function reinstate_changed!(ele::Ele, group::Type{T}) where T <: EleParameterGroup
  for param in keys(ele.changed)
    info = ele_param_info(param, ele, throw_error = false)
    if isnothing(info) || info.parent_group != group; continue; end
    Base.setproperty!(ele, param, ele.changed[param], false)
  end

  return
end

#---------------------------------------------------------------------------------------------------
# init_multipass_bookkeeper!

"""
    Internal: init_multipass_bookkeeper!(lat::Lattice)

Multipass initialization done during lattice expansion.
""" init_multipass_bookkeeper!

function init_multipass_bookkeeper!(lat::Lattice)
  # Sort slaves. multipass_id is an identification tag to enable identifying the set of slaves
  # for a given lord. multipass_id is removed here since it will be no longer needed.
  # The Dict is ordered so that the order of the lords in the lord branch is deterministic.
  # [Note: The id vector contains strings generated by Random and is not deterministic but this is OK.]

  mdict = OrderedDict()
  multipass_branch = lat.branch["multipass"]

  for branch in lat.branch
    for ele in branch.ele
      id = ele.pdict[:multipass_id]
      delete!(ele.pdict, :multipass_id)
      if length(id) == 0; continue; end
      if haskey(mdict, id)
        push!(mdict[id], ele)
      else
        mdict[id] = [ele]
      end
    end
  end

  # Create multipass lords.
  for (key, val) in mdict
    push!(multipass_branch.ele, deepcopy(val[1]))
    lord = multipass_branch.ele[end]
    delete!(lord.pdict, :multipass_id)
    lord.pdict[:branch] = multipass_branch
    lord.pdict[:ix_ele] = length(multipass_branch.ele)
    lord.pdict[:slaves] = Ele[]
    lord.lord_status = Lord.MULTIPASS
    for (ix, ele) in enumerate(val)
      ele.name = ele.name * "!mp" * string(ix)
      ele.pdict[:multipass_lord] = lord
      ele.slave_status = Slave.MULTIPASS
      if haskey(ele.pdict, :MasterGroup); ele.field_master = true; end
      push!(lord.pdict[:slaves], ele)
    end
  end

  return
end

#---------------------------------------------------------------------------------------------------
# fork_bookkeeper

"""
  fork_bookkeeper(fork::Ele)

Adds the `Branch` that is forked to to the lattice.
""" fork_bookkeeper

function fork_bookkeeper(fork::Ele)
  # No to_line means fork to existing element.
  if isnothing(fork.to_line)
    if typeof(fork.to_ele) != Ele; error("Since to_line is not specified for fork $(fork.name),\n" *
                                         "to_ele must be an actual element in a lattice."); end
    lat = lattice(ele)
    if isnothing(lat); error("Since to_line is not specified for fork $(fork.name),\n" *
                             "to_ele must be in a lattice and not external."); end

  # Fork to new branch
  else
    to_branch = new_tracking_branch!(lat, fork.to_line)
    if typeof(fork.to_ele) == Ele; error(
      "Since to_line is specified, to_ele must be something (String, Regex) that can be used with \n" *
      "the `find` function to locate the element in the new branch and cannot be an existing element."); end
    to_ele = find(fork.to_ele)
    if length(to_ele) == 0; error("to_ele ($(fork.to_ele)) not found in new branch for fork $(fork.name)."); end
    if length(to_ele) > 1; error("Multiple elements matched to to_ele ($(fork.to_ele)) for fork $(fork.name)."); end
    fork.to_ele = to_ele[1]

    to_ele = fork.to_ele
    if to_ele.ix_ele == 1
      if to_ele.species_ref == Species("Null"); to_ele.species_ref = fork.species_ref; end
      if to_ele.pc_ref == NaN && to_ele.E_tot_ref == NaN
        to_ele.pc_ref = fork.pc_ref
        to_ele.E_tot_ref = fork.pc_ref
      end
    end
  end

  return
end

#---------------------------------------------------------------------------------------------------
# push_bookkeeping_state

"""
    push_bookkeeping_state!(lat::Lattice; auditing_enabled::Union{Bool,Nothing} = nothing, 
                                autobookkeeping::Union{Bool,Nothing} = nothing)

Push the current state of `auditing_enabled` and `autobookkeeping` onto a saved state stack and set
these parameters to the corresponding arguments if the arguments are not `nothing`.
""" push_bookkeeping_state!

function push_bookkeeping_state!(lat::Lattice; auditing_enabled::Union{Bool,Nothing} = nothing, 
                                     autobookkeeping::Union{Bool,Nothing} = nothing)
  push!(lat.private[:bookkeeping_state], copy(lat.pdict))
  if !isnothing(auditing_enabled); lat.pdict[:auditing_enabled] = auditing_enabled; end
  if !isnothing(autobookkeeping); lat.pdict[:autobookkeeping] = autobookkeeping; end
end

#---------------------------------------------------------------------------------------------------
# pop_bookkeeping_state!

"""
    pop_bookkeeping_state!(lat::Lattice)

Restore the state of `auditing_enabled` and `autobookkeeping` from the saved state stack.
""" pop_bookkeeping_state!

function pop_bookkeeping_state!(lat::Lattice)
  lat.pdict[:auditing_enabled] = lat.private[:bookkeeping_state][end][:auditing_enabled]
  lat.pdict[:autobookkeeping] = lat.private[:bookkeeping_state][end][:autobookkeeping]
  pop!(lat.private[:bookkeeping_state])
end

