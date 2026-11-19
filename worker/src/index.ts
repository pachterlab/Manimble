// manimble-examples: anyone can share a presentation made with Manimble for the website's Examples page
// (docs/examples.md), from the page itself or with `manimbler --submit`. A submission is checked, rate limited
// and stored privately as pending; a GitHub issue tells the maintainers, who approve or reject it with
// scripts/examples_admin.py. Approved examples are listed by GET /examples, which the page shows.
//
//   POST /submit                      body: the .manimble package (a zip), as is
//                                     X-Manimble-Meta: encodeURIComponent(JSON {title, authors, institution?,
//                                       date?, keywords?, description?, agree: true})
//                                     -> {id, issue_url?}
//   GET  /examples                    -> {examples: [approved example, newest first]}
//   GET  /examples/<id>/package       the package (pending ones too: the link is in their review issue)
//   GET  /admin/examples?status=...   Authorization: Bearer ADMIN_TOKEN
//   POST /admin/examples/<id>/approve | /reject   (reject deletes the package)

import { checkPackage } from "./zip.ts";

export interface Env {
  DB: D1Database;
  /** Private: packages/<id>.manimble. Served only through this Worker. */
  PACKAGES: R2Bucket;
  /** Short-term limit on upload attempts per IP address (wrangler.jsonc). */
  UPLOADS: RateLimit;
  /** Comma-separated origins whose pages may upload (the docs site, and a local `mkdocs serve`). */
  ALLOWED_ORIGINS: string;
  /** The repository the review issues are opened in, as owner/name. */
  GITHUB_REPO: string;
  /** Secret: the maintainers' key for /admin (`wrangler secret put ADMIN_TOKEN`). */
  ADMIN_TOKEN?: string;
  /** Optional secret: a token that may open issues in GITHUB_REPO. Without it no issue is opened. */
  GITHUB_TOKEN?: string;
  /** Optional secret salting the IP hashes. */
  IP_SALT?: string;
}

// Keep in sync with manimbler (MAX_EXAMPLE_BYTES) and docs/assets/examples.js.
const MAX_PACKAGE_BYTES = 95 * 1024 * 1024; // Workers accept request bodies up to 100 MB
const MAX_PER_IP_PER_DAY = 5;
const MAX_PENDING = 200;
const LIMITS = { title: 200, authors: 500, institution: 200, keywords: 300, description: 2000 };

class Rejected extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

interface Meta {
  title: string;
  authors: string;
  institution: string;
  date: string;
  keywords: string[];
  description: string;
}

interface Row extends Omit<Meta, "keywords"> {
  id: string;
  status: string;
  keywords: string;
  size: number;
  issue_url: string;
  created: number;
  reviewed: number | null;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const cors = corsHeaders(req, env, url.pathname);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    let response: Response;
    try {
      response = await route(req, url, env);
    } catch (e) {
      if (e instanceof Rejected) response = json({ error: e.message }, e.status);
      else {
        console.error(e);
        response = json({ error: "Something went wrong on the server; please try again later." }, 500);
      }
    }
    for (const [k, v] of Object.entries(cors)) response.headers.set(k, v);
    return response;
  },
} satisfies ExportedHandler<Env>;

