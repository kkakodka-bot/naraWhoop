import assert from "node:assert/strict";

export const DEFAULT_CAPACITY_COHORTS = [10, 100, 750, 1000] as const;
export const CAPACITY_LIVE_P95_SLO_SECONDS = 60;

export function parseCapacityCohorts(configured?: string): number[] {
  if (!configured) return [...DEFAULT_CAPACITY_COHORTS];
  const values = configured.split(",").map((value) => {
    assert.match(value, /^[1-9][0-9]*$/);
    const cohort = Number(value);
    assert.ok(Number.isSafeInteger(cohort) && cohort <= 1000);
    return cohort;
  });
  assert.equal(new Set(values).size, values.length);
  return values;
}

type EnvReader = (name: string) => string | undefined;

export function capacitySourceIdentity(
  get: EnvReader = (name) => Deno.env.get(name),
) {
  const commitSha = get("PIPELINE_TEST_SOURCE_SHA");
  const treeSha = get("PIPELINE_TEST_SOURCE_TREE");
  const worktreeClean = get("PIPELINE_TEST_SOURCE_CLEAN");
  const statusSha256 = get("PIPELINE_TEST_SOURCE_STATUS_SHA256");
  const statusLineCount = Number(
    get("PIPELINE_TEST_SOURCE_STATUS_LINE_COUNT"),
  );
  assert.match(commitSha ?? "", /^[0-9a-f]{40}$/);
  assert.match(treeSha ?? "", /^[0-9a-f]{40}$/);
  assert.ok(worktreeClean === "true" || worktreeClean === "false");
  assert.match(statusSha256 ?? "", /^[0-9a-f]{64}$/);
  assert.ok(Number.isSafeInteger(statusLineCount) && statusLineCount >= 0);
  return {
    commitSha,
    treeSha,
    worktreeClean: worktreeClean === "true",
    statusSha256,
    statusLineCount,
  };
}

export function quantiles(values: number[]) {
  assert.ok(values.length > 0);
  const sorted = [...values].sort((a, b) => a - b);
  const p = (q: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1)];
  return { count: sorted.length, p50: p(.5), p95: p(.95), p99: p(.99) };
}

function finiteNumber(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function parsePercent(value: unknown): number | null {
  if (typeof value !== "string") return finiteNumber(value);
  return finiteNumber(value.trim().replace(/%$/, ""));
}

export function parseDockerBytes(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const used = value.split("/")[0].trim();
  const match = used.match(/^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)$/i);
  if (!match) return null;
  const amount = Number(match[1]);
  const unit = match[2].toUpperCase();
  const scale: Record<string, number> = {
    B: 1,
    KB: 1_000,
    KIB: 1024,
    MB: 1_000_000,
    MIB: 1024 ** 2,
    GB: 1_000_000_000,
    GIB: 1024 ** 3,
    TB: 1_000_000_000_000,
    TIB: 1024 ** 4,
  };
  return scale[unit] ? amount * scale[unit] : null;
}

function peakMeasurement(
  values: Array<number | null>,
  unit: string,
  reason: string,
) {
  const measured = values.filter((value): value is number => value !== null);
  return measured.length > 0
    ? {
      status: "MEASURED",
      sampleCount: measured.length,
      peak: Math.max(...measured),
      unit,
    }
    : { status: "NOT_MEASURED", sampleCount: 0, peak: null, unit, reason };
}

export function summarizeResourceSamples(
  samples: any[],
  processKey: "runner" | "workers",
) {
  return {
    sampleCount: samples.length,
    databaseCpu: peakMeasurement(
      samples.map((sample) => parsePercent(sample.database?.CPUPerc)),
      "percent_of_one_cpu",
      "no_valid_docker_cpu_sample",
    ),
    databaseMemory: peakMeasurement(
      samples.map((sample) => parseDockerBytes(sample.database?.MemUsage)),
      "bytes",
      "no_valid_docker_memory_sample",
    ),
    databaseConnections: peakMeasurement(
      samples.map((sample) => finiteNumber(sample.connections?.total)),
      "connections",
      "no_valid_database_connection_sample",
    ),
    databaseActiveConnections: peakMeasurement(
      samples.map((sample) => finiteNumber(sample.connections?.active)),
      "connections",
      "no_valid_active_connection_sample",
    ),
    processCpu: peakMeasurement(
      samples.map((sample) =>
        sample[processKey]?.status === "MEASURED"
          ? finiteNumber(sample[processKey].aggregateCpuPercent)
          : null
      ),
      "percent_of_one_cpu",
      `no_valid_${processKey}_cpu_sample`,
    ),
    processMemory: peakMeasurement(
      samples.map((sample) =>
        sample[processKey]?.status === "MEASURED"
          ? finiteNumber(sample[processKey].aggregateRssBytes)
          : null
      ),
      "bytes_rss",
      `no_valid_${processKey}_memory_sample`,
    ),
  };
}

