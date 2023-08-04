using OffsetArrays
using PyFormattedStrings

#-------------------------------------------------------------------------------------
# Exceptions

struct InfiniteLoop <: Exception;   msg::AbstractString; end
struct RangeError <: Exception;     msg::AbstractString; end
struct BmadParseError <: Exception; msg::AbstractString; end

# A "lattice branch" is a branch in a lattice.
# A "beamline" is a line defined in a lattice file.

#-------------------------------------------------------------------------------------

"Abstract type that represents a Ele or sub BeamLine contained in a beamline."
abstract type BeamLineItem end

"Abstract lattice element from which all lattice elements inherit"
abstract type Ele <: BeamLineItem end

"Abstract lattice from which Lat inherits"
abstract type AbstractLat end


#-------------------------------------------------------------------------------------
# Ele

"General thick multipole that is inherited by quadrupoles, sextupoles, etc."
abstract type ThickMultipole <: Ele end

# Bend

"Bend lat element."
mutable struct Bend <: Ele
  name::AbstractString
  param::Dict{Symbol,Any}
end

function Bend(name::AbstractString; kwargs...) 
  eval( :($(Symbol(name)) = Bend($name, Dict{Symbol,Any}($kwargs...))) )
end

## Old way:
## Bend(name::AbstractString;kwargs...)= Bend(name, Dict{Symbol,Any}(kwargs))

# Drift

"Drift lat element"
mutable struct Drift <: Ele
  name::AbstractString
  param::Dict{Symbol,Any}
end

function Drift(name::AbstractString; kwargs...) 
  eval( :($(Symbol(name)) = Drift($name, Dict{Symbol,Any}($kwargs...))) )
end

# Quadrupole

"Quadrupole lat element"
mutable struct Quadrupole <: ThickMultipole
  name::AbstractString
  param::Dict{Symbol,Any}
end

function Quadrupole(name::AbstractString; kwargs...) 
  eval( :($(Symbol(name)) = Quadrupole($name, Dict{Symbol,Any}($kwargs...))) )
end

# Marker

"Marker lat element"
mutable struct Marker <: Ele
  name::AbstractString
  param::Dict{Symbol,Any}
end

function Marker(name::AbstractString; kwargs...) 
  eval( :($(Symbol(name)) = Marker($name, Dict{Symbol,Any}($kwargs...))) )
end

# NullEle

"NullEle lat element"
mutable struct NullEle <: Ele
  name::AbstractString
  param::Dict{Symbol,Any}
end

function NullEle(name::AbstractString; kwargs...) 
  eval( :($(Symbol(name)) = NullEle($name, Dict{Symbol,Any}($kwargs...))) )
end

NULL_ELE      = NullEle("null", Dict{Symbol,Any}())

#-------------------------------------------------------------------------------------
# Ele parameters

mutable struct FloorPosition
  r::Vector{Float64}       # (x,y,z) in Global coords
  q::Vector{Float64}       # Quaternion orientation
  theta::Float64;  phi::Float64;  psi::Float64  # Angular orientation consistant with q
end

mutable struct MultipoleArray
  k::OffsetVector{Float64}
  ks::OffsetVector{Float64}
  tilt::OffsetVector{Float64}
end

#-------------------------------------------------------------------------------------
# Branch

mutable struct Branch <: BeamLineItem
  name::AbstractString
  ele::Vector{Ele}
  param::Dict{Symbol,Any}
end

#-------------------------------------------------------------------------------------
# Lat

mutable struct BmadGlobal
  significant_length::Float64
  other::Dict{Any,Any}                      # For user defined stuff.
end

BmadGlobal() = BmadGlobal(1.0e-10, Dict())

mutable struct Lat <: AbstractLat
  name::AbstractString
  branch::OffsetVector{Branch}
  param::Dict{Symbol,Any}
  bmadglobal::BmadGlobal
end

#-------------------------------------------------------------------------------------
# BeamLine
# Rule: param Dict of BeamLineEle and BeamLine always define :orientation and :multipass keys.
# Rule: All instances a given Ele in beamlines are identical so that the User can easily 
# make a Change to all. At lattice expansion, deepcopyies of Eles will be done.

# Why wrap a Ele within a BeamLineEle? This allows multiple instances in a beamline of the same 
# identical Ele with some having orientation reversed or within multipass regions and some not.

mutable struct BeamLineEle <: BeamLineItem
  ele::Ele
  param::Dict{Symbol,Any}
end

mutable struct BeamLine <: BeamLineItem
  name::AbstractString
  line::Vector{BeamLineItem}
  param::Dict{Symbol,Any}
end

"Used when doing lattice expansion."
mutable struct LatConstructionInfo
  multipass_id::Vector{String}
  orientation_here::Int
  n_loop::Int
end


