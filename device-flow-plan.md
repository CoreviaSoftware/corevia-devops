# Device flow improvements — execution plan

**Context for the next session:** this plan came out of an analysis of how external device telemetry (MQTT / REST / Webhook / Folder / SNMP / Teltonika JSON-RPC) flows through `IngestionPipeline` → `sensor_readings` + `devices.last_telemetry` → SSE → FE. Phase 1 is **already merged** on the local `andrei` branch (smartcity-fe) and the smartcity-be working tree. Phase 2 is the next batch of work; Phase 3 is deferred.

**Working dirs:**
- `/home/ahavasi/Desktop/CoreVia/smartcity-be` — Spring Boot 3.x, Gradle, Java
- `/home/ahavasi/Desktop/CoreVia/smartcity-fe` — Next.js 14, TypeScript, react-query, react-hook-form

---

## Project conventions (read before touching code)

From `smartcity-be/CLAUDE.md`:

1. **No tests.** Owner authors them later. Don't add new test classes/methods. If existing tests break from a production change, fix the production code or the test setup — never add new assertions to make them pass.
2. **Hand-written `@Component` mappers** only. No MapStruct, no `@Mapper`, no generated code. Reference: `ro.smartcity.user.UserMapper`.
3. Build verification: `./gradlew compileJava -q` (BE), `./node_modules/.bin/tsc --noEmit && npm run build` (FE). Both must be clean before claiming an item done.

---

## Phase 1 — DONE (do not redo)

| # | Item | Files |
|---|------|-------|
| 1A | Drop dead `categoryHint` arg from `IngestionPipeline.ingest()` | `iot/IngestionPipeline.java`, all 6 adapters under `iot/runtime/`, `iot/webhook/WebhookController.java` |
| 1B | Extract dotted-path parser to `iot/JsonPaths.java`; `FieldMapper` + `JsonProfileMapper` delegate to it | `iot/{JsonPaths,FieldMapper,JsonProfileMapper}.java` |
| 1C | SSE `AFTER_COMMIT` — was already implemented in `SseEmitterService.broadcast` (uses `TransactionSynchronization.afterCommit()`). No-op. | — |
| 1D | `FieldMapper.normalizeStatus` / `normalizeDisplayHealth` return `null` on unknown values (was silently defaulting to "healthy"/"online"); WARN log the unknown value | `iot/FieldMapper.java` |
| 1E | FE consumes SSE telemetry events. `useLocalityEvents` now invalidates device-detail / device-list / incidents queries on `sensor_reading`, `device_status_changed`, `device_stale_warning`, `new_incident` | `smartcity-fe/src/shared/hooks/use-locality-events.ts` |
| 1F | Ingest-events timeline on device-detail page (BE endpoint already existed at `GET /api/localities/{lid}/devices/{id}/ingest-events`) | new `IngestEventsCard.tsx`, mounted in `DeviceDetailView.tsx`, hook `useDeviceIngestEvents` in `features/devices/api.ts` |
| 1G | "Test mapping with sample payload" panel in `DeviceFormDialog` (edit mode only). New BE endpoint `POST /api/localities/{lid}/devices/{id}/preview-mapping` runs `JsonProfileMapper` + `FieldMapper` + `JsonSchemaValidator` against the operator's sample JSON, returns `{remapped, canonical, schemaViolations}`. | new `device/MappingPreviewService.java`, new DTOs `device/dto/PreviewMapping{Request,Response}.java`, new endpoint in `DeviceController.java`; FE: `usePreviewMapping` mutation + new `<details>` block in `DeviceFormDialog.tsx`; i18n in en/ro/hu under `devicesPage.form.preview*` and new `devicesPage.ingestEvents.*` namespace |

**Verify Phase 1 is in:** `git -C /home/ahavasi/Desktop/CoreVia/smartcity-fe log --oneline -5` should show "device mapping rules" and "fix search filters" near the top. The BE work is uncommitted in the working tree (or committed depending on what the user has done since).

---

## Phase 2 — NEXT (start here)

Higher-risk, hot-path changes. Ship one PR at a time, each with its own deploy + monitoring window. **Every Phase 2 item gets a config flag so it can be reverted without redeploy.**

### 2A. Canonical-equality dedupe

**Problem:** A device emitting the same canonical value (for example `isFull=false`) once per second still triggers full validation + `sensor_readings` insert + alert sweep + SSE broadcast every second.

**Files:** `smartcity-be/src/main/java/ro/smartcity/iot/IngestionPipeline.java`, `application.yml`.

