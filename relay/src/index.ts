export interface Env {
  WEBHOOK_SECRET: string;
  AUTH_TOKEN: string;
  WEBSOCKET_ROOM: DurableObjectNamespace;
}

// --- Crypto helpers ---

async function verifySignature(
  secret: string,
  payload: string,
  signature: string,
): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  const digest = "sha256=" + hexEncode(new Uint8Array(sig));
  return timingSafeEqual(digest, signature);
}

function hexEncode(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  const encoder = new TextEncoder();
  const aBuf = encoder.encode(a);
  const bBuf = encoder.encode(b);
  let diff = 0;
  for (let i = 0; i < aBuf.length; i++) {
    diff |= aBuf[i] ^ bBuf[i];
  }
  return diff === 0;
}

// --- Relevant PR actions ---

const RELEVANT_PR_ACTIONS = new Set([
  "opened",
  "closed",
  "synchronize",
  "reopened",
  "ready_for_review",
]);

const RELEVANT_REVIEW_ACTIONS = new Set(["submitted"]);

// --- Worker fetch handler ---

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/webhook" && request.method === "POST") {
      return handleWebhook(request, env);
    }

    if (url.pathname === "/ws" && request.method === "GET") {
      return handleWebSocket(request, url, env);
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleWebhook(request: Request, env: Env): Promise<Response> {
  const signature = request.headers.get("X-Hub-Signature-256");
  if (!signature) {
    return new Response("Missing signature", { status: 401 });
  }

  const body = await request.text();

  const valid = await verifySignature(env.WEBHOOK_SECRET, body, signature);
  if (!valid) {
    return new Response("Invalid signature", { status: 403 });
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(body);
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const eventType = request.headers.get("X-GitHub-Event") ?? "";
  const action = payload.action as string | undefined;

  let envelope: Record<string, unknown>;

  if (eventType === "check_run") {
    if (action !== "completed") {
      return new Response("Ignored action", { status: 200 });
    }
    const checkRun = payload.check_run as Record<string, unknown> | undefined;
    if (!checkRun) {
      return new Response("Not a check_run event", { status: 200 });
    }
    // Extract PR numbers from the check run's pull_requests array
    const prs = checkRun.pull_requests as Array<Record<string, unknown>> | undefined;
    const repo = payload.repository as Record<string, unknown> | undefined;
    if (!prs || prs.length === 0) {
      return new Response("No associated PRs", { status: 200 });
    }
    envelope = {
      type: "check_run_event",
      check_run: {
        name: checkRun.name,
        status: checkRun.status,
        conclusion: checkRun.conclusion,
      },
      prs: prs.map((pr) => ({ number: pr.number })),
      repo: {
        full_name: repo?.full_name ?? null,
      },
      timestamp: new Date().toISOString(),
    };
  } else if (eventType === "pull_request_review") {
    if (!action || !RELEVANT_REVIEW_ACTIONS.has(action)) {
      return new Response("Ignored action", { status: 200 });
    }
    const review = payload.review as Record<string, unknown> | undefined;
    const pr = payload.pull_request as Record<string, unknown> | undefined;
    const repo = payload.repository as Record<string, unknown> | undefined;
    if (!review || !pr) {
      return new Response("Not a review event", { status: 200 });
    }
    envelope = {
      type: "review_event",
      action,
      review: {
        state: review.state,
        user_login: (review.user as Record<string, unknown>)?.login ?? null,
        avatar_url: (review.user as Record<string, unknown>)?.avatar_url ?? null,
      },
      pr: {
        number: pr.number,
        title: pr.title,
        html_url: pr.html_url,
      },
      repo: {
        full_name: repo?.full_name ?? null,
      },
      timestamp: new Date().toISOString(),
    };
  } else {
    // pull_request event
    if (!action || !RELEVANT_PR_ACTIONS.has(action)) {
      return new Response("Ignored action", { status: 200 });
    }
    const pr = payload.pull_request as Record<string, unknown> | undefined;
    if (!pr) {
      return new Response("Not a PR event", { status: 200 });
    }
    const repo = payload.repository as Record<string, unknown> | undefined;
    envelope = {
      type: "pr_event",
      action,
      pr: {
        number: pr.number,
        title: pr.title,
        html_url: pr.html_url,
        created_at: pr.created_at,
        updated_at: pr.updated_at,
        avatar_url: (pr.user as Record<string, unknown>)?.avatar_url ?? null,
        body: pr.body ?? "",
        user_login: (pr.user as Record<string, unknown>)?.login ?? null,
      },
      repo: {
        full_name: repo?.full_name ?? null,
      },
      timestamp: new Date().toISOString(),
    };
  }

  // Forward to the singleton Durable Object
  const id = env.WEBSOCKET_ROOM.idFromName("default");
  const stub = env.WEBSOCKET_ROOM.get(id);
  await stub.fetch(
    new Request("https://internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(envelope),
    }),
  );

  return new Response("OK", { status: 200 });
}

async function handleWebSocket(
  request: Request,
  url: URL,
  env: Env,
): Promise<Response> {
  const token = url.searchParams.get("token");
  if (!token || token !== env.AUTH_TOKEN) {
    return new Response("Unauthorized", { status: 401 });
  }

  const upgradeHeader = request.headers.get("Upgrade");
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
    return new Response("Expected WebSocket upgrade", { status: 426 });
  }

  const id = env.WEBSOCKET_ROOM.idFromName("default");
  const stub = env.WEBSOCKET_ROOM.get(id);
  return stub.fetch(request);
}

// --- Durable Object ---

export class WebSocketRoom implements DurableObject {
  ctx: DurableObjectState;

  constructor(ctx: DurableObjectState, _env: Env) {
    this.ctx = ctx;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/broadcast" && request.method === "POST") {
      const message = await request.text();
      this.broadcast(message);
      return new Response("Broadcast sent", { status: 200 });
    }

    // WebSocket upgrade
    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket", { status: 400 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.ctx.acceptWebSocket(server);

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    // Handle ping/pong or other client messages
    if (typeof message === "string") {
      try {
        const data = JSON.parse(message);
        if (data.type === "ping") {
          ws.send(JSON.stringify({ type: "pong" }));
        }
      } catch {
        // Non-JSON message, ignore
      }
    }
  }

  webSocketClose(
    ws: WebSocket,
    code: number,
    _reason: string,
    _wasClean: boolean,
  ): void {
    try {
      ws.close(code, "Connection closed");
    } catch {
      // Already closed, ignore
    }
  }

  webSocketError(ws: WebSocket, _error: unknown): void {
    try {
      ws.close(1011, "Internal error");
    } catch {
      // Already closed, ignore
    }
  }

  private broadcast(message: string): void {
    const sockets = this.ctx.getWebSockets();
    for (const ws of sockets) {
      try {
        ws.send(message);
      } catch {
        // Socket is dead; close it so it gets cleaned up
        try {
          ws.close(1011, "Send failed");
        } catch {
          // Already closed
        }
      }
    }
  }
}