async function route(req: Request, url: URL, env: Env): Promise<Response> {
  const path = url.pathname;
  if (path === "/submit" && req.method === "POST") return submit(req, env);
  if (path === "/examples" && req.method === "GET") return list(url.origin, env);
  const download = /^\/examples\/([0-9a-f]{32})\/package$/.exec(path);
  if (download && (req.method === "GET" || req.method === "HEAD")) return packageFile(download[1], req, env);
  if (path.startsWith("/admin/")) {
    await requireAdmin(req, env);
    if (path === "/admin/examples" && req.method === "GET") return adminList(url, env);
    const review = /^\/admin\/examples\/([0-9a-f]{32})\/(approve|reject)$/.exec(path);
    if (review && req.method === "POST") return decide(review[1], review[2] as "approve" | "reject", env);
  }
  if (path === "/") return new Response("Manimble examples\n");
  return json({ error: "Not found" }, 404);
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

function corsHeaders(req: Request, env: Env, path: string): Record<string, string> {
  const origin = req.headers.get("origin");
  if (path === "/examples" || path.startsWith("/examples/")) return { "access-control-allow-origin": "*" };
  if (path !== "/submit" || !origin) return {};
  const allowed = env.ALLOWED_ORIGINS.split(",").map((o) => o.trim());
  if (!allowed.includes(origin)) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST",
    "access-control-allow-headers": "content-type, x-manimble-meta",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

// ---- Submitting

function text(value: unknown, name: keyof typeof LIMITS, required: boolean): string {
  if (value !== undefined && value !== null && typeof value !== "string") throw new Rejected(`${name} must be text`);
  // Collapse whitespace (newlines kept in descriptions) and drop control characters.
  const keepLines = name === "description";
  const cleaned = (value ?? "")
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(keepLines ? /[ \t]+/g : /\s+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  if (required && !cleaned) throw new Rejected(`Please give the ${name === "authors" ? "authors" : name}.`);
  if (cleaned.length > LIMITS[name]) throw new Rejected(`The ${name} is too long (at most ${LIMITS[name]} characters).`);
  return cleaned;
}

export function parseMeta(header: string | null): Meta {
  if (!header) throw new Rejected("The submission's details are missing.");
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(decodeURIComponent(header));
  } catch {
    throw new Rejected("The submission's details are not valid JSON.");
  }
  if (!raw || typeof raw !== "object") throw new Rejected("The submission's details are not valid JSON.");
  if (raw.agree !== true) throw new Rejected("Please confirm that you may share this presentation.");
  const date = typeof raw.date === "string" ? raw.date.trim() : "";
  if (date && (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date)))) {
    throw new Rejected("The date must be YYYY-MM-DD.");
  }
  const keywordText = Array.isArray(raw.keywords) ? raw.keywords.join(",") : raw.keywords;
  const keywords = [...new Set(text(keywordText, "keywords", false).split(",").map((k) => k.trim()).filter(Boolean))];
  if (keywords.length > 12) throw new Rejected("Give at most 12 keywords.");
  return {
    title: text(raw.title, "title", true),
    authors: text(raw.authors, "authors", true),
    institution: text(raw.institution, "institution", false),
    date,
    keywords,
    description: text(raw.description, "description", false),
  };
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function newId(): string {
  return [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function submit(req: Request, env: Env): Promise<Response> {
  const meta = parseMeta(req.headers.get("x-manimble-meta"));
  const size = Number(req.headers.get("content-length"));
  if (!req.body || !Number.isFinite(size) || size <= 0) throw new Rejected("The presentation file is missing.", 411);
  if (size > MAX_PACKAGE_BYTES) {
    throw new Rejected(`The file is larger than ${MAX_PACKAGE_BYTES / 1024 / 1024} MB. Share a link to it in a GitHub issue instead.`, 413);
  }
  const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
  if (!(await env.UPLOADS.limit({ key: ip })).success) {
    throw new Rejected("Too many uploads at once; please wait a minute and try again.", 429);
  }
  const now = Math.floor(Date.now() / 1000);
  const ipHash = await sha256Hex(`${env.IP_SALT ?? ""}:${ip}`);
  const [recent, pending] = await env.DB.batch<{ n: number }>([
    env.DB.prepare("SELECT count(*) AS n FROM examples WHERE ip_hash = ? AND created > ?").bind(ipHash, now - 86400),
    env.DB.prepare("SELECT count(*) AS n FROM examples WHERE status = 'pending'"),
  ]);
  if ((recent.results[0]?.n ?? 0) >= MAX_PER_IP_PER_DAY) {
    throw new Rejected("You have shared several examples today already; please try again tomorrow.", 429);
  }
  if ((pending.results[0]?.n ?? 0) >= MAX_PENDING) {
    throw new Rejected("Too many examples are waiting for review; please try again in a few days.", 503);
  }

  const id = newId();
  const key = `packages/${id}.manimble`;
  // Streamed straight into R2 (a 95 MB body doesn't fit comfortably in a Worker's memory), then checked there.
  const stored = await env.PACKAGES.put(key, req.body, {
    httpMetadata: { contentType: "application/zip" },
    customMetadata: { title: meta.title },
  });
  if (!stored || stored.size !== size) {
    await env.PACKAGES.delete(key);
    throw new Rejected("The upload was cut short; please try again.");
  }
  try {
    await checkPackage((offset, length) => readRange(env.PACKAGES, key, offset, length), size);
  } catch (e) {
    await env.PACKAGES.delete(key);
    throw e instanceof Error && !(e instanceof Rejected) ? new Rejected(e.message) : e;
  }
  await env.DB.prepare(
    `INSERT INTO examples (id, status, title, authors, institution, date, keywords, description, size, ip_hash, created)
     VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, meta.title, meta.authors, meta.institution, meta.date, JSON.stringify(meta.keywords), meta.description,
    size, ipHash, now).run();

  let issueUrl = "";
  try {
    issueUrl = await openIssue(id, meta, size, new URL(req.url).origin, env);
    if (issueUrl) await env.DB.prepare("UPDATE examples SET issue_url = ? WHERE id = ?").bind(issueUrl, id).run();
  } catch (e) {
    console.error("could not open the review issue", e); // the submission is kept; it shows in /admin/examples
  }
  return json({ id, issue_url: issueUrl || undefined }, 201);
}

async function readRange(bucket: R2Bucket, key: string, offset: number, length: number): Promise<Uint8Array> {
  const object = await bucket.get(key, { range: { offset, length } });
  if (!object) throw new Error("The stored package disappeared.");
  return new Uint8Array(await object.arrayBuffer());
}

// ---- GitHub

/** Markdown-safe text for a public issue: no mentions, no HTML, no links that look like something else. */
function quoted(value: string): string {
  return value.replace(/[\\`*_{}[\]<>()#+!|~]/g, "\\$&").replace(/@/g, "@\u200b").replace(/\n/g, "<br>");
}

function humanSize(size: number): string {
  return size >= 1024 * 1024 ? `${(size / 1024 / 1024).toFixed(1)} MB` : `${Math.ceil(size / 1024)} KB`;
}

async function github(path: string, init: RequestInit, env: Env): Promise<Response> {
  const response = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: "application/vnd.github+json",
      "user-agent": "manimble-examples-worker",
      "x-github-api-version": "2022-11-28",
      ...(init.headers ?? {}),
    },
  });
  if (!response.ok) throw new Error(`GitHub ${init.method ?? "GET"} ${path}: ${response.status} ${await response.text()}`);
  return response;
}

async function openIssue(id: string, meta: Meta, size: number, origin: string, env: Env): Promise<string> {
  if (!env.GITHUB_TOKEN) return "";
  const rows: [string, string][] = [
    ["Authors", meta.authors], ["Institution", meta.institution], ["Date", meta.date],
    ["Keywords", meta.keywords.join(", ")],
  ];
  const download = `${origin}/examples/${id}/package`;
  const body = [
    "A new example presentation was submitted for the [Examples page](https://pachterlab.github.io/Manimble/examples/).",
    "",
    "| | |", "|---|---|",
    `| **Title** | ${quoted(meta.title)} |`,
    ...rows.filter(([, v]) => v).map(([k, v]) => `| **${k}** | ${quoted(v)} |`),
    `| **Package** | [Download](${download}) (${humanSize(size)}) |`,
    "",
    ...(meta.description ? ["> " + quoted(meta.description), ""] : []),
    "To review it:",
    "",
    "```bash",
    `curl -L -o example.manimble ${download}`,
    "manimbler --check example.manimble && manimbler --info example.manimble",
    `worker/scripts/examples_admin.py approve ${id}   # or: reject ${id}`,
    "```",
    "",
    `<!-- manimble-example:${id} -->`,
  ].join("\n");
  const response = await github("/issues", {
    method: "POST",
    body: JSON.stringify({ title: `[Example] ${meta.title}`.slice(0, 250), body, labels: ["example"] }),
  }, env);
  return ((await response.json()) as { html_url: string }).html_url;
}

async function closeIssue(issueUrl: string, comment: string, reason: "completed" | "not_planned", env: Env) {
  const number = /\/issues\/(\d+)$/.exec(issueUrl)?.[1];
  if (!env.GITHUB_TOKEN || !number) return;
  await github(`/issues/${number}/comments`, { method: "POST", body: JSON.stringify({ body: comment }) }, env);
  await github(`/issues/${number}`, { method: "PATCH", body: JSON.stringify({ state: "closed", state_reason: reason }) }, env);
}

// ---- Reading

function publicExample(row: Row, origin: string) {
  return {
    id: row.id,
    title: row.title,
    authors: row.authors,
    institution: row.institution || undefined,
    date: row.date || undefined,
    keywords: JSON.parse(row.keywords) as string[],
    description: row.description || undefined,
    size: row.size,
    download_url: `${origin}/examples/${row.id}/package`,
    added: row.reviewed ? new Date(row.reviewed * 1000).toISOString().slice(0, 10) : undefined,
  };
}

async function list(origin: string, env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    "SELECT * FROM examples WHERE status = 'approved' ORDER BY reviewed DESC LIMIT 500",
  ).all<Row>();
  return json({ examples: results.map((row) => publicExample(row, origin)) }, 200, { "cache-control": "public, max-age=60" });
}

