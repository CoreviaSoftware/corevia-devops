# CoreVia — Improvement Plan & Progress

Date started: 2026-04-29
Build verified compiling at every checkpoint marked DONE.

## Phase 1 — Lombok rollout

### 1a. Build setup — DONE
- [x] Added Lombok to `smartcity-be/build.gradle.kts` (`compileOnly` + `annotationProcessor`, plus test variants).
- [x] Verified baseline compile passes.

### 1b. Entities & value classes converted to Lombok — DONE (15 of 15 needed; 9 of 24 remained as-is were already minimal/no-op)
Files converted with `@Getter` / `@Setter` (handling custom logic via `@Setter(AccessLevel.NONE)` or hand-written method that Lombok skips):

- [x] `common/entity/BaseEntity.java` — `@Getter` class, `@Setter` only on `id` (timestamps stay read-only)
- [x] `locality/Locality.java`
- [x] `user/User.java` — preserved `getLocalityId()` and `getLocalityAccessSet()` helpers
- [x] `camera/Camera.java`
- [x] `device/Device.java` — also cleaned up fully-qualified `java.util.List`/`java.util.Map` imports
- [x] `incident/Incident.java` — kept custom `setStatus()` with side-effect; `resolvedAt` has `@Setter(AccessLevel.NONE)`
- [x] `devicetype/DeviceType.java`
- [x] `sensor/SensorReading.java`
- [x] `alert/Alert.java`
- [x] `cms/CmsContent.java`
- [x] `audit/AuditLog.java` — id and createdAt remain read-only
- [x] `audit/SmartCityRevision.java`
- [x] `device/operatoraction/OperatorAction.java`
- [x] `incident/IncidentTimelineEntry.java` — id and createdAt remain read-only
- [x] `ticketing/TicketingSettings.java` — preserved custom `setEmailConfig` that updates timestamp
- [x] `ticketing/TicketingRoleNotification.java`
- [x] `ticketing/EmailNotificationHistoryEntry.java` — id and sentAt remain read-only
- [x] `station/StationContent.java`
- [x] `station/StationDisplayIntegration.java`
- [x] `iot/DeviceIngestEvent.java`
- [x] `auth/password/exception/WeakPasswordException.java` — `@Getter` on `code`
- [x] `auth/mfa/exception/ResendCooldownException.java` — `@Getter` on `retryAfterSeconds`
- [x] `auth/mfa/exception/InvalidCodeException.java` — `@Getter` on `attemptsRemaining`
- [x] `common/tenant/TenantContext.java` — left as-is (static utility, no fields to expose)

**Compile: passed after this phase.**

### 1c. Services / controllers / components → `@RequiredArgsConstructor` + `@Slf4j` — DONE
Replace hand-written constructors with `@RequiredArgsConstructor` and `LoggerFactory.getLogger(...)` declarations with `@Slf4j` across every Spring stereotype.

**Files identified (~79 with `private final` constructor injection; ~25 with `LoggerFactory.getLogger`):**

Auth / security:
- [ ] `auth/AuthService.java`
- [ ] `auth/AuthController.java`
- [ ] `auth/JwtService.java` — keep custom validation in constructor body but switch logger
- [ ] `auth/JwtAuthFilter.java`
- [ ] `auth/UserStatusCache.java`
- [ ] `auth/SecurityConfig.java`
- [ ] `auth/password/*` (PasswordResetService, PasswordResetTokenStore, PasswordResetAuditRecorder, SmtpPasswordResetMailSender, DevPasswordResetMailSender, PasswordResetExceptionHandler)
- [ ] `auth/mfa/*` (EmailMfaService, MfaChallengeStore, MfaAuditRecorder, SmtpMailSender, DevMailSender, MfaExceptionHandler)
- [ ] `common/web/LoginRateLimitFilter.java`
- [ ] `common/web/RequestIdFilter.java`

