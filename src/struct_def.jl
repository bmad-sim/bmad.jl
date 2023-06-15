using OffsetArrays
using PyFormattedStrings

#-------------------------------------------------------------------------------------

macro insert_standard_LatEle_fields()
  return esc(:( name::String; length::Float64 ))
end
  ## @insert_standard_LatEle_fields


abstract type BeamLineComponent end

"Abstract Lat element from which all elements inherit"
abstract type LatEle <: BeamLineComponent end

"General thick multipole that is inherited by quadrupoles, sextupoles, etc."
abstract type ThickMultipole <: LatEle end

"Bend lat element. Equivalent to SBend in Bmad."
mutable struct Bend <: LatEle
  name::String
  param::Dict{String,Any}
end

"Drift lat element"
mutable struct Drift <: LatEle
  name::String
  param::Dict{String,Any}
end

"Quadrupole lat element"
mutable struct Quadrupole <: ThickMultipole
  name::String
  param::Dict{String,Any}
end

"Marker lat element"
mutable struct Marker <: LatEle
  name::String
  param::Dict{String,Any}
end

beginning_Latele = Marker("beginning", Dict{String,Any}())
end_Latele       = Marker("end", Dict{String,Any}())

#-------------------------------------------------------------------------------------
"LatEle parameters"

mutable struct FloorPosition
  r::Vector{Float64}       # (x,y,z) in Global coords
  q::Vector{Float64}       # Quaternion orientation
  theta::Float64;  phi::Float64;  psi::Float64  # Angular orientation consistant with q
end

mutable struct MultipoleArray
  k::OffsetVector{Float64, Vector{Float64}}
  ks::OffsetVector{Float64, Vector{Float64}}
  tilt::OffsetVector{Float64, Vector{Float64}}
end

mutable struct LordSlave
  lord::Union{LatEle,Nothing}
  slave::Union{Vector{LatEle},Nothing}
  control_lord::Union{Vector{LatEle},Nothing}
end

#-------------------------------------------------------------------------------------
"Lattice"

abstract type AbstractLat end
abstract type AbstractBranch end

LatEle(ele::LatEle, branch::AbstractBranch, ix_ele::Int) = LatEle(ele.name, ele, branch, ix_ele, nothing)

mutable struct LatBranch
  name::String
  ele::Vector{LatEle}
  param::Dict{String,Any}
end

mutable struct Lat <: AbstractLat
  name::String
  branch::Vector{LatBranch}
end

function show_branch(branch::LatBranch)
  print(f"{get(branch.param, \"ix_branch\", \"\")} Branch: {branch.name}")
  n = maximum([6, maximum([length(e.name) for e in branch.ele])])
  for (ix, ele) in enumerate(branch.ele)
    print(f"\n  {ix:5i}  {rpad(ele.name, n)}")
  end
  return nothing
end

function show_lat(lat::Lat)
  print(f"Lat: {lat.name}")
  for branch in lat.branch
    print("\n")
    show_branch(branch)
  end
  return nothing
end

#Base.show(io::IO, lb::LatBranch) = print(io, "Hi!")


#-------------------------------------------------------------------------------------

BeamLineItem = Union{BeamLineComponent, Vector{BeamLineComponent}}

"A simple beam line."
mutable struct BeamLine <: BeamLineComponent
  name::String
  line::Vector{BeamLineItem}
  multipass::Bool
  orientation::Int
end

#Base.show(io::IO, lb::BeamLine) = print(io, "Hi!")

#-------------------------------------------------------------------------------------
"Functions to construct a lat."

function latele(type::Type{T}, name::String; kwargs...) where T <: LatEle
  # kwargs is a named tuple with Symbol keys. Want keys to be Strings.
  return type(name, Dict{String,Any}(string(k)=>v for (k,v) in kwargs))
end

function beamline(name::String, line_in::Vector{T}; multipass::Bool = false, orientation = +1) where T <: BeamLineItem
  return BeamLine(name, line_in, multipass, orientation)
end

function latele_to_branch!(branch, latele)
  push!(branch.ele, deepcopy(latele))
  ele = branch.ele[end]
  ele.param["ix_ele"] = length(branch.ele)
  return nothing
end

function beamline_item_to_branch!(branch::LatBranch, item::BeamLineItem)
  if isa(item, LatEle)
    latele_to_branch!(branch, item)
  elseif isa(item, Vector{LatEle})
    for subitem in item; latele_to_branch!(branch, subitem); end
  elseif isa(item, BeamLine) 
    add_to_latbranch!(branch, item)
  elseif isa(item, Vector{BeamLine})
    for subitem in item; add_to_latbranch!(branch, subitem); end
  end
  return nothing
end

function add_to_latbranch!(branch::LatBranch, beamline::BeamLine)
  for item in beamline.line; beamline_item_to_branch!(branch, item); end
  return nothing
end

function new_latbranch!(lat::Lat, beamline::BeamLine)
  push!(lat.branch, LatBranch(beamline.name, Vector{LatEle}(), 
                                              Dict{String,Any}("lat" => lat, "ix_branch" => length(lat.branch)+1)))
  branch = lat.branch[end]
  latele_to_branch!(branch, beginning_Latele)
  add_to_latbranch!(branch, beamline)
  latele_to_branch!(branch, end_Latele)
  return nothing
end

function make_lat(root_line::Union{BeamLine,Vector{BeamLine},Nothing} = nothing, name::String = "")
  lat = Lat(name, Vector{LatBranch}())
  if root_line == nothing; root_line = root_beamline end
  if isa(root_line, BeamLine)
    new_latbranch!(lat, root_line)
  else
    for rline in root_line; new_latbranch!(lat, rline); end
  end
  if lat.name == ""; lat.name = lat.branch[1].name; end
  return lat
end