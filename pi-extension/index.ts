import net from "node:net";
import os from "node:os";
import path from "node:path";
import type {
	ExtensionAPI,
	ExtensionContext,
	ToolCallEvent,
	ToolExecutionEndEvent,
	ToolExecutionStartEvent,
	ToolExecutionUpdateEvent,
} from "@ggwplarin/pi-coding-agent";

const VERSION = 1;

const METHOD_SESSION_UPSERT = "session.upsert";
const METHOD_SESSION_REMOVE = "session.remove";
const METHOD_TOOL_START = "tool.start";
const METHOD_TOOL_UPDATE = "tool.update";
const METHOD_TOOL_END = "tool.end";
const METHOD_APPROVAL_REQUEST = "approval.request";

type SessionStatus = "idle" | "thinking" | "running" | "done" | "failed" | "disconnected";
type ToolState = "running" | "done" | "failed";
type ApprovalDecision = "approved" | "denied" | "expired";

type ProtocolMessage = {
	version: number;
	kind: "request" | "response" | "event";
	id?: string;
	method: string;
	payload?: unknown;
	error?: { code: string; message: string };
};

type SessionPayload = {
	sessionId: string;
	cwd?: string;
	title?: string;
	status: SessionStatus;
	safeSummary?: string;
};

type ToolPayload = {
	sessionId: string;
	toolCallId: string;
	toolName: string;
	state?: ToolState;
	safeSummary?: string;
};

type ApprovalPayload = {
	approvalId: string;
	sessionId: string;
	toolCallId?: string;
	toolName: string;
	commandSummary?: string;
	risk?: string;
	timeoutMillis?: number;
};

type ApprovalResponse = {
	approvalId: string;
	decision: ApprovalDecision;
	reason?: string;
};

type PiPetClientOptions = {
	socketPath?: string;
	requestTimeoutMillis?: number;
	transport?: (message: ProtocolMessage, timeoutMillis: number, signal?: AbortSignal) => Promise<ProtocolMessage>;
};

type MinimalContext = Pick<ExtensionContext, "cwd" | "sessionManager">;

let requestCounter = 0;

export default function piPetExtension(pi: ExtensionAPI): void {
	const client = new PiPetClient();

	pi.on("session_start", (event, ctx) => {
		client.notifySession(sessionPayload(ctx, "idle", `session ${event.reason}`));
	});

	pi.on("session_shutdown", (event, ctx) => {
		client.notifySession(sessionPayload(ctx, "disconnected", `session ${event.reason}`));
	});

	pi.on("before_agent_start", (_event, ctx) => {
		client.notifySession(sessionPayload(ctx, "thinking", "agent preparing"));
	});

	pi.on("agent_start", (_event, ctx) => {
		client.notifySession(sessionPayload(ctx, "running", "agent running"));
	});

	pi.on("turn_start", (event, ctx) => {
		client.notifySession(sessionPayload(ctx, "running", `turn ${event.turnIndex + 1} running`));
	});

	pi.on("turn_end", (event, ctx) => {
		client.notifySession(sessionPayload(ctx, "running", `turn ${event.turnIndex + 1} done`));
	});

	pi.on("agent_end", (_event, ctx) => {
		client.notifySession(sessionPayload(ctx, "done", "agent done"));
	});

	pi.on("after_provider_response", (event, ctx) => {
		if (event.status >= 400) {
			client.notifySession(sessionPayload(ctx, "failed", `provider HTTP ${event.status}`));
		}
	});

	pi.on("tool_call", async (event, ctx) => {
		if (!shouldRequireApproval(event)) return undefined;

		const approval = approvalPayload(event, ctx);
		const decision = await client.requestApproval(approval, ctx.signal);
		if (decision.decision !== "approved") {
			return {
				block: true,
				reason: decision.reason || `Pi Pet approval ${decision.decision}`,
			};
		}
		return undefined;
	});

	pi.on("tool_execution_start", (event, ctx) => {
		client.notifyToolStart(toolPayload(event, ctx, "running", "started"));
	});

	pi.on("tool_execution_update", (event, ctx) => {
		client.notifyToolUpdate(toolPayload(event, ctx, "running", "running"));
	});

	pi.on("tool_execution_end", (event, ctx) => {
		client.notifyToolEnd(toolPayload(event, ctx, event.isError ? "failed" : "done", event.isError ? "failed" : "done"));
		if (event.isError) {
			client.notifySession(sessionPayload(ctx, "failed", `${event.toolName} failed`));
		}
	});
}