Domain services & controllers:
- [ ] `locality/LocalityService.java`, `locality/LocalityController.java`
- [ ] `user/UserService.java`, `user/UserController.java`, `user/UserMapper.java`, `user/DevUserSeeder.java`
- [ ] `device/DeviceService.java`, `device/DeviceController.java`, `device/DeviceMapper.java`
- [ ] `device/connection/DeviceConnectionCodec.java`
- [ ] `device/operatoraction/OperatorActionService.java`
- [ ] `device/stream/MediaMtxSigner.java`, `device/stream/MediaMtxAuthController.java`
- [ ] `devicetype/DeviceTypeService.java`, `devicetype/DeviceTypeController.java`
- [ ] `camera/CameraService.java`, `camera/CameraController.java`, `camera/StationCameraController.java`, `camera/CameraMapper.java`, `camera/CameraOnlineProbe.java`, `camera/MediaMtxPathService.java`
- [ ] `sensor/SensorService.java`, `sensor/SensorController.java`
- [ ] `incident/IncidentService.java`, `incident/IncidentController.java`
- [ ] `alert/AlertService.java`, `alert/AlertController.java`
- [ ] `report/ReportService.java`, `report/ReportController.java`
- [ ] `ticketing/TicketingSettingsController.java`, `ticketing/TicketingSettingsService.java`, `ticketing/NotificationDispatcher.java`, `ticketing/IotMailSender.java`
- [ ] `cms/CmsService.java`, `cms/CmsController.java`
- [ ] `audit/AuditRetentionJob.java`, `audit/AuditService.java` (and any others)
- [ ] `sse/SseEmitterService.java`
- [ ] `common/crypto/CryptoService.java`
- [ ] `common/exception/GlobalExceptionHandler.java`

IoT subsystem:
- [ ] `iot/IngestionPipeline.java`
- [ ] `iot/OfflineDetector.java`
- [ ] `iot/DeviceIngestEventService.java`
- [ ] `iot/JsonProfileMapper.java`, `iot/JsonSchemaValidator.java`, `iot/FieldMapper.java`
- [ ] `iot/test/ConnectionTester.java`
- [ ] `iot/health/RequestMetrics.java`, `iot/health/RequestMetricsFilter.java`, `iot/health/DrainingFilter.java`, `iot/health/IotHealthController.java`
- [ ] `iot/backup/IotBackupService.java`
- [ ] `iot/runtime/DeviceRuntimeManager.java`
- [ ] `iot/runtime/MqttDeviceRuntime.java`
- [ ] `iot/runtime/RestDeviceRuntime.java`
- [ ] `iot/runtime/SnmpDeviceRuntime.java`
- [ ] `iot/runtime/FolderDeviceRuntime.java`
- [ ] `iot/runtime/TeltonikaJsonRpcDeviceRuntime.java`
- [ ] `iot/webhook/WebhookController.java`
- [ ] `iot/analytics/IotAnalyticsService.java`

**Plus run `./gradlew compileJava` after each batch to catch issues early.**

---

## Phase 2 — Clean code refactors — PARTIAL
- [x] Split `device/DeviceService.java`:
  - Extracted `DeviceUpdateApplier` (the 20+ `if (req.x() != null) device.setX(req.x())` block).
  - Extracted `DeviceConnectionUpdater` for `preserveSecretsIfBlank` + `ensureWebhookToken`.
  - Extracted `DeviceRuntimeCoordinator` for `scheduleRuntimeRefresh` / `scheduleRuntimeDetach`.
- [ ] Split `iot/analytics/IotAnalyticsService.java` — DEFERRED (needs deeper review).
- [x] Magic numbers → `DEFAULT_OFFLINE_AFTER_SECONDS=300`, `STATUS_DEBOUNCE_SECONDS=15`, `STATUS_CACHE_MAX_SIZE=10_000`, `STATUS_CACHE_EXPIRY_HOURS=1` in `DeviceService`.
- [x] `GlobalExceptionHandler.respond(status, title, message)` helper collapsing all branches.
- [ ] Frontend pass — DEFERRED (out of scope this session).

---

