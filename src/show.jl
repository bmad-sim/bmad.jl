#-------------------------------------------------------------------------------------
"To print memory location of object"

function memloc(@nospecialize(x))
   y = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x)
   return repr(UInt64(y))
end

#-------------------------------------------------------------------------------------
# Show Ele Vector

function Base.show(io::IO, vec::Vector{Ele}) 
  print(f"[{join([v.name for v in vec], ',')}]")
end

#-------------------------------------------------------------------------------------
# ele_name

function ele_name(ele::Ele, template::AbstractString = "")
  if !haskey(ele.param, :ix_ele); return ele.name; end
  if template == ""; template = "\"@N\" (!#)"; end

  ix_ele = ele.param[:ix_ele]
  branch = ele.param[:branch]
  lat = branch.param[:lat]
  str = replace(template, "@N" => ele.name)
  str = replace(str, "%#" => (branch === lat.branch[1] ? ix_ele : branch.name * ">>" * string(ix_ele)))
  str = replace(str, "&#" => (lat.branch == 1 ? string(ix_ele) : branch.name * ">>" * string(ix_ele)))
  str = replace(str, "!#" => branch.name * ">>" * string(ix_ele))
  return str
end

#-------------------------------------------------------------------------------------
# show_param_name

function show_param_name(param, key, template::AbstractString = "")
  who = get(param, key, nothing)
  if who == nothing
    return ""
  elseif who isa Ele
    return ele_name(who, template)
  elseif who isa Vector
    return "[" * join([ele_name(ele, template) for ele in who], ", ") * "]"
  else
    return "???"
  end
end

#-------------------------------------------------------------------------------------
# show_ele

function show_ele(ele::Ele)
  println(f"{ele_name(ele)}:   {typeof(ele)}")
  for (key, val) in ele.param
    kstr = rpad(repr(key), 16)
    if val isa Ele
      println(f"  {kstr} {ele_name(val)}")
    elseif val isa Branch
      println(f"  {kstr} {str_quote(val.name)}")
    elseif val isa Vector{Ele}
      println(f"  {kstr} [{join([ele_name(ele) for ele in val], \", \")}]")
    else
      println(f"  {kstr} {val}")
    end
  end
  return nothing
end

Base.show(io::IO, ele::Ele) = show_ele(ele)

#-------------------------------------------------------------------------------------
# show_eles

function show_eles(eles::Vector{Ele})
  println(f"{size(eles,1)}-element Vector{{Ele}}:")
  for ele in eles
    println(" " * ele_name(ele))
  end
end

Base.show(io::IO, ::MIME"text/plain", eles::Vector{Ele}) = show_eles(eles)

#-------------------------------------------------------------------------------------
# show_lat

function show_lat(lat::Lat)
  println(f"Lat: {str_quote(lat.name)}")
  for branch in lat.branch
    show_branch(branch)
  end
  return nothing
end

Base.show(io::IO, lat::Lat) = show_lat(lat)

#-------------------------------------------------------------------------------------
# show_branch

function show_branch(branch::Branch)
  g_str = ""
  if haskey(branch.param, :geometry); g_str = f":geometry => {branch.param[:geometry]}"; end
  println(f"{branch[:ix_branch]} Branch: {str_quote(branch.name)}  {g_str}")

  if length(branch.ele) == 0 
    println("     --- No Elements ---")
  else
    n = maximum([12, maximum([length(e.name) for e in branch.ele])]) + 2
    for ele in branch.ele
      println(f"  {ele.param[:ix_ele]:5i}  {rpad(str_quote(ele.name), n)} {rpad(typeof(ele), 16)}" *
        f"  {lpad(ele.param[:orientation], 2)}  {show_param_name(ele.param, :multipass_lord)}{show_param_name(ele.param, :slave)}")
    end
  end
  return nothing
end

Base.show(io::IO, lb::Branch) = show_branch(lb)

#-------------------------------------------------------------------------------------
# show_beamline

function show_beamline(beamline::BeamLine)
  println(f"Beamline:  {str_quote{beamline.name}}, multipass: {beamline.param[:multipass]}, orientation: {beamline.param[:orientation]}")
  n = 6
  for item in beamline.line
    if item isa BeamLineEle
      n = maximum([n, length(item.ele.name)]) + 2
    else  # BeamLine
      n = maximum([n, length(item.name)]) + 2
    end
  end

  for (ix, item) in enumerate(beamline.line)
    if item isa BeamLineEle
      println(f"{ix:5i}  {rpad(str_quote(item.ele.name), n)}  {rpad(typeof(item.ele), 12)}  {lpad(item.param[:orientation], 2)}")
    else  # BeamLine
      println(f"{ix:5i}  {rpad(str_quote(item.name), n)}  {rpad(typeof(item), 12)}  {lpad(item.param[:orientation], 2)}")
    end
  end
  return nothing
end

Base.show(io::IO, bl::BeamLine) = show_beamline(bl)

