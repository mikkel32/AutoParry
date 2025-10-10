-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local DEFAULT_FIXED_STEP = 1 / 240
local ZERO = Vector3.new()

local function isFiniteNumber(value)
    return typeof(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function coerceVector3(value, fallback)
    if typeof(value) == "Vector3" then
        return value
    end
    if typeof(value) == "table" and value.x and value.y and value.z then
        return Vector3.new(value.x, value.y, value.z)
    end
    return fallback or ZERO
end

local function unitOrDefault(vector, default)
    if typeof(vector) ~= "Vector3" then
        return default or Vector3.new(0, 0, 1)
    end
    local magnitude = vector.Magnitude
    if magnitude < 1e-6 then
        return default or Vector3.new(0, 0, 1)
    end
    return vector / magnitude
end

local function copyDictionary(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function createBallInstance(options)
    options = options or {}

    local position = coerceVector3(options.position, Vector3.new())
    local velocity = coerceVector3(options.velocity, Vector3.new(0, 0, -140))

    local function computeCFrame(pos, vel)
        if vel and vel.Magnitude > 1e-3 then
            return CFrame.new(pos, pos + vel.Unit)
        end
        return CFrame.new(pos)
    end

    local ball = {
        Name = options.name or "TestBall",
        Position = position,
        AssemblyLinearVelocity = velocity,
        CFrame = options.cframe or computeCFrame(position, velocity),
        Parent = nil,
        _isReal = options.realBall ~= false,
        _attributes = {},
    }

    if options.attributes then
        for key, value in pairs(options.attributes) do
            ball._attributes[key] = value
        end
    end

    local className = options.className

    function ball:IsA(name)
        if name == "BasePart" then
            return true
        end
        return name == className
    end

    function ball:GetAttribute(name)
        if name == "realBall" then
            return self._isReal
        end
        return self._attributes[name]
    end

    function ball:SetAttribute(name, value)
        if name == "realBall" then
            self._isReal = value == true
            return
        end
        self._attributes[name] = value
    end

    function ball:SetPosition(newPosition)
        self.Position = newPosition
        self.CFrame = computeCFrame(newPosition, self.AssemblyLinearVelocity)
    end

    function ball:SetVelocity(newVelocity)
        self.AssemblyLinearVelocity = newVelocity
        self.CFrame = computeCFrame(self.Position, newVelocity)
    end

    function ball:IsDescendantOf(parent)
        local current = self.Parent
        while current do
            if current == parent then
                return true
            end
            current = current.Parent
        end
        return false
    end

    function ball:SetRealBall(value)
        self._isReal = value ~= false
    end

    function ball:_advance(dt)
        local velocity = self.AssemblyLinearVelocity
        if velocity then
            local newPosition = self.Position + velocity * dt
            self:SetPosition(newPosition)
        end
    end

    return ball
end

local FieldVolume = {}
FieldVolume.__index = FieldVolume

function FieldVolume.new(options)
    local radius = options.radius or 0
    if radius < 0 then
        radius = 0
    end

    local volume = {
        radius = radius,
        mode = options.mode or "override",
        instance = options.instance,
        center = coerceVector3(options.center, Vector3.new()),
    }

    return setmetatable(volume, FieldVolume)
end

function FieldVolume:getCenter()
    if self.instance and typeof(self.instance.Position) == "Vector3" then
        return self.instance.Position
    end
    return self.center
end

function FieldVolume:getRadius()
    return self.radius or 0
end

function FieldVolume:contains(point)
    local center = self:getCenter()
    return (point - center).Magnitude <= self:getRadius()
end

local Agent = {}
Agent.__index = Agent

function Agent.new(world, options)
    local instance = options.instance
    local safeRadius = options.safeRadius
    if safeRadius == nil then
        safeRadius = world.config.safeRadius
    end

    local agent = {
        world = world,
        name = options.name or "agent",
        instance = instance,
        safeRadius = safeRadius,
        restitution = options.restitution or 0,
        latency = math.max(options.latency or 0, 0),
        history = {},
        accumulator = 0,
        telemetry = {},
    }

    return setmetatable(agent, Agent)
end

function Agent:_sampleState(dt)
    local instance = self.instance
    if not instance then
        return
    end

    local position = instance.Position or Vector3.new()
    local velocity = instance.AssemblyLinearVelocity or ZERO

    if self.latency > 0 then
        self.accumulator += dt
        table.insert(self.history, 1, { time = self.world.now, position = position })
        while #self.history > 0 do
            local entry = self.history[#self.history]
            if self.world.now - entry.time > self.latency + dt then
                table.remove(self.history)
            else
                break
            end
        end
    end

    self.telemetry[#self.telemetry + 1] = {
        t = self.world.now,
        position = position,
        velocity = velocity,
    }
end

function Agent:getLatencyPosition()
    if self.latency <= 0 then
        local instance = self.instance
        if instance then
            return instance.Position or Vector3.new()
        end
        return Vector3.new()
    end

    for _, entry in ipairs(self.history) do
        if self.world.now - entry.time >= self.latency then
            return entry.position
        end
    end

    if self.instance then
        return self.instance.Position or Vector3.new()
    end
    return Vector3.new()
end

function Agent:step(dt)
    local instance = self.instance
    if not instance then
        return
    end

    local velocity = instance.AssemblyLinearVelocity
    if typeof(velocity) ~= "Vector3" then
        velocity = ZERO
    end

    if velocity.Magnitude > 0 then
        local newPosition = instance.Position + velocity * dt
        instance.Position = newPosition
        if velocity.Magnitude > 1e-3 then
            instance.CFrame = CFrame.new(newPosition, newPosition + velocity.Unit)
        else
            instance.CFrame = CFrame.new(newPosition)
        end
    end

    self:_sampleState(dt)
end

local Projectile = {}
Projectile.__index = Projectile

function Projectile.new(world, options)
    options = options or {}
    local instance = options.instance or createBallInstance(options)
    local entity = {
        world = world,
        instance = instance,
        latency = math.max(options.latency or 0, 0),
        safeRadius = options.safeRadius,
        curvature = options.curvature or 0,
        curvatureRate = options.curvatureRate or 0,
        curvatureJerk = options.curvatureJerk or 0,
        curvatureAxis = unitOrDefault(options.curvatureAxis or Vector3.new(0, 1, 0)),
        enableOscillation = options.oscillation ~= false,
        oscillationMagnitude = options.oscillationMagnitude,
        oscillationFrequency = options.oscillationFrequency,
        oscillationAxis = unitOrDefault(options.oscillationAxis or Vector3.new(0, 1, 0)),
        oscillationPhase = 0,
        telemetry = {},
        contactLatency = 0,
        contactArmed = false,
    }

    return setmetatable(entity, Projectile)
end

function Projectile:_resolveConfig()
    local config = self.world.config
    local safeRadius = self.safeRadius
    if safeRadius == nil then
        safeRadius = config.safeRadius or 0
    end

    local oscillationMagnitude = self.oscillationMagnitude
    if oscillationMagnitude == nil then
        oscillationMagnitude = config.oscillationDistanceDelta or 0
    end

    local oscillationFrequency = self.oscillationFrequency
    if oscillationFrequency == nil then
        oscillationFrequency = config.oscillationFrequency or 0
    end

    return safeRadius, oscillationMagnitude, oscillationFrequency
end

function Projectile:_applyCurvature(dt)
    local instance = self.instance
    local velocity = instance.AssemblyLinearVelocity
    if typeof(velocity) ~= "Vector3" then
        return velocity or ZERO
    end

    local speed = velocity.Magnitude
    if speed <= 1e-5 then
        return velocity
    end

    local curvature = self.curvature or 0
    local curvatureRate = self.curvatureRate or 0
    local curvatureJerk = self.curvatureJerk or 0

    curvature += curvatureRate * dt
    curvatureRate += curvatureJerk * dt

    self.curvature = curvature
    self.curvatureRate = curvatureRate

    if curvature == 0 then
        return velocity
    end

    local tangent = velocity / speed
    local axis = self.curvatureAxis or Vector3.new(0, 1, 0)
    local normal = unitOrDefault(axis - axis:Dot(tangent) * tangent, Vector3.new(0, 1, 0))
    local radial = tangent:Cross(normal)
    if radial.Magnitude <= 1e-6 then
        radial = tangent:Cross(Vector3.new(0, 1, 0))
        if radial.Magnitude <= 1e-6 then
            radial = Vector3.new(1, 0, 0)
        end
    end
    radial = radial.Unit

    local acceleration = radial * (speed * speed * curvature)
    local newVelocity = velocity + acceleration * dt
    instance:SetVelocity(newVelocity)
    return newVelocity
end

function Projectile:_applyOscillation(dt)
    if not self.enableOscillation then
        return
    end

    local safeRadius, magnitude, frequency = self:_resolveConfig()
    if frequency <= 0 or magnitude == 0 then
        return
    end

    local instance = self.instance
    local velocity = instance.AssemblyLinearVelocity or ZERO

    local angularFrequency = frequency * math.pi * 2
    self.oscillationPhase += angularFrequency * dt
    local displacement = math.sin(self.oscillationPhase) * magnitude
    local axis = self.oscillationAxis or Vector3.new(0, 1, 0)
    axis = unitOrDefault(axis, Vector3.new(0, 1, 0))

    local offsetVelocity = axis * displacement * angularFrequency
    instance:SetVelocity(velocity + offsetVelocity * dt)

    if safeRadius and safeRadius > 0 then
        self.safeRadius = safeRadius
    end
end

function Projectile:step(dt)
    local instance = self.instance
    if not instance then
        return
    end

    local velocity = instance.AssemblyLinearVelocity or ZERO
    if typeof(velocity) ~= "Vector3" then
        velocity = ZERO
    end

    if typeof(instance._advance) == "function" then
        instance:_advance(dt)
    else
        local newVelocity = self:_applyCurvature(dt)
        if newVelocity ~= velocity then
            velocity = newVelocity
        end

        self:_applyOscillation(dt)
        velocity = instance.AssemblyLinearVelocity or velocity
        local newPosition = instance.Position + velocity * dt
        instance:SetPosition(newPosition)
    end

    self.telemetry[#self.telemetry + 1] = {
        t = self.world.now,
        position = instance.Position,
        velocity = instance.AssemblyLinearVelocity or ZERO,
        contact = self.contactArmed,
    }
end

function Projectile:applyContactResolution(agent, normal, correction, dt)
    local instance = self.instance
    if not instance then
        return
    end

    if correction > 0 then
        local newPosition = instance.Position + normal * correction
        instance:SetPosition(newPosition)
    end

    local velocity = instance.AssemblyLinearVelocity or ZERO
    local relative = velocity
    if agent and agent.instance and typeof(agent.instance.AssemblyLinearVelocity) == "Vector3" then
        relative -= agent.instance.AssemblyLinearVelocity
    end

    local projected = normal:Dot(relative)
    if projected < 0 then
        local restitution = math.max(agent and agent.restitution or 0, 0)
        local impulse = -(1 + restitution) * projected
        instance:SetVelocity(velocity + normal * impulse)
    end
end

local World = {}
World.__index = World

function World.new(options)
    options = options or {}

    local config = copyDictionary(options.config or {})
    config.safeRadius = config.safeRadius or 10
    config.activationLatency = config.activationLatency or 0.12
    config.curvatureLeadScale = config.curvatureLeadScale or 0.12
    config.curvatureHoldBoost = config.curvatureHoldBoost or 0.5
    config.oscillationFrequency = config.oscillationFrequency or 3
    config.oscillationDistanceDelta = config.oscillationDistanceDelta or 0.35
    config.oscillationSpamCooldown = config.oscillationSpamCooldown or 0.15

    local world = {
        now = options.now or 0,
        accumulator = 0,
        fixedStep = options.fixedStep or DEFAULT_FIXED_STEP,
        config = config,
        scheduler = options.scheduler,
        ballsFolder = options.ballsFolder,
        agents = {},
        projectiles = {},
        volumes = {},
        projectileIndex = {},
        telemetry = {
            steps = {},
        },
    }

    return setmetatable(world, World)
end

function World:addAgent(options)
    local agent = Agent.new(self, options or {})
    table.insert(self.agents, agent)
    return agent
end

function World:addFieldVolume(options)
    local volume = FieldVolume.new(options or {})
    table.insert(self.volumes, volume)
    return volume
end

function World:_registerInstance(instance)
    if not (self.ballsFolder and instance) then
        return
    end

    if typeof(self.ballsFolder.Add) == "function" then
        self.ballsFolder:Add(instance)
    else
        instance.Parent = self.ballsFolder
    end
end

function World:addProjectile(options)
    local projectile = Projectile.new(self, options)
    local instance = projectile.instance

    if not self.projectileIndex[instance] then
        self.projectileIndex[instance] = projectile
        table.insert(self.projectiles, projectile)
        self:_registerInstance(instance)
    end

    return instance
end

function World:updateConfig(newConfig)
    if typeof(newConfig) ~= "table" then
        return
    end

    for key, value in pairs(newConfig) do
        if typeof(value) == "number" or typeof(value) == "boolean" then
            self.config[key] = value
        elseif typeof(value) == "table" then
            local current = self.config[key]
            if typeof(current) == "table" then
                for subKey, subValue in pairs(value) do
                    if typeof(subValue) == "number" or typeof(subValue) == "boolean" then
                        if typeof(current) ~= "table" then
                            current = {}
                            self.config[key] = current
                        end
                        current[subKey] = subValue
                    end
                end
            end
        end
    end
end

function World:removeProjectile(instance)
    local projectile = self.projectileIndex[instance]
    if not projectile then
        return nil
    end

    self.projectileIndex[instance] = nil

    for index, value in ipairs(self.projectiles) do
        if value == projectile then
            table.remove(self.projectiles, index)
            break
        end
    end

    if instance and typeof(instance._mockSetParent) == "function" then
        instance:_mockSetParent(nil)
    elseif instance then
        instance.Parent = nil
    end

    if self.ballsFolder and typeof(self.ballsFolder.Remove) == "function" then
        self.ballsFolder:Remove(instance)
    end

    return projectile
end

function World:clearProjectiles()
    for index = #self.projectiles, 1, -1 do
        local projectile = self.projectiles[index]
        local instance = projectile.instance
        if instance and typeof(instance._mockSetParent) == "function" then
            instance:_mockSetParent(nil)
        elseif instance then
            instance.Parent = nil
        end
        if self.ballsFolder and typeof(self.ballsFolder.Remove) == "function" then
            self.ballsFolder:Remove(instance)
        end
        self.projectiles[index] = nil
    end
    table.clear(self.projectileIndex)
end

function World:_resolveSafeRadius(agent)
    local base = agent.safeRadius or self.config.safeRadius or 0
    local position = agent:getLatencyPosition()

    for _, volume in ipairs(self.volumes) do
        if volume:contains(position) then
            if volume.mode == "additive" then
                base = math.max(base, volume:getRadius())
            else
                base = volume:getRadius()
            end
        end
    end

    return base
end

function World:_resolveContacts(dt)
    for _, projectile in ipairs(self.projectiles) do
        local instance = projectile.instance
        if instance then
            local contact = false
            local contactNormal = nil
            local contactCorrection = 0

            for _, agent in ipairs(self.agents) do
                local agentInstance = agent.instance
                if agentInstance then
                    local agentPosition = agent:getLatencyPosition()
                    local ballPosition = instance.Position
                    local delta = ballPosition - agentPosition
                    local distance = delta.Magnitude

                    local safeRadius = projectile.safeRadius
                    if safeRadius == nil then
                        safeRadius = self:_resolveSafeRadius(agent)
                    end

                    if safeRadius > 0 and distance < safeRadius then
                        contact = true
                        if distance > 1e-6 then
                            contactNormal = delta.Unit
                        else
                            contactNormal = Vector3.new(0, 0, 1)
                        end
                        contactCorrection = safeRadius - distance
                        projectile:applyContactResolution(agent, contactNormal, contactCorrection, dt)
                        break
                    end
                end
            end

            if contact then
                projectile.contactLatency += dt
                if projectile.contactLatency >= projectile.latency then
                    projectile.contactArmed = true
                end
            else
                projectile.contactLatency = 0
                projectile.contactArmed = false
            end
        end
    end
end

function World:_stepFixed(dt)
    for _, agent in ipairs(self.agents) do
        agent:step(dt)
    end

    for _, projectile in ipairs(self.projectiles) do
        projectile:step(dt)
    end

    self:_resolveContacts(dt)

    table.insert(self.telemetry.steps, {
        t = self.now,
        agents = self:getAgentSamples(),
        projectiles = self:getProjectileSamples(),
    })
end

function World:step(dt)
    if not isFiniteNumber(dt) or dt <= 0 then
        return 0
    end

    self.accumulator += dt
    local fixedStep = self.fixedStep
    local steps = 0

    while self.accumulator >= fixedStep do
        self.accumulator -= fixedStep
        self.now += fixedStep
        self:_stepFixed(fixedStep)
        steps += 1
    end

    return steps
end

function World:getProjectileSamples()
    local samples = {}
    for _, projectile in ipairs(self.projectiles) do
        local instance = projectile.instance
        if instance then
            samples[#samples + 1] = {
                name = instance.Name,
                position = instance.Position,
                velocity = instance.AssemblyLinearVelocity or ZERO,
                contact = projectile.contactArmed,
            }
        end
    end
    return samples
end

function World:getAgentSamples()
    local samples = {}
    for _, agent in ipairs(self.agents) do
        local instance = agent.instance
        if instance then
            samples[#samples + 1] = {
                name = agent.name,
                position = agent:getLatencyPosition(),
                velocity = instance.AssemblyLinearVelocity or ZERO,
            }
        end
    end
    return samples
end

local function serializeVector(vector)
    if typeof(vector) ~= "Vector3" then
        return { x = 0, y = 0, z = 0 }
    end
    return { x = vector.X, y = vector.Y, z = vector.Z }
end

function World:exportTelemetry()
    local export = {
        now = self.now,
        steps = {},
    }

    for _, step in ipairs(self.telemetry.steps) do
        local snapshot = {
            t = step.t,
            agents = {},
            projectiles = {},
        }

        for _, agent in ipairs(step.agents) do
            snapshot.agents[#snapshot.agents + 1] = {
                name = agent.name,
                position = serializeVector(agent.position),
                velocity = serializeVector(agent.velocity),
            }
        end

        for _, projectile in ipairs(step.projectiles) do
            snapshot.projectiles[#snapshot.projectiles + 1] = {
                name = projectile.name,
                position = serializeVector(projectile.position),
                velocity = serializeVector(projectile.velocity),
                contact = projectile.contact == true,
            }
        end

        export.steps[#export.steps + 1] = snapshot
    end

    return export
end

function World:clearTelemetry()
    self.telemetry.steps = {}
end

function World:destroy()
    self:clearProjectiles()
    self.telemetry.steps = {}
    table.clear(self.agents)
    table.clear(self.volumes)
end

return World