export async function sampleProcesses(pids: number[]) {
  const requestedPids = [...new Set(pids)].filter((pid) =>
    Number.isSafeInteger(pid) && pid > 0
  );
  if (requestedPids.length === 0) {
    return {
      status: "NOT_MEASURED" as const,
      reason: "no_process_ids",
      requestedPids,
      processes: [],
    };
  }
  try {
    const result = await new Deno.Command("ps", {
      args: [
        "-o",
        "pid=,rss=,pcpu=",
        "-p",
        requestedPids.join(","),
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (result.code !== 0) {
      return {
        status: "NOT_MEASURED" as const,
        reason: "ps_failed_or_processes_exited",
        requestedPids,
        processes: [],
      };
    }
    const processes = new TextDecoder().decode(result.stdout).trim()
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        const fields = line.split(/\s+/);
        assert.equal(fields.length, 3);
        return {
          pid: Number(fields[0]),
          rssBytes: Number(fields[1]) * 1024,
          cpuPercent: Number(fields[2]),
        };
      })
      .filter((row) =>
        Number.isSafeInteger(row.pid) && Number.isFinite(row.rssBytes) &&
        Number.isFinite(row.cpuPercent)
      );
    if (processes.length === 0) {
      return {
        status: "NOT_MEASURED" as const,
        reason: "no_live_process_sample",
        requestedPids,
        processes,
      };
    }
    return {
      status: "MEASURED" as const,
      requestedPids,
      observedPids: processes.map((row) => row.pid),
      processes,
      aggregateRssBytes: processes.reduce((sum, row) => sum + row.rssBytes, 0),
      aggregateCpuPercent: processes.reduce(
        (sum, row) => sum + row.cpuPercent,
        0,
      ),
    };
  } catch {
    return {
      status: "NOT_MEASURED" as const,
      reason: "ps_unavailable",
      requestedPids,
      processes: [],
    };
  }
}

type Completion = {
  userId: string;
  workClass: "live" | "backfill";
  outcome: string;
  completedAtEpoch?: number;
};

export function outcomeCounts(completions: Completion[]) {
  const counts: Record<string, number> = {};
  for (const completion of completions) {
    counts[completion.outcome] = (counts[completion.outcome] ?? 0) + 1;
  }
  return counts;
}

export function ownerFairness(
  completions: Completion[],
  expectedOwners: number,
  committedAtMs: number,
) {
  const owners = new Map<string, { live: number; backfill: number }>();
  const firstCompletion = new Map<string, number>();
  for (const row of completions) {
    if (row.outcome !== "done") continue;
    const counts = owners.get(row.userId) ?? { live: 0, backfill: 0 };
    counts[row.workClass]++;
    owners.set(row.userId, counts);
    if (Number.isFinite(row.completedAtEpoch)) {
      const seconds = Math.max(
        0,
        Number(row.completedAtEpoch) - committedAtMs / 1000,
      );
      firstCompletion.set(
        row.userId,
        Math.min(firstCompletion.get(row.userId) ?? seconds, seconds),
      );
    }
  }
  const perOwner = [...owners.values()].map((row) => row.live + row.backfill);
  const first = [...firstCompletion.values()];
  const ownersWithLiveDone = [...owners.values()].filter((row) => row.live > 0)
    .length;
  const ownersWithBackfillDone =
    [...owners.values()].filter((row) => row.backfill > 0).length;
  const ownersWithBothClassesDone =
    [...owners.values()].filter((row) => row.live > 0 && row.backfill > 0)
      .length;
  return {
    expectedOwners,
    ownersWithAnyDone: owners.size,
    ownersWithLiveDone,
    ownersWithBackfillDone,
    ownersWithBothClassesDone,
    ownersWithoutAnyDone: Math.max(0, expectedOwners - owners.size),
    allOwnersProgressed: owners.size === expectedOwners,
    bothWorkClassesProgressed: ownersWithLiveDone > 0 &&
      ownersWithBackfillDone > 0,
    completionsPerProgressingOwner: perOwner.length > 0
      ? { min: Math.min(...perOwner), max: Math.max(...perOwner) }
      : {
        min: null,
        max: null,
        status: "NOT_MEASURED",
        reason: "no_done_completion",
      },
    firstCompletionSeconds: first.length > 0
      ? { status: "MEASURED", ...quantiles(first) }
      : {
        status: "NOT_MEASURED",
        count: 0,
        p50: null,
        p95: null,
        p99: null,
        reason: "completion_timestamp_unavailable",
      },
  };
}

export function specialOwnerProgress(
  completions: Completion[],
  userId: string,
) {
  const done = completions.filter((row) =>
    row.userId === userId && row.outcome === "done"
  );
  return {
    done: done.length,
    liveDone: done.filter((row) => row.workClass === "live").length,
    backfillDone: done.filter((row) => row.workClass === "backfill").length,
    outcomes: outcomeCounts(completions.filter((row) => row.userId === userId)),
  };
}
