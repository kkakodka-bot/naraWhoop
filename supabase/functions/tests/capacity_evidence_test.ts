import assert from "node:assert/strict";
import {
  capacitySourceIdentity,
  ownerFairness,
  parseCapacityCohorts,
  parseDockerBytes,
  sampleProcesses,
  summarizeResourceSamples,
} from "./capacity_evidence.ts";

Deno.test("capacity cohort selector has a stable release default", () => {
  assert.deepEqual(parseCapacityCohorts(), [10, 100, 750, 1000]);
  assert.deepEqual(parseCapacityCohorts("10,100,750,1000"), [
    10,
    100,
    750,
    1000,
  ]);
  assert.deepEqual(parseCapacityCohorts("750"), [750]);
  assert.throws(() => parseCapacityCohorts("10,10"));
  assert.throws(() => parseCapacityCohorts("1001"));
  assert.throws(() => parseCapacityCohorts("10, 100"));
});

Deno.test("source identity includes commit tree and complete status identity", () => {
  const values: Record<string, string> = {
    PIPELINE_TEST_SOURCE_SHA: "a".repeat(40),
    PIPELINE_TEST_SOURCE_TREE: "b".repeat(40),
    PIPELINE_TEST_SOURCE_CLEAN: "false",
    PIPELINE_TEST_SOURCE_STATUS_SHA256: "c".repeat(64),
    PIPELINE_TEST_SOURCE_STATUS_LINE_COUNT: "3",
  };
  assert.deepEqual(capacitySourceIdentity((name) => values[name]), {
    commitSha: "a".repeat(40),
    treeSha: "b".repeat(40),
    worktreeClean: false,
    statusSha256: "c".repeat(64),
    statusLineCount: 3,
  });
});

Deno.test("resource summary reports measured peaks and explicit missing lanes", () => {
  const report = summarizeResourceSamples([{
    database: { CPUPerc: "102.5%", MemUsage: "1.5GiB / 2GiB" },
    connections: { total: 15, active: 5 },
    workers: {
      status: "MEASURED",
      aggregateCpuPercent: 240,
      aggregateRssBytes: 800_000_000,
    },
  }], "workers");
  assert.equal(report.databaseCpu.peak, 102.5);
  assert.equal(report.databaseMemory.peak, 1.5 * 1024 ** 3);
  assert.equal(report.databaseConnections.peak, 15);
  assert.equal(report.processMemory.peak, 800_000_000);
  const missing = summarizeResourceSamples([], "runner");
  assert.equal(missing.databaseCpu.status, "NOT_MEASURED");
  assert.equal(missing.processMemory.status, "NOT_MEASURED");
  assert.equal(parseDockerBytes("148.3MiB / 2GiB"), 148.3 * 1024 ** 2);
});

Deno.test("owner fairness records both classes and first progress tails", () => {
  const base = Date.now();
  const report = ownerFairness(
    [
      {
        userId: "a",
        workClass: "live",
        outcome: "done",
        completedAtEpoch: base / 1000 + 1,
      },
      {
        userId: "a",
        workClass: "backfill",
        outcome: "done",
        completedAtEpoch: base / 1000 + 3,
      },
      {
        userId: "b",
        workClass: "live",
        outcome: "failed",
        completedAtEpoch: base / 1000 + 1,
      },
      {
        userId: "b",
        workClass: "live",
        outcome: "done",
        completedAtEpoch: base / 1000 + 2,
      },
      {
        userId: "b",
        workClass: "backfill",
        outcome: "done",
        completedAtEpoch: base / 1000 + 4,
      },
    ],
    2,
    base,
  );
  assert.equal(report.allOwnersProgressed, true);
  assert.equal(report.ownersWithBothClassesDone, 2);
  assert.deepEqual(report.completionsPerProgressingOwner, { min: 2, max: 2 });
  assert.equal(report.firstCompletionSeconds.status, "MEASURED");
  assert.equal(report.firstCompletionSeconds.p95, 2);
});