**Approach:**
- Before `sensorService.save(tagged)` (currently around line 114), compute `prevCanonical = device.getLastTelemetry()` stripped of `kind` + `timestamp`; compute `newCanonical = canonical` stripped of same. If `Objects.equals(prevCanonical, newCanonical)`, skip `sensorService.save`, skip the `sseEmitterService.broadcast("sensor_reading", ...)`, but **still** call `deviceService.markSeen(deviceId)` to bump `last_seen_at` (so the OfflineDetector doesn't flip the device).
- Log a new `DeviceIngestEvent` status `ACCEPTED_DUPLICATE` (add the constant to `DeviceIngestEventService`) so operators can see suppressions in the timeline (Phase 1G UI).
- Threshold/incident eval still runs (in case rules depend on a debounce-style condition). Or skip it — write a comment either way.
- Config flag: `app.ingest.dedupe-enabled` (default `true`) wrapped via `@Value`.

**Risks:** Float comparison fragility — but `FieldMapper.coerce` already normalizes numbers to `Double`, so `Objects.equals` over the canonical maps is safe. Add a unit comment explaining this.

**Exit:** new ingest-events row of type `ACCEPTED_DUPLICATE` shows up when you replay the same payload twice; `sensor_readings` row count stops growing for the duplicates.

---

### 2B. Async ingestion queue

**Problem:** Adapter threads (Paho callbacks, scheduled REST/SNMP pollers, folder watchers) execute the entire pipeline synchronously. Slow DB or stuck SSE emitter pins the adapter thread.

**Files:** new `iot/IngestQueue.java`, new `iot/IngestWorker.java`. Modify all 5 polling adapters (`MqttDeviceRuntime`, `RestDeviceRuntime`, `FolderDeviceRuntime`, `SnmpDeviceRuntime`, `TeltonikaJsonRpcDeviceRuntime`) to enqueue. **Leave `WebhookController` synchronous** — HTTP callers expect a real 200/400.

**Approach:**
- Per-device `ArrayBlockingQueue<IngestFrame>` (capacity ~64), drop-oldest-on-overflow with a `DeviceIngestEvent` of new status `OVERFLOW_DROPPED`.
- Worker pool of size `app.ingest.workers` (default `Runtime.availableProcessors() * 2`) drains all queues fairly.
- **Per-device single-flight** (one frame at a time per device) so `openCount`-style stateful enrichment stays ordered. A `ConcurrentHashMap<UUID, ReentrantLock>` keyed by device works.
- Existing `ingestTaskScheduler` keeps polling; a new `ingestWorkerExecutor` bean handles pipeline work.
- Config flag: `app.ingest.async-enabled` (default `true`). When `false`, adapters call `pipeline.ingest()` directly as today.

**Risks:** This is the architectural change with the most surface. Soak-test with a script pushing 1000 frames/s across 50 simulated devices before merging. Verify `openCount` and threshold incidents still fire correctly.

**Exit:** under load, adapter threads stay responsive (e.g. MQTT subscriber doesn't fall behind broker), p99 ingest latency improves, no openCount regressions.

---

### 2C. Batched `sensor_readings` writes

**Problem:** One INSERT per frame into `sensor_readings`. No partitioning, no compression. Hits Postgres write throughput ceiling at smartcity-scale.

**Blocker:** Ship after 2B. Without async ingestion, a flush slowdown still pins adapter threads.

**Files:** new `sensor/SensorReadingBuffer.java`, modify `sensor/SensorService.java`, `application.yml`.

**Approach:**
- `SensorService.save` enqueues to an in-memory buffer keyed by deviceId.
- A scheduled drainer flushes every `app.ingest.batch-flush-ms` (default 250) or when buffer reaches `app.ingest.batch-max-rows` (default 500), whichever first.
- Use `JdbcTemplate.batchUpdate` for the flush (raw SQL, not Hibernate, for throughput).
- `devices.last_telemetry` updates via `deviceService.markTelemetry` stay **synchronous** — the FE reads them on every page load.
- Document the failure mode: a crash between buffer and flush loses up to 250 ms of readings. Either accept and document, or persist to a small append-only WAL table first (probably overkill).

**Exit:** insert throughput on `sensor_readings` rises substantially; under load the table accumulates rows in batches visible in `pg_stat_statements`.

---

### 2D. Trim SSE telemetry payload

**Problem:** Every `sensor_reading` event ships the full canonical map (could be ~20 fields for a Wi-Fi AP) × N subscribers per locality.

**Blocker:** depends on 1E being live (FE listeners that invalidate caches on receipt). It is.

**Files:** `iot/IngestionPipeline.java` (build a thin payload), `smartcity-fe/src/shared/hooks/use-locality-events.ts` (already invalidates on receipt; payload shape change is transparent).

**Approach:**
- Replace `Map.of("deviceId", device.getId(), "metrics", tagged)` with `Map.of("deviceId", device.getId(), "ts", tagged.get("timestamp"), "changedRoles", roleKeysList)`.
- "Changed roles" can be computed cheaply as the diff between `prevCanonical` and `newCanonical` (already computed for 2A dedupe — synergy).
- FE listener already invalidates the detail query, so the missing payload data is recovered via cache miss → fresh fetch. No FE behavioural change.

**Exit:** SSE traffic per frame drops by ~10×; FE behaviour unchanged.

---

### 2E. Tighten device cache eviction (only if 1F shows staleness)

**Problem:** `DeviceService.findByAdapterId` is `@Cacheable`. The cached `Device` carries `field_mapping`, `json_profile`, `device_type` — if a UI edit doesn't evict, the next ingest uses stale config.

**Files:** `device/DeviceService.java`.

**Approach:**
1. Audit every mutation in `DeviceService` (`update`, `markEmptied`, `setEnabled`, mapping/profile updates) for `@CacheEvict(key = "#adapterId")` on the `findByAdapterId` cache.
2. If complete, **skip this item** (Phase 1F's ingest-events timeline will surface stale-config bugs as MAPPING_ERROR rows; if none appear in operator usage, this is theoretical).
3. If incomplete, either add evictions or restructure the cache to `(adapterId → deviceId)` only, then `findById` for the entity.

**Exit:** edits to mapping/profile in the UI take effect on the very next frame.

---

### Phase 2 exit criteria

Soak test with `k6` (or similar) pushing 1000 frames/s across 50 simulated devices. Compare before/after on:
- p99 `IngestionPipeline.ingest()` latency
- `sensor_readings` insert throughput (rows/s)
- BE thread count + adapter responsiveness (no MQTT subscriber backlog)
- SSE bytes/s per locality

---

## Phase 3 — DEFERRED

Don't start until Phase 2 metrics show single-node BE saturating. Listed for completeness only.

- **3A. Externalize ingestion to its own service** publishing to Kafka/Redis Streams. Solves the multi-replica problem (REST/SNMP pollers would otherwise dual-poll). Significant ops cost.
- **3B. `sensor_readings` → TimescaleDB hypertable** with monthly chunks + retention policy + continuous aggregates for the existing `/readings?metric=...` API. Gates retention beyond ~weeks at high cadence. Requires a Flyway migration.

---

## Suggested PR order for Phase 2

| PR | Items | Notes |
|----|-------|-------|
| 1 | 2A dedupe | Cheapest, large win for chatty devices. ~120 LOC + flag. |
| 2 | 2B async queue | Architectural. ~500 LOC + flag. Soak test before merge. |
| 3 | 2C batched writes | Depends on PR 2. ~200 LOC + flag. |
| 4 | 2D SSE payload trim | Depends on PR 1 (`changedRoles` reuses dedupe diff). ~80 LOC. |
| 5 | 2E cache audit (only if needed) | Skip if 1F shows no staleness. |

---

## Useful pointers from the analysis

- `IngestionPipeline.ingest()` is the funnel — read it first.
- `FieldMapper.apply()` resolution order (highest precedence first): `device[protocol]` > `device[default]` > `type[protocol]` > `type[default]`. The `default` bucket is the cross-protocol fallback.
- Reserved bucket key `"default"` lives in `iot/Protocols.java`.
- `OfflineDetector` runs every 30s (`@Scheduled`), flips devices to OFFLINE/stale based on `lastSeenAt` vs per-device `offlineAfterSeconds`. Its broadcasts also benefit from 2D payload trim if you want.
- SSE event types currently broadcast: `sensor_reading`, `new_incident`, `device_status_changed`, `device_stale_warning`, `alert_raised`, `alert_cleared`, `alert_ack`, `notification_created`. The `alert_*` family is **not yet consumed by the FE** — separate small ticket if you want to wire it (similar pattern to the Phase 1E work in `use-locality-events.ts`).
- Build verification (run after each PR):
  - BE: `cd /home/ahavasi/Desktop/CoreVia/smartcity-be && ./gradlew compileJava -q`
  - FE: `cd /home/ahavasi/Desktop/CoreVia/smartcity-fe && ./node_modules/.bin/tsc --noEmit && npm run build`

---

## How to start the next session

Open a new chat in `/home/ahavasi/Desktop/CoreVia` and say: *"Read device-flow-plan.md and start Phase 2 PR 1 (canonical-equality dedupe)."* The plan is self-contained; follow the file paths and conventions above.
