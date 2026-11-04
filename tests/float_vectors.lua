-- Source stores Vector components/results as 32-bit floats. The usual
-- double-precision adapter misses clipping faults at real map coordinates.
local function float(value)
    if value==0 or value==math.huge or value==-math.huge then return value end
    local mantissa,exponent=math.frexp(math.abs(value))
    local scaled=mantissa*16777216
    local integer=math.floor(scaled)
    local fraction=scaled-integer
    if fraction>0.5 or (fraction==0.5 and integer%2==1) then integer=integer+1 end
    return math.ldexp(integer,exponent-24)*(value<0 and -1 or 1)
end
local original=Vector
local meta=getmetatable(Vector())
function Vector(x,y,z) return original(float(x or 0),float(y or 0),float(z or 0)) end
function meta.__mul(a,b)
    if type(a)=="number" then a,b=b,a end
    b=float(b) return Vector(a.x*b,a.y*b,a.z*b)
end
function meta.__div(a,b) b=float(b) return Vector(a.x/b,a.y/b,a.z/b) end
function meta:Set(b) self.x,self.y,self.z=b.x,b.y,b.z end
function meta:Add(b) self.x,self.y,self.z=float(self.x+b.x),float(self.y+b.y),float(self.z+b.z) end
function meta:Sub(b) self.x,self.y,self.z=float(self.x-b.x),float(self.y-b.y),float(self.z-b.z) end
function meta:Mul(b) b=float(b) self.x,self.y,self.z=float(self.x*b),float(self.y*b),float(self.z*b) end
function meta:Div(b) b=float(b) self.x,self.y,self.z=float(self.x/b),float(self.y/b),float(self.z/b) end
function meta:Normalize()
    local length=self:Length()
    if length>0 then self:Div(length) end
end
function meta:Dot(b)
    return float(float(float(self.x*b.x)+float(self.y*b.y))+float(self.z*b.z))
end
function meta:Cross(b)
    return Vector(float(self.y*b.z)-float(self.z*b.y),float(self.z*b.x)-float(self.x*b.z),float(self.x*b.y)-float(self.y*b.x))
end
function meta:Length() return float(math.sqrt(self:LengthSqr())) end
function meta:GetNormalized()
    local length=self:Length()
    return length>0 and self/length or Vector()
end