Deno.test("process sampler measures this real test process or declares why it cannot", async () => {
  const sample = await sampleProcesses([Deno.pid]);
  assert.ok(sample.status === "MEASURED" || sample.status === "NOT_MEASURED");
  if (sample.status === "MEASURED") {
    assert.ok(sample.aggregateRssBytes > 0);
    assert.deepEqual(sample.observedPids, [Deno.pid]);
  } else {
    assert.ok(sample.reason);
  }
});

Deno.test("launch capacity declaration stays local-only and matches fleet limits", async () => {
  const declaration = JSON.parse(
    await Deno.readTextFile(
      new URL(
        "../../../infra/vps/launch-capacity.json",
        import.meta.url,
      ),
    ),
  );
  assert.deepEqual(Object.keys(declaration).sort(), [
    "conditionalCanaryAdmission",
    "databaseConnections",
    "decision",
    "evidenceScope",
    "fleetCapacityReadiness",
    "publicationSlo",
    "schemaVersion",
    "targetVpsCapacity",
    "unsupportedClaims",
  ]);
  assert.equal(declaration.decision, "CONDITIONAL_CANARY_ONLY");
  assert.equal(declaration.evidenceScope, "LOCAL_SCALAR_FIXTURE");
  assert.equal(declaration.targetVpsCapacity, "NOT_MEASURED");
  assert.equal(declaration.fleetCapacityReadiness, "FAIL");
  assert.deepEqual(declaration.conditionalCanaryAdmission, {
    activeOwners: 10,
    devices: 20,
    physiologyWorkerProcesses: 4,
  });
  assert.equal(declaration.publicationSlo.percentile, 95);
  assert.equal(declaration.publicationSlo.seconds, 60);
  assert.equal(declaration.databaseConnections.budget, 40);
  assert.equal(declaration.databaseConnections.reserve, 16);
  assert.ok(
    declaration.unsupportedClaims.some((claim: any) =>
      claim.activeOwners === 1000 && claim.status === "UNSUPPORTED"
    ),
  );

  const compose = await Deno.readTextFile(
    new URL(
      "../../../infra/vps/templates/docker-compose.fleet.yml",
      import.meta.url,
    ),
  );
  assert.match(compose, /SCORING_FLEET_REPLICAS:-4/);
  assert.match(compose, /SCORING_DB_CONNECTION_BUDGET:-40/);
  assert.match(compose, /SCORING_DB_CONNECTION_RESERVE:-16/);

  const handoff = await Deno.readTextFile(
    new URL("../../../HANDOFF_multiuser.md", import.meta.url),
  );
  assert.match(handoff, /1,000 owners[\s\S]*\*\*FAIL; excluded\*\*/);
  assert.match(
    handoff,
    /Do not size a 1,000-user deployment from this result\./,
  );
  assert.doesNotMatch(handoff, /1,000 owners[^\n]*\bPASS\b/);

  const sensorCapacity = await Deno.readTextFile(
    new URL("../../../docs/sensor-algorithms/capacity.md", import.meta.url),
  );
  assert.match(
    sensorCapacity,
    /capacity-supported user count remain `NOT_MEASURED`/,
  );
});

Deno.test("pipeline source receipt covers commit tree staged and untracked state", async () => {
  const pipeline = await Deno.readTextFile(
    new URL(
      "../../../scoring-service/scripts/test-server-pipeline.sh",
      import.meta.url,
    ),
  );
  assert.match(
    pipeline,
    /git --no-replace-objects[^\n]+rev-parse --verify HEAD/,
  );
  assert.match(pipeline, /rev-parse --verify 'HEAD\^\{tree\}'/);
  assert.match(pipeline, /status --porcelain=v1 --untracked-files=all/);
  assert.match(pipeline, /diff --binary HEAD/);
  assert.match(pipeline, /ls-files --others --exclude-standard/);
});