function filename(title: string): string {
  const slug = title.normalize("NFKD").replace(/[^\w\s-]/g, "").trim().replace(/[\s_-]+/g, "-").slice(0, 80);
  return `${slug || "example"}.manimble`;
}

async function packageFile(id: string, req: Request, env: Env): Promise<Response> {
  const row = await env.DB.prepare("SELECT title, status FROM examples WHERE id = ?").bind(id).first<Row>();
  if (!row || row.status === "rejected") return json({ error: "This example isn't available." }, 404);
  const key = `packages/${id}.manimble`;
  const object = req.method === "HEAD" ? await env.PACKAGES.head(key) : await env.PACKAGES.get(key);
  if (!object) return json({ error: "This example isn't available." }, 404);
  return new Response("body" in object ? (object as R2ObjectBody).body : null, {
    headers: {
      "content-type": "application/zip",
      "content-length": String(object.size),
      "content-disposition": `attachment; filename="${filename(row.title)}"`,
      "x-content-type-options": "nosniff",
      "cache-control": row.status === "approved" ? "public, max-age=3600" : "private, no-store",
    },
  });
}

// ---- Reviewing

async function requireAdmin(req: Request, env: Env): Promise<void> {
  const given = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!env.ADMIN_TOKEN || given.length !== env.ADMIN_TOKEN.length) throw new Rejected("Not authorized", 401);
  const a = new TextEncoder().encode(given), b = new TextEncoder().encode(env.ADMIN_TOKEN);
  if (!crypto.subtle.timingSafeEqual(a, b)) throw new Rejected("Not authorized", 401);
}

