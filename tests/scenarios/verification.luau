return {
    version = 1,
    metadata = {
        id = "verification_ladder_regression",
        label = "Verification ladder regression coverage",
        description = "Exercises balls folder discovery, remote verification, and restart handling with deliberate outages.",
        tags = { "verification", "spec", "init" },
        history = {
            "tests/autoparry/verification_status.spec.lua",
        },
    },
    config = {
        autoparry = {
            playerTimeout = 5,
            remotesTimeout = 5,
            ballsFolderTimeout = 5,
            verificationRetryInterval = 0.5,
        },
    },
    timeline = {
        {
            time = 0,
            type = "rule",
            rule = "balls-folder-present",
            value = false,
            notes = "Start with the balls folder absent so the verification ladder reports waiting status.",
        },
        {
            time = 0.25,
            type = "network",
            network = {
                event = "remotes:ParryButtonPress",
                direction = "observe",
                payload = { available = true },
            },
            notes = "ParryButtonPress remote is discovered immediately during initial verification.",
        },
        {
            time = 1.5,
            type = "rule",
            rule = "balls-folder-present",
            value = true,
            notes = "Workspace receives the Balls folder, allowing verification to transition to ready state.",
        },
        {
            time = 2.0,
            macro = "hitch gauntlet",
            options = {
                count = 5,
                interval = 0.18,
                magnitude = 0.18,
            },
            notes = "Inject periodic scheduler hitches to confirm the ladder continues reporting progress.",
        },
        {
            time = 3.5,
            type = "network",
            network = {
                event = "remotes:ParryButtonPress",
                direction = "observe",
                payload = { available = false },
            },
            notes = "Remote is removed mid-session, forcing the verification ladder to restart.",
        },
        {
            time = 5.5,
            type = "network",
            network = {
                event = "remotes:ParryButtonPress",
                direction = "observe",
                payload = { available = true },
            },
            notes = "Remote becomes available again, allowing verification to settle on the configured name.",
        },
    },
}
