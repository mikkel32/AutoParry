local math = math

local function makeThreat(idSuffix, time, position, velocity, tags)
    return {
        time = time,
        type = "threat",
        threat = {
            id = string.format("%s", idSuffix),
            spawn = {
                position = position,
                velocity = velocity,
            },
            tags = tags,
        },
    }
end

local function addRemoteAttach(timeline)
    timeline[#timeline + 1] = {
        time = 0,
        type = "network",
        network = {
            event = "remotes:ParryButtonPress",
            direction = "observe",
            payload = { available = true },
        },
        notes = "Ensure the parry remote is mounted before threats spawn.",
    }
end

local function baseTimeline(notes)
    local timeline = {
        {
            time = 0,
            type = "rule",
            rule = "autoparry-enabled",
            value = true,
            notes = notes or "Enable AutoParry at the beginning of the scenario.",
        },
    }
    addRemoteAttach(timeline)
    return timeline
end

local function massPressureScenario()
    local threatCount = 5000
    local spawnInterval = 0.004
    local startTime = 0.15
    local lanes = {
        { position = { 0, 1, 210 }, velocity = { 0, 0, -240 }, tag = "frontal" },
        { position = { 14, 3, 240 }, velocity = { -24, -2, -265 }, tag = "cross-left" },
        { position = { -12, 2, 235 }, velocity = { 22, -1, -255 }, tag = "cross-right" },
        { position = { 6, -1, 225 }, velocity = { -6, 0, -230 }, tag = "high-low" },
        { position = { -18, -4, 250 }, velocity = { 28, 4, -280 }, tag = "curve-right" },
    }

    local timeline = baseTimeline("Heavy threat density requires AutoParry active immediately.")

    for index = 1, threatCount do
        local lane = lanes[((index - 1) % #lanes) + 1]
        local time = startTime + (index - 1) * spawnInterval
        local position = {
            lane.position[1] + math.sin(index * 0.125) * 2,
            lane.position[2] + math.cos(index * 0.1) * 1.5,
            lane.position[3] - (index % 11),
        }
        local speedScale = 1 + ((index % 17) / 50)
        local velocity = {
            lane.velocity[1] * speedScale,
            lane.velocity[2] * speedScale,
            lane.velocity[3] * speedScale,
        }
        local tags = { "engine-perf", "mass-pressure", lane.tag }
        if index % 1000 == 0 then
            tags[#tags + 1] = "milestone"
        end
        timeline[#timeline + 1] = makeThreat(string.format("mass-%04d", index), time, position, velocity, tags)
    end

    timeline[#timeline + 1] = {
        time = startTime + threatCount * spawnInterval * 0.5,
        macro = "hitch gauntlet",
        options = {
            count = 5,
            interval = 1.35,
            magnitude = 0.18,
        },
        notes = "Inject five 180 ms hitches mid-run per goal.md hitch gauntlet target.",
    }

    timeline[#timeline + 1] = {
        time = startTime + threatCount * spawnInterval * 0.8,
        macro = "oscillation storm",
        options = {
            rule = "highlight-gate",
            duration = 0.3,
            frequencyHz = 22,
            values = { true, false },
        },
        notes = "Overlay highlight flicker while throughput remains high.",
    }

    return {
        version = 1,
        metadata = {
            id = "engine_perf_mass_pressure",
            label = "Mass pressure throughput",
            description = "5000 threat burst at mixed angles validating P99 ≤10ms scheduling under load.",
            tags = { "engine-perf", "mass-pressure", "goal-md" },
            history = { "goal.md" },
        },
        config = {
            autoparry = {
                cooldown = 0.12,
                minTTI = 0.08,
                maxTTI = 3.0,
                pingOffset = 0.02,
                pressMaxLookahead = 0.9,
                pressScheduleSlack = 0.01,
            },
        },
        timeline = timeline,
    }
end

local function hitchResilienceScenario()
    local timeline = baseTimeline("Keep AutoParry hot before the hitch ladder begins.")

    local hitchStart = 0.6
    for wave = 1, 7 do
        local phase = (wave - 1) * 0.95
        timeline[#timeline + 1] = makeThreat(
            string.format("hitch-wave-%02d-a", wave),
            hitchStart + phase,
            { 0, 0, 170 - wave * 4 },
            { 0, 0, -215 - wave * 8 },
            { "engine-perf", "hitch", "pre" }
        )
        timeline[#timeline + 1] = makeThreat(
            string.format("hitch-wave-%02d-b", wave),
            hitchStart + phase + 0.18,
            { (-1) ^ wave * 12, 1.5, 195 - wave * 3 },
            { (-1) ^ wave * -18, -1.5, -245 - wave * 6 },
            { "engine-perf", "hitch", "post" }
        )
    end

    timeline[#timeline + 1] = {
        time = hitchStart + 0.45,
        macro = "hitch gauntlet",
        options = {
            count = 5,
            interval = 1.4,
            magnitude = 0.18,
        },
        notes = "Five 180 ms hitches spaced to mirror the hitch gauntlet acceptance criteria.",
    }

    timeline[#timeline + 1] = {
        time = hitchStart + 5.0,
        type = "player",
        player = {
            action = "observe-telemetry",
            duration = 0.6,
        },
        notes = "Allow telemetry collectors to settle after hitch recovery for offline analysis.",
    }

    return {
        version = 1,
        metadata = {
            id = "engine_perf_hitch_resilience",
            label = "Hitch gauntlet resilience",
            description = "Validates scheduler recovery across the five hitch gauntlet cases from goal.md.",
            tags = { "engine-perf", "hitch-gauntlet", "goal-md" },
            history = { "goal.md" },
        },
        config = {
            autoparry = {
                cooldown = 0.1,
                minTTI = 0.05,
                maxTTI = 2.5,
                pingOffset = 0.015,
                pressMaxLookahead = 0.95,
                pressScheduleSlack = 0.008,
            },
        },
        timeline = timeline,
    }
end

local function flickerStormScenario()
    local timeline = baseTimeline("Highlight gate must stay responsive during oscillation storms.")

    local function addStorm(time, frequency)
        timeline[#timeline + 1] = {
            time = time,
            macro = "oscillation storm",
            options = {
                rule = "highlight-gate",
                duration = 0.3,
                frequencyHz = frequency,
                values = { true, false },
            },
            notes = string.format("Highlight flicker storm at %.1f Hz as per goal.md flicker requirement.", frequency),
        }
    end

    local approachTimes = { 0.35, 0.85, 1.35, 1.85, 2.35 }
    for index, base in ipairs(approachTimes) do
        local offset = (index % 2 == 0) and 6 or -6
        timeline[#timeline + 1] = makeThreat(
            string.format("flicker-%02d", index),
            base,
            { offset, 0.75, 180 - index * 6 },
            { -offset * 2.2, 0, -220 - index * 12 },
            { "engine-perf", "flicker-storm" }
        )
    end

    addStorm(0.3, 15)
    addStorm(1.2, 20)
    addStorm(2.1, 25)

    timeline[#timeline + 1] = {
        time = 2.6,
        type = "player",
        player = {
            action = "observe-telemetry",
            duration = 0.5,
        },
        notes = "Capture post-flicker telemetry for offline gating analysis.",
    }

    return {
        version = 1,
        metadata = {
            id = "engine_perf_flicker_window",
            label = "Flicker storm gating",
            description = "Exercises 15–25 Hz highlight oscillation windows with concurrent threats.",
            tags = { "engine-perf", "flicker-storm", "goal-md" },
            history = { "goal.md" },
        },
        config = {
            autoparry = {
                cooldown = 0.11,
                minTTI = 0.07,
                maxTTI = 2.8,
                pingOffset = 0.018,
                pressMaxLookahead = 0.92,
                pressScheduleSlack = 0.009,
            },
        },
        timeline = timeline,
    }
end

return {
    version = 1,
    metadata = {
        id = "engine_perf_suite",
        label = "Engine performance regression suite",
        description = "Defines mass-pressure, hitch-gauntlet, and flicker-storm workloads aligning with goal.md targets.",
        tags = { "engine-perf", "goal-md" },
    },
    scenarios = {
        massPressureScenario(),
        hitchResilienceScenario(),
        flickerStormScenario(),
    },
}