export class PiPetClient {
	private socketPath: string;
	private requestTimeoutMillis: number;
	private transport: ((message: ProtocolMessage, timeoutMillis: number, signal?: AbortSignal) => Promise<ProtocolMessage>) | undefined;
	private notificationQueue: Promise<void> = Promise.resolve();

	constructor(options: PiPetClientOptions = {}) {
		this.socketPath = options.socketPath || defaultSocketPath();
		this.requestTimeoutMillis = options.requestTimeoutMillis ?? 3000;
		this.transport = options.transport;
	}

	notifySession(payload: SessionPayload): void {
		this.enqueueNotification(METHOD_SESSION_UPSERT, payload);
	}

	notifyToolStart(payload: ToolPayload): void {
		this.enqueueNotification(METHOD_TOOL_START, payload);
	}

	notifyToolUpdate(payload: ToolPayload): void {
		this.enqueueNotification(METHOD_TOOL_UPDATE, payload);
	}

	notifyToolEnd(payload: ToolPayload): void {
		this.enqueueNotification(METHOD_TOOL_END, payload);
	}

	async requestApproval(payload: ApprovalPayload, signal?: AbortSignal): Promise<ApprovalResponse> {
		try {
			await withAbort(this.flushNotifications(), signal);
			const response = await this.request(METHOD_APPROVAL_REQUEST, payload, payload.timeoutMillis || 10 * 60 * 1000, signal);
			return response.payload as ApprovalResponse;
		} catch (error) {
			return {
				approvalId: payload.approvalId,
				decision: "denied",
				reason: isAbortError(error) ? "Pi Pet approval was cancelled" : "Pi Pet daemon is unavailable for approval",
			};
		}
	}

	async flushNotifications(): Promise<void> {
		await this.notificationQueue;
	}

	async request(
		method: string,
		payload: unknown,
		timeoutMillis = this.requestTimeoutMillis,
		signal?: AbortSignal,
	): Promise<ProtocolMessage> {
		const id = `${Date.now().toString(36)}-${++requestCounter}`;
		const message: ProtocolMessage = {
			version: VERSION,
			kind: "request",
			id,
			method,
			payload,
		};
		if (signal?.aborted) throw abortError();
		if (this.transport) {
			return withAbort(this.transport(message, timeoutMillis, signal), signal);
		}
		const line = `${JSON.stringify(message)}\n`;

		return new Promise((resolve, reject) => {
			const socket = net.createConnection(this.socketPath);
			let buffer = "";
			let settled = false;
			const cleanup = () => {
				clearTimeout(timer);
				signal?.removeEventListener("abort", onAbort);
			};
			const fail = (error: Error) => {
				if (settled) return;
				settled = true;
				cleanup();
				socket.destroy();
				reject(error);
			};
			const succeed = (response: ProtocolMessage) => {
				if (settled) return;
				settled = true;
				cleanup();
				socket.end();
				resolve(response);
			};
			const onAbort = () => fail(abortError());
			const timer = setTimeout(() => {
				fail(new Error("pi pet daemon request timed out"));
			}, timeoutMillis);
			signal?.addEventListener("abort", onAbort, { once: true });

			socket.on("connect", () => {
				socket.write(line);
			});

			socket.on("data", (chunk) => {
				buffer += chunk.toString("utf8");
				const newline = buffer.indexOf("\n");
				if (newline === -1) return;
				const raw = buffer.slice(0, newline);
				try {
					const response = JSON.parse(raw) as ProtocolMessage;
					if (response.error) {
						fail(new Error(response.error.message));
					} else {
						succeed(response);
					}
				} catch (error) {
					fail(error instanceof Error ? error : new Error(String(error)));
				}
			});

			socket.on("error", (error) => {
				fail(error);
			});

			socket.on("close", () => {
				cleanup();
			});
		});
	}

	private enqueueNotification(method: string, payload: unknown): void {
		this.notificationQueue = this.notificationQueue.then(
			() => this.request(method, payload).then(
				() => {},
				() => {},
			),
			() => {},
		);
	}
}

export function defaultSocketPath(): string {
	const runtimeDir = process.env.PI_PET_SOCKET_DIR || process.env.XDG_RUNTIME_DIR;
	if (runtimeDir) return path.join(runtimeDir, "pi-pet.sock");
	return path.join(os.tmpdir(), `codex-pets-${os.userInfo().uid}`, "pi-pet.sock");
}

