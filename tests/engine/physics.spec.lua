-- selene: allow(global_usage)
-- selene: allow(incorrect_standard_library_use)

local TestHarness = script.Parent.Parent
local RuntimeFolder = TestHarness:WaitForChild("engine")
local Physics = require(RuntimeFolder:WaitForChild("physics"))
local Context = require(TestHarness:WaitForChild("Context"))
local Fixtures = require(TestHarness:WaitForChild("PhysicsFixtures"))

local function createWorld(options)
    options = options or {}
    local ballsFolder = Context.BallsFolder and Context.BallsFolder.new("Balls") or Instance.new("Folder")
    if typeof(ballsFolder.Name) ~= "string" then
        ballsFolder.Name = "Balls"
    end

    local world = Physics.World.new({
        now = options.now or 0,
        ballsFolder = ballsFolder,
        config = options.config,
    })

    local rootPart = {
        Name = "HumanoidRootPart",
        Position = Vector3.new(),
        AssemblyLinearVelocity = Vector3.new(),
        CFrame = CFrame.new(),
    }

    world:addAgent({
        name = "player",
        instance = rootPart,
        safeRadius = options.safeRadius or (options.config and options.config.safeRadius),
        latency = options.latency or 0,
    })

    return world, ballsFolder, rootPart
end

local function assertVector(expect, actual, expected, tolerance)
    tolerance = tolerance or 1e-6
    expect(math.abs(actual.x - expected.x) <= tolerance):toEqual(true)
    expect(math.abs(actual.y - expected.y) <= tolerance):toEqual(true)
    expect(math.abs(actual.z - expected.z) <= tolerance):toEqual(true)
end

return function(t)
    t.test("fixed step integrator matches legacy telemetry", function(expect)
        local world = createWorld({ config = Fixtures.defaults })
        world:addProjectile({
            name = "LegacyBaseline",
            position = Vector3.new(0, 0, 60),
            velocity = Vector3.new(0, 0, -120),
        })

        for _ = 1, #Fixtures.straight.steps do
            world:step(Fixtures.step)
        end

        local telemetry = world:exportTelemetry()
        expect(#telemetry.steps):toEqual(#Fixtures.straight.steps)

        for index, expected in ipairs(Fixtures.straight.steps) do
            local sample = telemetry.steps[index]
            expect(sample.t):toBeCloseTo(expected.t, 1e-6)
            local projectile = sample.projectiles[1]
            local expectedProjectile = expected.projectiles[1]
            assertVector(expect, projectile.position, expectedProjectile.position, 1e-4)
            assertVector(expect, projectile.velocity, expectedProjectile.velocity, 1e-4)
            expect(projectile.contact):toEqual(expectedProjectile.contact)
        end
    end)

    t.test("contact resolution respects safe radius and fixtures", function(expect)
        local world = createWorld({ config = Fixtures.defaults })
        world:addProjectile({
            name = "SafeRadiusProbe",
            position = Vector3.new(0, 0, Fixtures.defaults.safeRadius / 2),
            velocity = Vector3.new(0, 0, -40),
        })

        for _ = 1, #Fixtures.contact.steps do
            world:step(Fixtures.step)
        end

        local telemetry = world:exportTelemetry()
        for index, expected in ipairs(Fixtures.contact.steps) do
            local sample = telemetry.steps[index]
            expect(sample.t):toBeCloseTo(expected.t, 1e-6)
            local projectile = sample.projectiles[1]
            local expectedProjectile = expected.projectiles[1]
            assertVector(expect, projectile.position, expectedProjectile.position, 1e-3)
            expect(projectile.contact):toEqual(expectedProjectile.contact)
        end
    end)

    t.test("latency injection delays contact arming", function(expect)
        local latency = Fixtures.defaults.activationLatency
        local world = createWorld({ config = Fixtures.defaults, latency = latency })
        world:addProjectile({
            name = "LatencyBall",
            position = Vector3.new(0, 0, Fixtures.defaults.safeRadius - 0.5),
            velocity = Vector3.new(0, 0, -20),
            latency = latency,
        })

        local armedAt
        for step = 1, 240 do
            world:step(Fixtures.step)
            local telemetry = world:getProjectileSamples()[1]
            if telemetry.contact then
                armedAt = step
                break
            end
        end

        expect(armedAt):toBeTruthy()
        expect(armedAt * Fixtures.step >= latency):toEqual(true)
    end)

    t.test("curvature and oscillation adjust velocity", function(expect)
        local world = createWorld({ config = Fixtures.defaults })
        world:addProjectile({
            name = "Curved",
            position = Vector3.new(0, 0, 40),
            velocity = Vector3.new(0, 0, -100),
            curvature = 0.05,
            curvatureRate = 0.01,
            oscillationMagnitude = Fixtures.defaults.oscillationDistanceDelta,
            oscillationFrequency = Fixtures.defaults.oscillationFrequency,
        })

        world:step(Fixtures.step)
        local sample = world:getProjectileSamples()[1]
        expect(sample.position.Z < 40):toEqual(true)
        expect(sample.velocity.X ~= 0 or sample.velocity.Y ~= 0):toEqual(true)
    end)
end
