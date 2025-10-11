--!strict

local Trajectory = {}
Trajectory.__index = Trajectory

export type Options = {
    position: Vector3?,
    velocity: Vector3?,
    forward: Vector3?,
    range: number?,
    duration: number?,
    lateral: Vector3?,
    control: Vector3?,
    finish: Vector3?,
    apexHeight: number?,
    allowDescent: boolean?,
    floorHeight: number?,
    endHeight: number?,
    maintainVelocity: boolean?,
    clampHeight: boolean?,
}

export type Sample = {
    time: number,
    position: Vector3,
    velocity: Vector3,
}

local ZERO = Vector3.new()

local function coerceVector3(value: Vector3?, fallback: Vector3?): Vector3
    if typeof(value) == "Vector3" then
        return value
    end
    return fallback or ZERO
end

local function magnitudeOrDefault(vector: Vector3, default: number): number
    local magnitude = vector.Magnitude
    if magnitude <= 1e-6 then
        return default
    end
    return magnitude
end

local function unitOrDefault(vector: Vector3, default: Vector3): Vector3
    if vector.Magnitude <= 1e-6 then
        return default
    end
    return vector.Unit
end

local function bezier(t: number, p0: Vector3, p1: Vector3, p2: Vector3): Vector3
    local u = 1 - t
    local uu = u * u
    local tt = t * t
    local twoUT = 2 * u * t
    return (p0 * uu) + (p1 * twoUT) + (p2 * tt)
end

local function bezierDerivative(t: number, p0: Vector3, p1: Vector3, p2: Vector3): Vector3
    local u = 1 - t
    return (p1 - p0) * (2 * u) + (p2 - p1) * (2 * t)
end

local function clampHeight(position: Vector3, minHeight: number?, startHeight: number?, allowDescent: boolean): Vector3
    local y = position.Y
    if not allowDescent then
        if startHeight and y < startHeight then
            y = startHeight
        end
    elseif minHeight and y < minHeight then
        y = minHeight
    end
    if y == position.Y then
        return position
    end
    return Vector3.new(position.X, y, position.Z)
end

function Trajectory.new(options: Options)
    options = options or {}

    local origin = coerceVector3(options.position, ZERO)
    local initialVelocity = coerceVector3(options.velocity, ZERO)
    local forward = options.forward
    if typeof(forward) ~= "Vector3" or forward.Magnitude <= 1e-6 then
        forward = initialVelocity
    end
    forward = unitOrDefault(forward, Vector3.new(0, 0, -1))

    local duration = math.max(options.duration or 0, 0)
    local range = options.range

    local speed = magnitudeOrDefault(initialVelocity, 60)
    if duration <= 1e-6 then
        if range and range > 1e-6 then
            duration = range / math.max(speed, 1e-3)
        else
            duration = 0.85
        end
    end

    if not range or range <= 1e-6 then
        range = speed * duration
        if range <= 1e-6 then
            range = 20
        end
    end

    local lateral = coerceVector3(options.lateral, ZERO)

    local defaultControl = origin + (forward * (range * 0.5)) + lateral
    local defaultFinish = origin + (forward * range) + (lateral * 2)

    local apexHeight = options.apexHeight
    if typeof(apexHeight) ~= "number" then
        apexHeight = math.max(origin.Y + math.min(math.max(range * 0.25, 6), 24), origin.Y)
    else
        apexHeight = math.max(apexHeight, origin.Y)
    end

    local allowDescent = options.allowDescent == true

    local floorHeight = options.floorHeight
    if typeof(floorHeight) ~= "number" then
        floorHeight = origin.Y
    end

    local endHeight = options.endHeight
    if typeof(endHeight) ~= "number" then
        endHeight = if allowDescent then floorHeight else origin.Y
    end

    local control = options.control
    if typeof(control) ~= "Vector3" then
        control = defaultControl
    end
    control = Vector3.new(control.X, apexHeight, control.Z)

    local finish = options.finish
    if typeof(finish) ~= "Vector3" then
        finish = defaultFinish
    end
    finish = Vector3.new(finish.X, endHeight, finish.Z)

    local self = setmetatable({
        origin = origin,
        control = control,
        finish = finish,
        duration = duration,
        elapsed = 0,
        forward = forward,
        range = range,
        lateral = lateral,
        allowDescent = allowDescent,
        startHeight = origin.Y,
        minHeight = math.min(origin.Y, endHeight, floorHeight),
        maintainVelocity = options.maintainVelocity ~= false,
        clampHeight = options.clampHeight ~= false,
        previousPosition = origin,
        completed = false,
    }, Trajectory)

    return self
end

function Trajectory:evaluate(alpha: number): Vector3
    if alpha <= 0 then
        return self.origin
    end
    if alpha >= 1 then
        local final = self.finish
        if self.clampHeight then
            final = clampHeight(final, self.minHeight, self.startHeight, self.allowDescent)
        end
        return final
    end

    local position = bezier(alpha, self.origin, self.control, self.finish)
    if self.clampHeight then
        position = clampHeight(position, self.minHeight, self.startHeight, self.allowDescent)
    end
    return position
end

function Trajectory:step(instance, dt: number): (boolean, Vector3)
    if self.completed or dt <= 0 then
        local current = instance.Position or self.finish
        local velocity = instance.AssemblyLinearVelocity or ZERO
        return false, velocity
    end

    self.elapsed += dt
    local alpha = self.elapsed / self.duration
    if alpha >= 1 then
        alpha = 1
        self.completed = true
    end

    local position = self:evaluate(alpha)
    local velocity = (position - self.previousPosition) / dt
    self.previousPosition = position

    if typeof(instance.SetPosition) == "function" then
        instance:SetPosition(position)
    else
        instance.Position = position
    end

    if self.maintainVelocity and typeof(instance.SetVelocity) == "function" then
        instance:SetVelocity(velocity)
    else
        instance.AssemblyLinearVelocity = velocity
    end

    return not self.completed, velocity
end

function Trajectory:isFinished(): boolean
    return self.completed
end

function Trajectory:rewind(): ()
    self.elapsed = 0
    self.previousPosition = self.origin
    self.completed = false
end

function Trajectory:samples(count: number): { Sample }
    count = math.max(count or 0, 2)
    local results = {}
    local duration = self.duration
    for index = 0, count - 1 do
        local alpha = if count == 1 then 1 else index / (count - 1)
        local position = self:evaluate(alpha)
        local derivative = bezierDerivative(alpha, self.origin, self.control, self.finish)
        local velocity = derivative / math.max(duration, 1e-3)
        if self.clampHeight then
            local clamped = clampHeight(position, self.minHeight, self.startHeight, self.allowDescent)
            if clamped ~= position then
                position = clamped
                velocity = Vector3.new(velocity.X, 0, velocity.Z)
            end
        end
        results[#results + 1] = {
            time = duration * alpha,
            position = position,
            velocity = velocity,
        }
    end
    return results
end

return Trajectory