export function shouldRequireApproval(event: ToolCallEvent): boolean {
	if (process.env.PI_PET_APPROVE_ALL_TOOLS === "1") return true;
	if (event.toolName !== "bash") return false;
	const command = String((event.input as { command?: unknown }).command || "");
	return commandRisk(command) !== "low";
}

export function commandRisk(command: string): "low" | "medium" | "high" {
	const normalized = command.toLowerCase();
	if (/\brm\s+(-rf|-fr|--recursive)\b/.test(normalized)) return "high";
	if (/\bsudo\b/.test(normalized)) return "high";
	if (/\bgit\s+push\b/.test(normalized)) return "medium";
	if (/\bchmod\b.*\b777\b/.test(normalized)) return "medium";
	if (/\bchown\b/.test(normalized)) return "medium";
	return "low";
}

export function summarizeToolCall(event: Pick<ToolCallEvent, "toolName" | "input">): string {
	if (event.toolName === "bash") {
		return summarizeCommand(String((event.input as { command?: unknown }).command || ""));
	}
	if (event.toolName === "read") {
		return safeSummary(`read ${(event.input as { path?: unknown }).path || ""}`);
	}
	if (event.toolName === "edit" || event.toolName === "write") {
		return safeSummary(`${event.toolName} ${(event.input as { path?: unknown }).path || ""}`);
	}
	return safeSummary(event.toolName);
}

export function summarizeCommand(command: string): string {
	const firstLine = command.split(/\r?\n/, 1)[0] || "";
	const collapsed = firstLine.replace(/\s+/g, " ").trim();
	return safeSummary(collapsed);
}

export function safeSummary(value: string): string {
	const collapsed = value.replace(/\s+/g, " ").trim();
	return collapsed.length <= 180 ? collapsed : collapsed.slice(0, 180);
}

export function sessionPayload(ctx: MinimalContext, status: SessionStatus, safeSummary?: string): SessionPayload {
	return {
		sessionId: sessionID(ctx),
		cwd: ctx.cwd || process.cwd(),
		title: sessionTitle(ctx),
		status,
		safeSummary: safeSummary ? safeSummary : undefined,
	};
}

export function approvalPayload(event: ToolCallEvent, ctx: MinimalContext): ApprovalPayload {
	const sessionId = sessionID(ctx);
	const risk = event.toolName === "bash" ? commandRisk(String((event.input as { command?: unknown }).command || "")) : "medium";
	return {
		approvalId: `${sessionId}:${event.toolCallId}`,
		sessionId,
		toolCallId: event.toolCallId,
		toolName: event.toolName,
		commandSummary: summarizeToolCall(event),
		risk,
		timeoutMillis: positiveInt(process.env.PI_PET_APPROVAL_TIMEOUT_MS) || 10 * 60 * 1000,
	};
}

function toolPayload(
	event: ToolExecutionStartEvent | ToolExecutionUpdateEvent | ToolExecutionEndEvent,
	ctx: MinimalContext,
	state: ToolState,
	verb: string,
): ToolPayload {
	return {
		sessionId: sessionID(ctx),
		toolCallId: event.toolCallId,
		toolName: event.toolName,
		state,
		safeSummary: safeSummary(`${event.toolName} ${verb}`),
	};
}

function withAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
	if (!signal) return promise;
	if (signal.aborted) return Promise.reject(abortError());
	return new Promise((resolve, reject) => {
		const onAbort = () => reject(abortError());
		signal.addEventListener("abort", onAbort, { once: true });
		promise.then(resolve, reject).finally(() => {
			signal.removeEventListener("abort", onAbort);
		});
	});
}

function abortError(): Error {
	const error = new Error("pi pet request aborted");
	error.name = "AbortError";
	return error;
}

function isAbortError(error: unknown): boolean {
	return error instanceof Error && error.name === "AbortError";
}

function sessionID(ctx: MinimalContext): string {
	const manager = ctx.sessionManager as unknown as {
		getSessionId?: () => string;
		getSessionFile?: () => string | undefined;
	};
	return manager.getSessionId?.() || manager.getSessionFile?.() || `${ctx.cwd || process.cwd()}:${process.pid}`;
}

function sessionTitle(ctx: MinimalContext): string {
	const cwd = ctx.cwd || process.cwd();
	return path.basename(cwd) || cwd;
}

function positiveInt(value: string | undefined): number | undefined {
	if (!value) return undefined;
	const parsed = Number.parseInt(value, 10);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}