## Phase 3 — Safety / security — DONE
- [x] **JWT** (`auth/JwtService.java`): added `iss=smartcity-be` / `aud=smartcity-fe` on build, `requireIssuer` / `requireAudience` + `clockSkewSeconds(30)` on parse via shared `parser()`. `DEV_DEFAULT_SECRET` now fail-fast outside the `dev` profile (only allowed under dev).
- [x] **CORS** (`auth/SecurityConfig.java`): explicit `Authorization, Content-Type, X-Request-Id, If-None-Match`.
- [x] **MediaMTX**: new `MediaMtxSecretFilter` (HIGHEST_PRECEDENCE+5) requires `X-Internal-Secret` header (or `?secret=` fallback) on `/internal/mediamtx/**`. Constant-time compare.
- [x] **Ingest** (`/api/ingest/**`): `WebhookController` already enforces per-device `Authorization: Bearer <authToken>` against the device's stored token — verified, no filter needed.
- [x] **Rate limiting**: added `/api/auth/mfa/resend` to `LoginRateLimitFilter`'s rate-limited paths (login/mfa-verify/password-forgot already covered).
- [x] **CryptoService**: already sourced from `${app.secret-key}` env var with mandatory non-blank + 32-byte length check at `@PostConstruct` — verified, no change needed.

---

## Phase 4 — Performance — PARTIAL
- [x] **`@EntityGraph`** on `findByLocalityId`, `findByLocalityIdAndDeviceType_Category`, `findById`, `findByAdapterId` — already in place; verified.
- [x] **`DeviceService.markTelemetry`**: new `DeviceRepository.updateLastSeenAt` `@Modifying` JPQL; hot path takes it when `canonical` is null AND debounce window not yet elapsed (no entity load). Status flips and canonical writes still load+save.
- [x] **Cache eviction**: `update()` switched to keyed eviction (`#result.adapterId`); `delete()` keeps `allEntries = true` (rare op, can't read result on void return).
- [x] `@Cacheable` on `DeviceTypeService.findById` — already in place; verified.
- [ ] **DTO projections** for paginated device lists — DEFERRED (large refactor).
- [ ] TimescaleDB hypertable / Hikari / FE staleTime — DEFERRED (config review out of scope).

---

## Phase 5 — Docker / ops — DONE
- [x] Backend `healthcheck` on `/actuator/health` (start_period 60s; wget added to runtime image; frontend now `condition: service_healthy`).
- [x] Pinned Mosquitto `2.0`, Redis `7.4-alpine`. MediaMTX already pinned to `1.9.3`.
- [x] Dev secret defaults removed from `docker-compose.yml` — now `${VAR:?...}` (compose fails fast if unset). Defaults moved to `.env.example`.

---

## Final verification — DONE
- [x] `./gradlew clean compileJava` — passes.
- [x] `./gradlew bootJar` — passes.
- [x] Per project convention (`smartcity-be/CLAUDE.md`): no tests added/expanded; mappers stayed hand-written `@Component`.

---

## Notes / decisions taken
- **Lombok choice**: `@Getter`/`@Setter` only — no `@Data`, no `@ToString`, no `@EqualsAndHashCode`. Keeping JPA-safe (avoids breaking lazy proxies and bidirectional toString cycles).
- **`@Setter(AccessLevel.NONE)`** used to preserve encapsulation around fields that are only mutated via lifecycle callbacks or other setters (`Incident.resolvedAt`, `BaseEntity.createdAt/updatedAt`, `*.id` of standalone entities, `*.createdAt/sentAt` on entities with custom lifecycle).
- **Hand-written setters preserved**: `Incident.setStatus` (sets `resolvedAt` side-effect); `TicketingSettings.setEmailConfig` (touches `updatedAt`). Lombok skips method generation when a method with the same signature already exists.
- **Mappers (`@Component`)**: stay hand-written per `smartcity-be/CLAUDE.md` — no MapStruct.
- **Tests**: untouched per `smartcity-be/CLAUDE.md`.
