import {
    chmodSync,
    mkdirSync,
    readdirSync,
    renameSync,
    statSync,
    unlinkSync,
    writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import type {
    AgentActivityOutcome,
    BeforeAgentStartEvent,
    ExtensionAPI,
    ExtensionContext,
} from "@earendil-works/pi-coding-agent";

type PanelStatus = "idle" | "running" | "waitingForInput" | "completed" | "failed";

interface PanelState {
    schemaVersion: 1;
    source: "pi";
    pid: number;
    sessionId: string;
    sessionFile?: string;
    mode: string;
    cwd: string;
    title: string;
    status: PanelStatus;
    startedAt: string;
    stateChangedAt: string;
    heartbeatAt: string;
}

const HEARTBEAT_INTERVAL_MS = 5_000;
const STATE_FILE_RETENTION_MS = 10 * 60 * 1_000;
const MAX_TITLE_LENGTH = 80;

function stateDirectory(): string {
    const override = process.env.CODEX_STATUS_PANEL_PI_STATE_DIR?.trim();
    if (override) return override;
    return path.join(
        homedir(),
        "Library",
        "Application Support",
        "io.github.mayday-materials.codex-status-panel",
        "pi-sessions",
    );
}

function titleFromPrompt(pi: ExtensionAPI, event: BeforeAgentStartEvent): string {
    const sessionName = pi.getSessionName()?.trim();
    if (sessionName) return sessionName.slice(0, MAX_TITLE_LENGTH);

    const line = event.prompt
        .split(/\r?\n/)
        .map((value) => value.trim())
        .find((value) => value.length > 0);
    return (line || "Pi 会话").slice(0, MAX_TITLE_LENGTH);
}

export default function (pi: ExtensionAPI) {
    const directory = stateDirectory();
    const outputPath = path.join(directory, `${process.pid}.json`);
    const temporaryPath = `${outputPath}.tmp`;
    let state: PanelState | undefined;
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    let agentActive = false;
    let promptDepth = 0;
    let outcome: AgentActivityOutcome = "completed";

    function reportWriteFailure(error: unknown): void {
        const detail = error instanceof Error ? error.message : String(error);
        process.stderr.write(`pi-status-bridge: 无法写入 ${outputPath}：${detail}\n`);
    }

    function prepareStateDirectory(): void {
        mkdirSync(directory, { recursive: true, mode: 0o700 });
        chmodSync(directory, 0o700);
        const cutoff = Date.now() - STATE_FILE_RETENTION_MS;
        for (const entry of readdirSync(directory, { withFileTypes: true })) {
            if (!entry.isFile() || !/^\d+\.json(?:\.tmp)?$/.test(entry.name)) continue;
            const candidate = path.join(directory, entry.name);
            try {
                if (statSync(candidate).mtimeMs < cutoff) unlinkSync(candidate);
            } catch (error) {
                if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
            }
        }
    }

    function writeState(): void {
        if (!state) return;
        try {
            prepareStateDirectory();
            writeFileSync(temporaryPath, `${JSON.stringify(state)}\n`, {
                encoding: "utf8",
                mode: 0o600,
            });
            chmodSync(temporaryPath, 0o600);
            renameSync(temporaryPath, outputPath);
        } catch (error) {
            reportWriteFailure(error);
        }
    }

    function ensureState(ctx: ExtensionContext): PanelState {
        const now = new Date().toISOString();
        if (!state) {
            state = {
                schemaVersion: 1,
                source: "pi",
                pid: process.pid,
                sessionId: ctx.sessionManager.getSessionId(),
                sessionFile: ctx.sessionManager.getSessionFile(),
                mode: ctx.mode,
                cwd: ctx.cwd,
                title: pi.getSessionName()?.trim().slice(0, MAX_TITLE_LENGTH) || "Pi 会话",
                status: "idle",
                startedAt: now,
                stateChangedAt: now,
                heartbeatAt: now,
            };
        } else {
            state.sessionId = ctx.sessionManager.getSessionId();
            state.sessionFile = ctx.sessionManager.getSessionFile();
            state.mode = ctx.mode;
            state.cwd = ctx.cwd;
        }
        return state;
    }

    function updateStatus(
        ctx: ExtensionContext,
        status: PanelStatus,
        options: { title?: string; startsTask?: boolean } = {},
    ): void {
        const current = ensureState(ctx);
        const now = new Date().toISOString();
        if (options.title) current.title = options.title;
        if (options.startsTask) current.startedAt = now;
        if (current.status !== status || options.startsTask) {
            current.status = status;
            current.stateChangedAt = now;
        }
        current.heartbeatAt = now;
        writeState();
    }

    function startHeartbeat(ctx: ExtensionContext): void {
        if (heartbeat) clearInterval(heartbeat);
        heartbeat = setInterval(() => {
            if (!state || (!agentActive && promptDepth === 0)) return;
            ensureState(ctx).heartbeatAt = new Date().toISOString();
            writeState();
        }, HEARTBEAT_INTERVAL_MS);
    }

    function stopHeartbeat(): void {
        if (!heartbeat) return;
        clearInterval(heartbeat);
        heartbeat = undefined;
    }

    pi.on("session_start", (_event, ctx) => {
        agentActive = false;
        promptDepth = 0;
        outcome = "completed";
        state = undefined;
        updateStatus(ctx, "idle");
        startHeartbeat(ctx);
    });

    pi.on("session_info_changed", (event, ctx) => {
        const title = event.name?.trim();
        if (!title) return;
        ensureState(ctx).title = title.slice(0, MAX_TITLE_LENGTH);
        writeState();
    });

    pi.on("before_agent_start", (event, ctx) => {
        agentActive = true;
        promptDepth = 0;
        outcome = "completed";
        updateStatus(ctx, "running", {
            title: titleFromPrompt(pi, event),
            startsTask: true,
        });
    });

    pi.on("agent_start", (_event, ctx) => {
        agentActive = true;
        updateStatus(ctx, promptDepth > 0 ? "waitingForInput" : "running");
    });

    pi.on("ui_prompt_start", (event, ctx) => {
        promptDepth += 1;
        const title = agentActive
            ? undefined
            : event.title?.trim().slice(0, MAX_TITLE_LENGTH);
        updateStatus(ctx, "waitingForInput", {
            title,
            startsTask: !agentActive && promptDepth === 1,
        });
    });

    pi.on("ui_prompt_end", (_event, ctx) => {
        promptDepth = Math.max(0, promptDepth - 1);
        if (promptDepth > 0) {
            updateStatus(ctx, "waitingForInput");
        } else if (agentActive) {
            updateStatus(ctx, "running");
        } else {
            updateStatus(ctx, "idle");
        }
    });

    pi.on("turn_end", (event) => {
        outcome = event.outcome;
    });

    pi.on("agent_before_settle", (event) => {
        outcome = event.outcome;
    });

    pi.on("agent_settled", (_event, ctx) => {
        agentActive = false;
        promptDepth = 0;
        updateStatus(ctx, outcome === "completed" ? "completed" : "failed");
    });

    pi.on("session_shutdown", (_event, ctx) => {
        stopHeartbeat();
        if (agentActive || promptDepth > 0) {
            updateStatus(ctx, "failed");
        } else if (state) {
            ensureState(ctx).heartbeatAt = new Date().toISOString();
            writeState();
        }
        agentActive = false;
        promptDepth = 0;
    });
}
