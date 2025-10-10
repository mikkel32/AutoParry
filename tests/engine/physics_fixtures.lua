local step = 1 / 240

local defaults = {
    safeRadius = 10,
    activationLatency = 0.12,
    oscillationDistanceDelta = 0.35,
    oscillationFrequency = 3,
}

local straightSteps = {
    {
        t = step,
        projectiles = {
            {
                name = "LegacyBaseline",
                position = { x = 0, y = 0, z = 59.5 },
                velocity = { x = 0, y = 0, z = -120 },
                contact = false,
            },
        },
    },
    {
        t = step * 2,
        projectiles = {
            {
                name = "LegacyBaseline",
                position = { x = 0, y = 0, z = 59.0 },
                velocity = { x = 0, y = 0, z = -120 },
                contact = false,
            },
        },
    },
    {
        t = step * 3,
        projectiles = {
            {
                name = "LegacyBaseline",
                position = { x = 0, y = 0, z = 58.5 },
                velocity = { x = 0, y = 0, z = -120 },
                contact = false,
            },
        },
    },
}

local contactSteps = {
    {
        t = step,
        projectiles = {
            {
                name = "SafeRadiusProbe",
                position = { x = 0, y = 0, z = 10 },
                velocity = { x = 0, y = 0, z = 0 },
                contact = true,
            },
        },
    },
    {
        t = step * 2,
        projectiles = {
            {
                name = "SafeRadiusProbe",
                position = { x = 0, y = 0, z = 10 },
                velocity = { x = 0, y = 0, z = 0 },
                contact = false,
            },
        },
    },
}

return {
    step = step,
    defaults = defaults,
    straight = {
        steps = straightSteps,
    },
    contact = {
        steps = contactSteps,
    },
}
