return {
    version = 1,
    metadata = {
        id = "configuration_api_contract",
        label = "Configuration API contract",
        description = "Applies valid overrides, rejects invalid inputs, and resets to defaults for the configuration surface.",
        tags = { "configuration", "spec" },
        history = {
            "tests/autoparry/config.spec.lua",
        },
    },
    config = {
        autoparry = {
            cooldown = 0.25,
            minSpeed = 60,
            pingOffset = 0.02,
            minTTI = 0.1,
            maxTTI = 3.0,
            safeRadius = 12,
            targetHighlightName = "Highlight",
            ballsFolderName = "Balls",
            playerTimeout = 5,
            remotesTimeout = 5,
            ballsFolderTimeout = 5,
            verificationRetryInterval = 0.5,
        },
    },
    timeline = {
        {
            time = 0,
            type = "player",
            player = {
                action = "configure",
                parameters = {
                    overrides = {
                        cooldown = "default + 0.05",
                        minSpeed = "default + 15",
                        pingOffset = "default + 0.02",
                        minTTI = "default + 0.05",
                        maxTTI = "default + 0.1",
                        safeRadius = "default + 5",
                        targetHighlightName = "HighlightOverride",
                        ballsFolderName = "Projectiles",
                        playerTimeout = "default + 5",
                        remotesTimeout = "default + 5",
                        ballsFolderTimeout = "default + 5",
                        verificationRetryInterval = "default + 0.1",
                    },
                },
            },
            notes = "Snapshot of accepted configuration overrides mirrored from the spec coverage.",
        },
        {
            time = 1.0,
            type = "player",
            player = {
                action = "configure-invalid",
                parameters = {
                    overrides = {
                        cooldown = -1,
                        minSpeed = -5,
                        pingOffset = "offset",
                        minTTI = -0.25,
                        maxTTI = -0.5,
                        safeRadius = -10,
                        targetHighlightName = "",
                        ballsFolderName = "",
                        playerTimeout = -1,
                        remotesTimeout = -1,
                        ballsFolderTimeout = -1,
                        verificationRetryInterval = -0.1,
                    },
                },
            },
            notes = "Invalid overrides that must be rejected without mutating the stored configuration.",
        },
        {
            time = 2.0,
            type = "player",
            player = {
                action = "reset-config",
            },
            notes = "Reset back to defaults to confirm config mutations can be rolled back.",
        },
    },
}
