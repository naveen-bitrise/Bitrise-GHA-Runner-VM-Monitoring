import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// --- Pure helpers (also exported from lib.ts for unit tests) ---

interface LabelInfo {
  machine_os:   string | null;
  machine_arch: string | null;
  cpu_count:    number | null;
  runner_type:  string;
}

const OS_LABELS   = ["macOS", "Linux", "Windows"];
const ARCH_LABELS = ["arm64", "x64", "ARM64", "X64"];

function parseLabels(labels: string[]): LabelInfo {
  const machine_os   = labels.find((l) => OS_LABELS.includes(l))   ?? null;
  const machine_arch = labels.find((l) => ARCH_LABELS.includes(l)) ?? null;
  const coreLabel    = labels.find((l) => /^\d+core$/.test(l));
  const cpu_count    = coreLabel ? parseInt(coreLabel) : null;
  const runner_type  = labels.includes("self-hosted") ? "self-hosted" : "github-hosted";
  return { machine_os, machine_arch, cpu_count, runner_type };
}

function diffSeconds(a: string, b: string): number {
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / 1000);
}

async function verifySignature(body: string, signature: string, secret: string): Promise<boolean> {
  if (!secret) return true;
  try {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
    );
    const signed = await crypto.subtle.sign("HMAC", key, enc.encode(body));
    const hex = Array.from(new Uint8Array(signed))
      .map((b) => b.toString(16).padStart(2, "0")).join("");
    return `sha256=${hex}` === signature;
  } catch {
    return false;
  }
}

// --- Edge Function handler ---

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });

  const body      = await req.text();
  const signature = req.headers.get("X-Hub-Signature-256") ?? "";
  const secret    = Deno.env.get("GITHUB_WEBHOOK_SECRET") ?? "";

  if (!(await verifySignature(body, signature, secret))) {
    return new Response("ok", { status: 200 });
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(body);
  } catch {
    return new Response("ok", { status: 200 });
  }

  if (payload.action !== "completed") return new Response("ok", { status: 200 });

  const job = payload.workflow_job as Record<string, unknown> | undefined;
  if (!job) return new Response("ok", { status: 200 });

  const prefix = Deno.env.get("RUNNER_NAME_PREFIX") ?? "";
  if (prefix && !String(job.runner_name ?? "").startsWith(prefix)) {
    return new Response("ok", { status: 200 });
  }

  const labels = Array.isArray(job.labels) ? job.labels as string[] : [];
  const { machine_os, machine_arch, cpu_count, runner_type } = parseLabels(labels);

  const wait_time_seconds = job.created_at && job.started_at
    ? diffSeconds(String(job.created_at), String(job.started_at)) : null;
  const build_duration_seconds = job.started_at && job.completed_at
    ? diffSeconds(String(job.started_at), String(job.completed_at)) : null;

  const repo   = payload.repository as Record<string, unknown> | undefined;
  const sender = payload.sender     as Record<string, unknown> | undefined;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")              ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  await supabase.from("job_conclusions").upsert(
    {
      job_id:                job.id,
      run_id:                String(job.run_id ?? ""),
      run_attempt:           job.run_attempt      ?? null,
      job_name:              job.name             ?? null,
      workflow_name:         job.workflow_name     ?? null,
      repository:            repo?.full_name       ?? null,
      branch:                job.head_branch       ?? null,
      sha:                   job.head_sha          ?? null,
      conclusion:            job.conclusion        ?? null,
      runner_name:           job.runner_name       ?? null,
      runner_group_name:     job.runner_group_name ?? null,
      machine_os,
      machine_arch,
      cpu_count,
      runner_type,
      actor:                 sender?.login         ?? null,
      wait_time_seconds,
      build_duration_seconds,
      created_at:            job.created_at        ?? null,
      started_at:            job.started_at        ?? null,
      completed_at:          job.completed_at      ?? null,
    },
    { onConflict: "job_id" },
  );

  return new Response("ok", { status: 200 });
});
