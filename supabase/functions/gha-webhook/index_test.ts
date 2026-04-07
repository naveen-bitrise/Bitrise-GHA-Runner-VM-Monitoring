import { assertEquals } from "jsr:@std/assert";
import { parseLabels, diffSeconds, verifySignature } from "./lib.ts";

// --- parseLabels ---

Deno.test("parseLabels: self-hosted macOS arm64 14core", () => {
  const r = parseLabels(["self-hosted", "macOS", "arm64", "14core"]);
  assertEquals(r.machine_os,   "macOS");
  assertEquals(r.machine_arch, "arm64");
  assertEquals(r.cpu_count,    14);
  assertEquals(r.runner_type,  "self-hosted");
});

Deno.test("parseLabels: self-hosted Linux X64 16core", () => {
  const r = parseLabels(["self-hosted", "Linux", "X64", "16core"]);
  assertEquals(r.machine_os,   "Linux");
  assertEquals(r.machine_arch, "X64");
  assertEquals(r.cpu_count,    16);
  assertEquals(r.runner_type,  "self-hosted");
});

Deno.test("parseLabels: github-hosted ubuntu-latest (no self-hosted label)", () => {
  const r = parseLabels(["ubuntu-latest"]);
  assertEquals(r.machine_os,   null);
  assertEquals(r.machine_arch, null);
  assertEquals(r.cpu_count,    null);
  assertEquals(r.runner_type,  "github-hosted");
});

Deno.test("parseLabels: empty labels", () => {
  const r = parseLabels([]);
  assertEquals(r.machine_os,   null);
  assertEquals(r.machine_arch, null);
  assertEquals(r.cpu_count,    null);
  assertEquals(r.runner_type,  "github-hosted");
});

Deno.test("parseLabels: Windows ARM64 8core", () => {
  const r = parseLabels(["self-hosted", "Windows", "ARM64", "8core"]);
  assertEquals(r.machine_os,   "Windows");
  assertEquals(r.machine_arch, "ARM64");
  assertEquals(r.cpu_count,    8);
  assertEquals(r.runner_type,  "self-hosted");
});

// --- diffSeconds ---

Deno.test("diffSeconds: 30 second gap", () => {
  assertEquals(diffSeconds("2024-01-01T00:00:00Z", "2024-01-01T00:00:30Z"), 30);
});

Deno.test("diffSeconds: 5 minute gap", () => {
  assertEquals(diffSeconds("2024-01-01T00:00:00Z", "2024-01-01T00:05:00Z"), 300);
});

// --- verifySignature ---

Deno.test("verifySignature: valid HMAC", async () => {
  const secret = "mysecret";
  const body   = '{"action":"completed"}';
  const key    = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const hex    = Array.from(new Uint8Array(signed))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  const valid = await verifySignature(body, `sha256=${hex}`, secret);
  assertEquals(valid, true);
});

Deno.test("verifySignature: wrong signature", async () => {
  const valid = await verifySignature('{"action":"completed"}', "sha256=badhex", "mysecret");
  assertEquals(valid, false);
});

Deno.test("verifySignature: empty secret skips check", async () => {
  const valid = await verifySignature("body", "sha256=anything", "");
  assertEquals(valid, true);
});
