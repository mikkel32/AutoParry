return {
    version = 1,
    metadata = {
        id = "telemetry_baseline_capture",
        label = "Telemetry baseline capture",
        description = "Spawns a single frontal threat and records telemetry through a highlight oscillation window.",
        tags = { "telemetry", "spec", "smoke" },
        history = {
            "tests/autoparry/telemetry.spec.lua",
            "tests/autoparry/oscillation_spam.spec.lua",
        },
    },
    config = {
        autoparry = {
            minTTI = 0,
            pingOffset = 0,
            cooldown = 0.12,
            activationLatency = 0.08,
            pressMaxLookahead = 2.5,
            pressReactionBias = 0,
            pressConfidencePadding = 0.2,
            pressScheduleSlack = 0.01,
        },
    },
    timeline = {
        {
            time = 0,
            type = "rule",
            rule = "autoparry-enabled",
            value = true,
            notes = "Enable AutoParry before spawning the projectile to capture telemetry from the first frame.",
        },
        {
            time = 0,
            type = "threat",
            threat = {
                id = "telemetry-threat",
                spawn = {
                    position = { 0, 0, 180 },
                    velocity = { 0, 0, -160 },
                },
                tags = { "baseline", "frontal" },
            },
            notes = "Baseline straight-line projectile used by telemetry and diagnostics specs.",
        },
        {
            time = 0.45,
            macro = "oscillation storm",
            options = {
                rule = "highlight-gate",
                duration = 0.3,
                frequencyHz = 20,
                values = { true, false },
            },
            notes = "Simulate highlight flicker around the decision window to stress telemetry capture.",
        },
        {
            time = 0.9,
            type = "player",
            player = {
                action = "observe-telemetry",
                duration = 0.35,
            },
            notes = "Allow telemetry buffers to stabilise before sampling diagnostics and smart tuning snapshots.",
        },
    },
}
