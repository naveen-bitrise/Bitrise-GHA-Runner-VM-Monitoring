export interface LabelInfo {
  machine_os:   string | null;
  machine_arch: string | null;
  cpu_count:    number | null;
  runner_type:  string;
}

const OS_LABELS   = ["macOS", "Linux", "Windows"];
const ARCH_LABELS = ["arm64", "x64", "ARM64", "X64"];

export function parseLabels(labels: string[]): LabelInfo {
  const machine_os   = labels.find((l) => OS_LABELS.includes(l))   ?? null;
  const machine_arch = labels.find((l) => ARCH_LABELS.includes(l)) ?? null;
  const coreLabel    = labels.find((l) => /^\d+core$/.test(l));
  const cpu_count    = coreLabel ? parseInt(coreLabel) : null;
  const runner_type  = labels.includes("self-hosted") ? "self-hosted" : "github-hosted";
  return { machine_os, machine_arch, cpu_count, runner_type };
}

export function diffSeconds(a: string, b: string): number {
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / 1000);
}

export async function verifySignature(
  body: string,
  signature: string,
  secret: string,
): Promise<boolean> {
  if (!secret) return true;
  try {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      enc.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signed = await crypto.subtle.sign("HMAC", key, enc.encode(body));
    const hex = Array.from(new Uint8Array(signed))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    return `sha256=${hex}` === signature;
  } catch {
    return false;
  }
}