async function adminList(url: URL, env: Env): Promise<Response> {
  const status = url.searchParams.get("status") ?? "pending";
  if (!["pending", "approved", "rejected"].includes(status)) throw new Rejected("Unknown status");
  const { results } = await env.DB.prepare("SELECT * FROM examples WHERE status = ? ORDER BY created DESC LIMIT 500")
    .bind(status).all<Row>();
  return json({
    examples: results.map((row) => ({ ...publicExample(row, url.origin), status: row.status, issue_url: row.issue_url || undefined,
      submitted: new Date(row.created * 1000).toISOString() })),
  });
}

async function decide(id: string, action: "approve" | "reject", env: Env): Promise<Response> {
  const row = await env.DB.prepare("SELECT * FROM examples WHERE id = ?").bind(id).first<Row>();
  if (!row) throw new Rejected("No such example", 404);
  const status = action === "approve" ? "approved" : "rejected";
  if (action === "reject") await env.PACKAGES.delete(`packages/${id}.manimble`);
  await env.DB.prepare("UPDATE examples SET status = ?, reviewed = ? WHERE id = ?")
    .bind(status, Math.floor(Date.now() / 1000), id).run();
  try {
    await closeIssue(row.issue_url, action === "approve"
      ? "Approved: this example is now on the [Examples page](https://pachterlab.github.io/Manimble/examples/). Thank you!"
      : "Thank you for the submission. It wasn't added to the Examples page, and the uploaded file was deleted.",
    action === "approve" ? "completed" : "not_planned", env);
  } catch (e) {
    console.error("could not close the review issue", e);
  }
  return json({ id, status });
}
