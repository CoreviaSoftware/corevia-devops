# Signworld Assisted Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish scrolling text and media programs from SmartCity Totems to the verified Signworld machine `8238`, with human-completed CAPTCHA and e-mail verification inside SmartCity.

**Architecture:** `smartcity-be` owns a fixture-backed Signworld gateway, encrypted vendor sessions, and a persistent publication state machine. `smartcity-fe` renders the assisted CAPTCHA/code workflow inside the existing Totem editor. `corevia-devops` passes backend-only vendor configuration; MQTT, WireGuard, cameras, MediaMTX, and Caddy stay untouched.

**Tech Stack:** Java 21, Spring Boot 3.4 MVC/JPA/RestClient, PostgreSQL/Flyway, AES-GCM `CryptoService`, Caffeine, JUnit/AssertJ/MockWebServer, Next.js 14, React 18, TanStack Query, next-intl, Vitest/MSW.

**Source specification:** `corevia-devops/docs/superpowers/specs/2026-08-17-signworld-assisted-publishing-design.md`

**Repository rule override:** `smartcity-be/CLAUDE.md` normally asks collaborators not to add tests. The user's explicit requirement for Signworld mock tests overrides that repository convention for this feature only.

---

## File map

### `smartcity-be`

Create:

- `src/main/resources/db/migration/V28__signworld_assisted_publishing.sql` — additive schema and targeted Salaj correction.
- `src/main/java/ro/smartcity/display/signworld/SignworldProperties.java` — backend-only config and timeouts.
- `src/main/java/ro/smartcity/display/signworld/SignworldState.java` — public seven-state enum.
- `src/main/java/ro/smartcity/display/signworld/SignworldSession.java` — encrypted session entity.
- `src/main/java/ro/smartcity/display/signworld/SignworldSessionRepository.java`.
- `src/main/java/ro/smartcity/display/signworld/SignworldPublication.java` — publication attempt entity.
- `src/main/java/ro/smartcity/display/signworld/SignworldPublicationRepository.java`.
- `src/main/java/ro/smartcity/display/signworld/SignworldChallenge.java` and `SignworldChallengeStore.java` — bounded five-minute CAPTCHA challenge cache.
- `src/main/java/ro/smartcity/display/signworld/SignworldOriginPolicy.java` — HTTPS/origin/redirect validation.
- `src/main/java/ro/smartcity/display/signworld/SignworldSessionCodec.java` — JSON + AES-GCM session serialization.
- `src/main/java/ro/smartcity/display/signworld/SignworldGateway.java` — vendor boundary.
- `src/main/java/ro/smartcity/display/signworld/HttpSignworldGateway.java` — real fixture-backed HTTP adapter.
- `src/main/java/ro/smartcity/display/signworld/SignworldAuthService.java` — CAPTCHA/login/session orchestration.
- `src/main/java/ro/smartcity/display/signworld/SignworldPublicationService.java` — create/confirm/status/retry orchestration.
- `src/main/java/ro/smartcity/display/signworld/SignworldPublicationPoller.java` — bounded polling and restart recovery.
- `src/main/java/ro/smartcity/display/signworld/SignworldController.java` — SmartCity API.
- `src/main/java/ro/smartcity/display/signworld/SignworldException.java` — sanitized typed errors.
- `src/main/java/ro/smartcity/display/signworld/dto/*.java` — request/response records.
- `src/test/resources/signworld/contracts/*.json` — sanitized vendor fixtures captured before adapter activation.
- `src/test/java/ro/smartcity/display/signworld/*Test.java` — migration, origin, crypto/session, gateway, service, controller, polling tests.

Modify:

- `src/main/java/ro/smartcity/SmartCityApplication.java` — enable `SignworldProperties`.
- `src/main/java/ro/smartcity/display/DisplayIntegration.java` — add `machineId`.
- `src/main/java/ro/smartcity/display/DisplayIntegrationService.java` — remove simulated remote sync.
- `src/main/java/ro/smartcity/display/DisplayMapper.java`.
- `src/main/java/ro/smartcity/display/dto/DisplayIntegrationResponse.java`.
- `src/main/java/ro/smartcity/display/dto/UpdateDisplayIntegrationRequest.java`.
- `src/main/java/ro/smartcity/display/DisplayContentService.java` — manual fallback remains; real remote publish moves to Signworld service.
- `src/main/java/ro/smartcity/common/exception/GlobalExceptionHandler.java` — sanitized Signworld responses.
- `src/main/resources/application.yml`, `application-local.yml`, `application-prod.yml`.
- `build.gradle.kts` — MockWebServer test dependency only.

### `smartcity-fe`

Create:

- `src/features/totems/components/editor/SignworldPublishingPanel.tsx`.
- `src/features/totems/components/editor/SignworldPublishingPanel.test.tsx`.
- `src/features/totems/signworld-state.ts` and `signworld-state.test.ts` — state/view-model helpers.

Modify:

- `src/shared/types/smartcity.ts` — machine and publication types.
- `src/features/totems/api.ts` — CAPTCHA/login/publication hooks; remove dry-run calls.
- `src/features/totems/index.ts`.
- `src/features/totems/components/editor/TotemEditor.tsx` — compose the panel.
- `src/features/totems/components/editor/TotemSettingsDialog.tsx` — explicit machine ID.
- `messages/ro/common.json`, `messages/hu/common.json`, `messages/en/common.json`.

### `corevia-devops`

Modify:

- `.env.windows.example` — non-secret names and safe comments.
- `docker-compose.windows.yml` — pass four Signworld variables only to backend.
- `WINDOWS_DEPLOY.md` — backup, configuration, deploy, rollback, and live acceptance.

Do not stage or alter the pre-existing unrelated `docker-compose.yml` media-volume change.

---

### Task 1: Capture and sanitize the current Signworld contract

**Files:**

- Create: `smartcity-be/src/test/resources/signworld/contracts/captcha-response.json`
- Create: `smartcity-be/src/test/resources/signworld/contracts/login-request.form`
- Create: `smartcity-be/src/test/resources/signworld/contracts/login-response.json`
- Create: `smartcity-be/src/test/resources/signworld/contracts/message-save-request.form`
- Create: `smartcity-be/src/test/resources/signworld/contracts/email-code-response.json`
- Create: `smartcity-be/src/test/resources/signworld/contracts/check-request.form`
- Create: `smartcity-be/src/test/resources/signworld/contracts/progress-response.json`
- Create when media contract is present: `smartcity-be/src/test/resources/signworld/contracts/program-*.json`

- [ ] **Step 1: Resolve the portal URL from production without printing secrets**

Run in PowerShell on the Windows server:

```powershell
$portalUrl = docker exec corevia-db psql -U smartcity -d smartcity -Atc @"
SELECT cms_url
FROM display_integration
WHERE integration_company_id = '13494'
   OR terminal_name IN ('signworld-inova', 'signworld.inova')
ORDER BY updated_at DESC
LIMIT 1;
"@
$portalUrl = $portalUrl.Trim()
if (-not [Uri]::IsWellFormedUriString($portalUrl, [UriKind]::Absolute)) {
  throw 'Signworld cms_url is missing; real adapter work must stop without the authorized portal address.'
}
$portalUrl
```

Expected: one HTTPS origin. If the query is empty, stop this task; do not guess a hostname and do not enable remote publication.

- [ ] **Step 2: Inspect the current official bundle**

Open `$portalUrl` in an authorized browser, use DevTools Sources/Search for the exact route fragments, and record the JS functions constructing:

```text
/apic/user/graph/code
/apic/user/login
/apic/user/publishing/emailcode
/apic/user/check
/apip/publishing/message
/apip/publishing/message/progress/
/apip/program
/apip/publishing/program
```

Do not run a CAPTCHA solver. The operator manually enters CAPTCHA and e-mail code.

- [ ] **Step 3: Capture one authorized manual scrolling-text publication**

Use browser Network “Copy as cURL” for the relevant requests, then create fixtures containing only:

```text
HTTP method
relative path
content type
field names
JSON/form value shapes
sanitized success/error response shapes
```

Replace username, password, cookies, tokens, CAPTCHA values, e-mail codes, names, and e-mail addresses with `fixture-*`. Preserve `machineIds=[8238]` because it is the tested target contract.

- [ ] **Step 4: Verify the sanitized fixtures contain no secrets**

Run:

```bash
rg -n -i 'authorization:|cookie:|set-cookie:|password=|token=|session=|bearer ' \
  smartcity-be/src/test/resources/signworld/contracts
```

Expected: no output.

- [ ] **Step 5: Commit only sanitized fixtures**

```bash
cd smartcity-be
git add src/test/resources/signworld/contracts
git diff --cached --check
git commit -m "test: capture sanitized Signworld contracts"
```

Expected: no credentials or full unsanitized HAR/cURL files in the commit.

---

### Task 2: Add the persistence schema and machine identity

**Files:**

- Create: `smartcity-be/src/main/resources/db/migration/V28__signworld_assisted_publishing.sql`
- Modify: `smartcity-be/src/main/java/ro/smartcity/display/DisplayIntegration.java`
- Modify: `smartcity-be/src/main/java/ro/smartcity/display/dto/DisplayIntegrationResponse.java`
- Modify: `smartcity-be/src/main/java/ro/smartcity/display/dto/UpdateDisplayIntegrationRequest.java`
- Modify: `smartcity-be/src/main/java/ro/smartcity/display/DisplayMapper.java`
- Test: `smartcity-be/src/test/java/ro/smartcity/display/signworld/SignworldMigrationTest.java`

- [ ] **Step 1: Write the failing migration test**

Create a Testcontainers/Flyway test that migrates to V27, inserts a display integration with company `13494` and terminal `signworld-inova`, migrates to latest, and asserts:

```java
assertThat(row.getString("integration_company_id")).isEqualTo("13494");
assertThat(row.getString("terminal_name")).isEqualTo("signworld.inova");
assertThat(row.getLong("machine_id")).isEqualTo(8238L);
assertThat(tableNames()).contains("signworld_session", "signworld_publication");
```

- [ ] **Step 2: Run the migration test and verify it fails**

```bash
cd smartcity-be
./gradlew test --tests ro.smartcity.display.signworld.SignworldMigrationTest
```

Expected: FAIL because V28 and the tables do not exist.

- [ ] **Step 3: Add the additive migration**

Use this schema:

```sql
ALTER TABLE display_integration
    ADD COLUMN machine_id BIGINT;

ALTER TABLE display_integration
    ADD CONSTRAINT chk_display_integration_machine_id
    CHECK (machine_id IS NULL OR machine_id > 0);

UPDATE display_integration
SET integration_company_id = '13494',
    terminal_name = 'signworld.inova',
    machine_id = 8238,
    updated_at = CURRENT_TIMESTAMP
WHERE integration_company_id = '13494'
   OR terminal_name = 'signworld-inova';

CREATE TABLE signworld_session (
    device_id UUID PRIMARY KEY REFERENCES display_integration(device_id) ON DELETE CASCADE,
    encrypted_session TEXT NOT NULL,
    authenticated_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE signworld_publication (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES display_integration(device_id) ON DELETE CASCADE,
    content_id UUID NOT NULL REFERENCES display_content(id) ON DELETE CASCADE,
    machine_id BIGINT NOT NULL CHECK (machine_id > 0),
    vendor_publication_id VARCHAR(120),
    state VARCHAR(40) NOT NULL,
    progress_percent INTEGER CHECK (progress_percent IS NULL OR progress_percent BETWEEN 0 AND 100),
    sanitized_error_code VARCHAR(120),
    sanitized_error_message TEXT,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_signworld_publication_device_created
    ON signworld_publication(device_id, created_at DESC);

CREATE UNIQUE INDEX uq_signworld_publication_active_content
    ON signworld_publication(content_id)
    WHERE state IN ('AWAITING_CODE', 'PUBLISHING');
```

- [ ] **Step 4: Add `Long machineId` end-to-end**

Add the entity column:

```java
@Column(name = "machine_id")
private Long machineId;
```

Add `Long machineId` after `terminalName` in both integration DTOs, assign it in `DisplayIntegrationService.update`, and map it field-by-field in `DisplayMapper`.

- [ ] **Step 5: Run migration and existing application tests**

```bash
cd smartcity-be
./gradlew test --tests ro.smartcity.display.signworld.SignworldMigrationTest
./gradlew test
```

Expected: PASS.

- [ ] **Step 6: Commit the schema slice**

```bash
git add src/main/resources/db/migration/V28__signworld_assisted_publishing.sql \
  src/main/java/ro/smartcity/display/DisplayIntegration.java \
  src/main/java/ro/smartcity/display/DisplayIntegrationService.java \
  src/main/java/ro/smartcity/display/DisplayMapper.java \
  src/main/java/ro/smartcity/display/dto/DisplayIntegrationResponse.java \
  src/main/java/ro/smartcity/display/dto/UpdateDisplayIntegrationRequest.java \
  src/test/java/ro/smartcity/display/signworld/SignworldMigrationTest.java
git commit -m "feat: persist Signworld machine and publication state"
```

---

### Task 3: Add typed configuration and strict origin validation

**Files:**

- Create: `smartcity-be/src/main/java/ro/smartcity/display/signworld/SignworldProperties.java`
- Create: `smartcity-be/src/main/java/ro/smartcity/display/signworld/SignworldOriginPolicy.java`
- Create: `smartcity-be/src/main/java/ro/smartcity/display/signworld/SignworldException.java`
- Modify: `smartcity-be/src/main/java/ro/smartcity/SmartCityApplication.java`
- Modify: `smartcity-be/src/main/resources/application.yml`
- Modify: `smartcity-be/src/main/resources/application-local.yml`
- Modify: `smartcity-be/src/main/resources/application-prod.yml`
- Test: `smartcity-be/src/test/java/ro/smartcity/display/signworld/SignworldOriginPolicyTest.java`

- [ ] **Step 1: Write origin-policy tests first**

Cover exact-origin HTTPS success and rejection of HTTP, user-info, fragment, alternate port, alternate host, relative URI, and cross-origin redirect:

```java
assertThat(policy.requireAllowed("https://portal.example.test/path").toString())
        .isEqualTo("https://portal.example.test/path");
assertThatThrownBy(() -> policy.requireAllowed("http://portal.example.test/path"))
        .isInstanceOf(SignworldException.class)
        .hasMessageContaining("HTTPS");
assertThatThrownBy(() -> policy.requireAllowed("https://portal.example.test.evil.test/path"))
        .isInstanceOf(SignworldException.class);
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew test --tests ro.smartcity.display.signworld.SignworldOriginPolicyTest
```

Expected: FAIL because the policy does not exist.

- [ ] **Step 3: Add immutable properties without secret-leaking `toString()`**

```java
@ConfigurationProperties(prefix = "app.signworld")
public final class SignworldProperties {
    private final URI allowedOrigin;
    private final String username;
    private final String password;
    private final Duration captchaTtl;
    private final Duration pollInterval;
    private final Duration publishTimeout;
    private final int captchaMaxBytes;

    public SignworldProperties(URI allowedOrigin, String username, String password,
                               Duration captchaTtl, Duration pollInterval,
                               Duration publishTimeout, int captchaMaxBytes) {
        this.allowedOrigin = allowedOrigin;
        this.username = username;
        this.password = password;
        this.captchaTtl = captchaTtl;
        this.pollInterval = pollInterval;
        this.publishTimeout = publishTimeout;
        this.captchaMaxBytes = captchaMaxBytes;
    }
    // Explicit accessors only. Do not generate or implement toString().
}
```

Register it in `@EnableConfigurationProperties` and add defaults:

```yaml
app:
  signworld:
    captcha-ttl: 5m
    poll-interval: 3s
    publish-timeout: 5m
    captcha-max-bytes: 1048576
```

Production-only values:

```yaml
app:
  signworld:
    allowed-origin: ${SIGNWORLD_ALLOWED_ORIGIN:}
    username: ${SIGNWORLD_USERNAME:}
    password: ${SIGNWORLD_PASSWORD:}
```

- [ ] **Step 4: Implement exact-origin validation**

Normalize default port (`443` for HTTPS), compare scheme/host/effective port exactly, reject user-info/fragments, and return sanitized `SignworldException("configuration_error", ...)` messages.

- [ ] **Step 5: Run tests and commit**

```bash
./gradlew test --tests ro.smartcity.display.signworld.SignworldOriginPolicyTest
git add src/main/java/ro/smartcity/SmartCityApplication.java \
  src/main/java/ro/smartcity/display/signworld/SignworldProperties.java \
  src/main/java/ro/smartcity/display/signworld/SignworldOriginPolicy.java \
  src/main/java/ro/smartcity/display/signworld/SignworldException.java \
  src/main/resources/application*.yml \
  src/test/java/ro/smartcity/display/signworld/SignworldOriginPolicyTest.java
git commit -m "feat: validate Signworld origin and secrets"
```

---

### Task 4: Persist encrypted sessions and bind CAPTCHA challenges

**Files:**

- Create the session/challenge files listed in the file map.
- Test: `SignworldSessionCodecTest.java`, `SignworldChallengeStoreTest.java`

- [ ] **Step 1: Write encryption and ownership tests**

Assert ciphertext does not contain cookie values and round-trips exactly:

```java
String encrypted = codec.encode(new SignworldSessionData(
        Map.of("SESSION", "fixture-cookie"), Instant.parse("2026-08-17T13:00:00Z")));
assertThat(encrypted).startsWith("enc:").doesNotContain("fixture-cookie");
assertThat(codec.decode(encrypted).cookies()).containsEntry("SESSION", "fixture-cookie");
```

Assert a challenge created for one `(userId, localityId, deviceId)` cannot be consumed by another and disappears after one attempt or TTL expiry.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew test --tests 'ro.smartcity.display.signworld.Signworld*StoreTest' \
  --tests ro.smartcity.display.signworld.SignworldSessionCodecTest
```

Expected: FAIL because the classes do not exist.

- [ ] **Step 3: Implement the encrypted session codec**

Serialize only a cookie map and expiry to JSON, call `CryptoService.encrypt`, and prefix the result with `enc:`. Reject missing prefixes, malformed JSON, and expired sessions with typed sanitized exceptions.

- [ ] **Step 4: Implement the bounded challenge store**

Use the existing Caffeine dependency:

```java
this.challenges = Caffeine.newBuilder()
        .maximumSize(500)
        .expireAfterWrite(properties.getCaptchaTtl())
        .build();
```

Store `challengeId`, owner IDs, opaque vendor key, MIME type, creation time, and expiry. `consume` validates ownership and invalidates the entry before returning it.

- [ ] **Step 5: Run tests and commit**

```bash
./gradlew test --tests 'ro.smartcity.display.signworld.Signworld*StoreTest' \
  --tests ro.smartcity.display.signworld.SignworldSessionCodecTest
git add src/main/java/ro/smartcity/display/signworld/SignworldSession* \
  src/main/java/ro/smartcity/display/signworld/SignworldChallenge* \
  src/test/java/ro/smartcity/display/signworld/SignworldSessionCodecTest.java \
  src/test/java/ro/smartcity/display/signworld/SignworldChallengeStoreTest.java
git commit -m "feat: protect Signworld sessions and challenges"
```

---

### Task 5: Implement fixture-backed Signworld authentication

**Files:**

- Create: `SignworldGateway.java`, `HttpSignworldGateway.java`, `SignworldAuthService.java`
- Create DTOs: `SignworldStatusResponse.java`, `SignworldCaptchaResponse.java`, `SignworldLoginRequest.java`
- Modify: `smartcity-be/build.gradle.kts`
- Test: `HttpSignworldGatewayAuthTest.java`, `SignworldAuthServiceTest.java`

- [ ] **Step 1: Add MockWebServer and failing contract tests**

```kotlin
testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
```

Load the sanitized fixtures from Task 1. Assert CAPTCHA route/method, login form field names, challenge key reuse, cookie capture, no cross-origin redirects, and no secret text in exception messages.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew test --tests ro.smartcity.display.signworld.HttpSignworldGatewayAuthTest \
  --tests ro.smartcity.display.signworld.SignworldAuthServiceTest
```

Expected: FAIL because the gateway and service do not exist.

- [ ] **Step 3: Define the vendor boundary**

```java
public interface SignworldGateway {
    VendorCaptcha fetchCaptcha(URI cmsUrl);
    VendorSession login(URI cmsUrl, VendorCaptcha captcha, String answer,
                        String username, String password);
    VendorPublication beginPublication(URI cmsUrl, VendorSession session,
                                       DisplayContent content, long machineId);
    VendorPublication confirm(URI cmsUrl, VendorSession session,
                              String vendorPublicationId, String code);
    VendorProgress progress(URI cmsUrl, VendorSession session,
                            String vendorPublicationId);
}
```

Vendor DTOs contain only opaque/sanitized contract values. Their `toString()` implementations must not expose cookie maps or credentials.

- [ ] **Step 4: Implement HTTP requests only from the captured fixtures**

Use `RestClient` over a JDK `HttpClient` with a per-operation `CookieManager`. Build login fields exactly as the sanitized `login-request.form` fixture. Parse only the fixture-confirmed success/error fields. Reject any unrecognized success shape as `unexpected_vendor_response`.

If Task 1 has not produced the required fixture, throw `SignworldException("contract_unavailable", "Signworld remote publishing is not configured")`; do not create guessed request fields.

- [ ] **Step 5: Implement auth orchestration**

`requestCaptcha` validates locality/device/integration/origin, stores the challenge, returns a `data:image/...;base64,...` URL with no-store semantics, and reports `CAPTCHA_REQUIRED`. `login` consumes the challenge, pulls backend-only credentials, encrypts/persists the vendor session, and reports `READY`.

- [ ] **Step 6: Run tests and commit**

```bash
./gradlew test --tests ro.smartcity.display.signworld.HttpSignworldGatewayAuthTest \
  --tests ro.smartcity.display.signworld.SignworldAuthServiceTest
git add build.gradle.kts src/main/java/ro/smartcity/display/signworld \
  src/test/java/ro/smartcity/display/signworld/HttpSignworldGatewayAuthTest.java \
  src/test/java/ro/smartcity/display/signworld/SignworldAuthServiceTest.java
git commit -m "feat: authenticate Signworld with assisted captcha"
```

---

### Task 6: Implement publication, e-mail confirmation, and progress polling

**Files:**

- Create publication entity/repository/service/poller files from the map.
- Create DTOs: `CreateSignworldPublicationRequest`, `ConfirmSignworldPublicationRequest`, `SignworldPublicationResponse`.
- Test: `HttpSignworldGatewayPublicationTest.java`, `SignworldPublicationServiceTest.java`, `SignworldPublicationPollerTest.java`.

- [ ] **Step 1: Write failing gateway tests from sanitized fixtures**

Verify exact message/program payloads, including:

```java
assertThat(form.get("machineIds")).isEqualTo("[8238]");
assertThat(form.get("name")).isEqualTo("Fixture emergency notice");
assertThatJson(form.get("messages")).isEqualTo(fixture.path("messages"));
```

Also assert e-mail code request, confirmation payload, progress ID, `Published 1/1`, explicit failure, ambiguous multiple-target response, and timeout.

- [ ] **Step 2: Write failing service-state tests**

Cover:

```text
READY -> AWAITING_CODE
AWAITING_CODE -> PUBLISHING
PUBLISHING -> PUBLISHED
session expired -> CAPTCHA_REQUIRED
wrong/expired code -> ERROR
vendor failure/timeout -> ERROR
```

Assert the request body cannot supply a machine ID and the service rejects integration machine IDs other than `8238` for the known Salaj company/terminal.

- [ ] **Step 3: Run and verify failure**

```bash
./gradlew test --tests ro.smartcity.display.signworld.HttpSignworldGatewayPublicationTest \
  --tests ro.smartcity.display.signworld.SignworldPublicationServiceTest \
  --tests ro.smartcity.display.signworld.SignworldPublicationPollerTest
```

- [ ] **Step 4: Implement state and persistence types**

```java
public enum SignworldState {
    UNAUTHENTICATED,
    CAPTCHA_REQUIRED,
    READY,
    AWAITING_CODE,
    PUBLISHING,
    PUBLISHED,
    ERROR
}
```

Repository queries must include locality/device ownership and
`findByStateAndVendorPublicationIdIsNotNull(PUBLISHING)` for restart recovery.

- [ ] **Step 5: Implement publication orchestration**

Create a row before the vendor call, copy machine ID from `DisplayIntegration`, and never accept a target from the frontend. On begin success store vendor ID and `AWAITING_CODE`; on confirm success store `PUBLISHING`; on terminal progress set content/integration/publication status atomically.

- [ ] **Step 6: Implement bounded polling**

Use the existing scheduler, `Clock`, configured interval, and deadline. Guard against duplicate pollers with a concurrent set keyed by publication UUID. Recover persisted `PUBLISHING` rows on `ApplicationReadyEvent`. Stop on success, failure, timeout, session expiry, or application shutdown.

- [ ] **Step 7: Run tests and commit**

```bash
./gradlew test --tests 'ro.smartcity.display.signworld.*Publication*Test'
git add src/main/java/ro/smartcity/display/signworld \
  src/test/java/ro/smartcity/display/signworld
git commit -m "feat: publish Signworld content with email verification"
```

---

### Task 7: Expose the secured SmartCity Signworld API

**Files:**

- Create: `SignworldController.java` and request/response DTOs.
- Modify: `GlobalExceptionHandler.java`, `DisplayIntegrationService.java`, `DisplayContentService.java`.
- Test: `SignworldControllerTest.java`, `SignworldSecretRedactionTest.java`.

- [ ] **Step 1: Write WebMvc tests**

Verify ADMIN/SUPER_ADMIN access, 403 for other roles, locality isolation, response shapes, `Cache-Control: no-store` for CAPTCHA, and absence of `password`, `cookie`, `token`, CAPTCHA answer, and e-mail code in every response.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew test --tests ro.smartcity.display.signworld.SignworldControllerTest \
  --tests ro.smartcity.display.signworld.SignworldSecretRedactionTest
```

- [ ] **Step 3: Add exact routes**

```java
@RestController
@RequestMapping("/api/localities/{localityId}/devices/{deviceId}/display/signworld")
@PreAuthorize("hasAnyRole('SUPER_ADMIN', 'ADMIN')")
final class SignworldController {
    @GetMapping("/status") SignworldStatusResponse status(...);
    @PostMapping("/captcha") ResponseEntity<SignworldCaptchaResponse> captcha(...);
    @PostMapping("/login") SignworldStatusResponse login(...);
    @PostMapping("/publications") ResponseEntity<SignworldPublicationResponse> create(...);
    @PostMapping("/publications/{publicationId}/confirm") SignworldPublicationResponse confirm(...);
    @GetMapping("/publications/{publicationId}") SignworldPublicationResponse publication(...);
    @PostMapping("/publications/{publicationId}/retry") SignworldPublicationResponse retry(...);
}
```

DTO validation requires nonblank CAPTCHA answer/code and UUID content ID; no DTO has username, password, session, or machine ID.

- [ ] **Step 4: Replace simulated sync behavior**

Remove `dry_run|simulate` branching. Manual/USB remain `noop`; remote Signworld sync returns current public status and tells the frontend to use the publication endpoints. `DisplayContentService.publish` retains manual package behavior and does not mark remote content published before vendor confirmation.

- [ ] **Step 5: Add sanitized error mapping**

Map typed errors to stable HTTP statuses: configuration/validation `400`, authentication required `401`, forbidden `403`, missing `404`, conflict `409`, expired challenge/code `410`, vendor unavailable/timeout `502/504`. Return only code, safe message, request ID, and timestamp.

- [ ] **Step 6: Run backend suite and commit**

```bash
./gradlew test
./gradlew bootJar
git add src/main/java/ro/smartcity/display src/main/java/ro/smartcity/common/exception \
  src/test/java/ro/smartcity/display/signworld
git commit -m "feat: expose assisted Signworld publishing API"
```

---

### Task 8: Add frontend types and API hooks

**Files:**

- Modify: `smartcity-fe/src/shared/types/smartcity.ts`
- Modify: `smartcity-fe/src/features/totems/api.ts`
- Modify: `smartcity-fe/src/features/totems/index.ts`
- Create: `smartcity-fe/src/features/totems/signworld-state.ts`
- Test: `smartcity-fe/src/features/totems/signworld-state.test.ts`

- [ ] **Step 1: Write state-helper tests**

```ts
expect(actionFor({ state: 'UNAUTHENTICATED' })).toBe('connect');
expect(actionFor({ state: 'CAPTCHA_REQUIRED' })).toBe('captcha');
expect(actionFor({ state: 'READY' })).toBe('publish');
expect(actionFor({ state: 'AWAITING_CODE' })).toBe('confirm');
expect(actionFor({ state: 'PUBLISHING' })).toBe('poll');
expect(actionFor({ state: 'PUBLISHED' })).toBe('done');
expect(actionFor({ state: 'ERROR', canRetry: true })).toBe('retry');
```

- [ ] **Step 2: Run and verify failure**

```bash
cd smartcity-fe
npm test -- --run src/features/totems/signworld-state.test.ts
```

- [ ] **Step 3: Add public types**

```ts
export type SignworldState =
  | 'UNAUTHENTICATED' | 'CAPTCHA_REQUIRED' | 'READY'
  | 'AWAITING_CODE' | 'PUBLISHING' | 'PUBLISHED' | 'ERROR';

export interface SignworldStatus {
  state: SignworldState;
  machineId: number | null;
  authenticatedAt?: string | null;
  expiresAt?: string | null;
  canRetry: boolean;
  errorCode?: string | null;
  errorMessage?: string | null;
}

export interface SignworldPublication extends SignworldStatus {
  publicationId: string;
  contentId: string;
  progressPercent?: number | null;
  completedAt?: string | null;
}
```

Add `machineId?: number | null` to `DisplayIntegration` and `UpdateIntegrationInput`.

- [ ] **Step 4: Add TanStack Query hooks**

Add status, CAPTCHA, login, create, confirm, retry, and publication polling hooks. Poll every three seconds only while state is `PUBLISHING`; stop for every terminal/non-polling state. Remove `dry_run` calls from `usePublishPlaylist` and `useSyncIntegration`.

- [ ] **Step 5: Run typecheck/tests and commit**

```bash
npm run typecheck
npm test -- --run src/features/totems/signworld-state.test.ts
git add src/shared/types/smartcity.ts src/features/totems/api.ts \
  src/features/totems/index.ts src/features/totems/signworld-state.ts \
  src/features/totems/signworld-state.test.ts
git commit -m "feat: add Signworld publishing client state"
```

---

### Task 9: Build the assisted publishing panel in the Totem editor

**Files:**

- Create: `SignworldPublishingPanel.tsx`, `SignworldPublishingPanel.test.tsx`
- Modify: `TotemEditor.tsx`, `TotemSettingsDialog.tsx`

- [ ] **Step 1: Write MSW component tests first**

Cover all seven states, CAPTCHA image/expiry/refresh, clearing CAPTCHA input after submit, clearing e-mail code after submit, wrong/expired code, polling success/failure, state restore after remount, fixed target display, and manual fallback.

Use MSW handlers on the exact SmartCity routes; assert request bodies contain only `challengeId/captchaAnswer`, `contentId`, or `code` as applicable and never credentials/machine ID.

- [ ] **Step 2: Run and verify failure**

```bash
npm test -- --run src/features/totems/components/editor/SignworldPublishingPanel.test.tsx
```

- [ ] **Step 3: Implement the panel as a state-driven component**

Render one compact panel/dialog inside the editor with:

```text
status badge
machine 8238
CAPTCHA image + refresh + answer field when required
Publish button when ready
verification code field when awaiting code
progress bar when publishing
completion time when published
sanitized error + retry/reconnect when failed
manual package fallback at all times
```

Use existing `PrimaryButton`, `TextField`, dialog, toast, spacing, and color tokens. Inputs use `autoComplete="off"`; CAPTCHA/code state is reset in `finally` after mutation submission.

- [ ] **Step 4: Compose it in `TotemEditor`**

`onPublish` saves content first, then opens/advances the Signworld panel rather than calling dry-run sync. Keep preview, autosave, settings, and mobile actions intact.

- [ ] **Step 5: Add explicit machine settings**

Add a numeric `machineId` field to `TotemSettingsDialog`, pre-filled from integration and defaulting to `8238` only for a new Signworld configuration. Validate a positive safe integer before PUT.

- [ ] **Step 6: Run focused tests and commit**

```bash
npm test -- --run src/features/totems/components/editor/SignworldPublishingPanel.test.tsx
npm run typecheck
git add src/features/totems/components/editor
git commit -m "feat: add assisted Signworld publishing UI"
```

---

### Task 10: Add localized copy and complete frontend verification

**Files:**

- Modify: `messages/ro/common.json`, `messages/hu/common.json`, `messages/en/common.json`
- Modify tests only if translation-key assertions require it.

- [ ] **Step 1: Add the exact seven status labels and action/error copy**

Under `totemsPage.editor.signworld`, add parallel keys for status, connect, refresh CAPTCHA, CAPTCHA expiry, publish, verification prompt, confirm, progress, retry, reconnect, manual fallback, and sanitized error categories.

- [ ] **Step 2: Verify locale key parity**

Run:

```bash
node - <<'NODE'
const fs = require('fs');
const files = ['ro', 'hu', 'en'].map(l => `messages/${l}/common.json`);
const objects = files.map(f => JSON.parse(fs.readFileSync(f, 'utf8')));
const keys = o => Object.keys(o.totemsPage.editor.signworld).sort();
if (JSON.stringify(keys(objects[0])) !== JSON.stringify(keys(objects[1])) ||
    JSON.stringify(keys(objects[0])) !== JSON.stringify(keys(objects[2]))) process.exit(1);
NODE
```

Expected: exit 0.

- [ ] **Step 3: Run the full frontend gate**

```bash
npm test
npm run typecheck
npm run build
```

Expected: all pass.

- [ ] **Step 4: Commit translations**

```bash
git add messages/ro/common.json messages/hu/common.json messages/en/common.json
git commit -m "feat: localize Signworld publishing workflow"
```

---

### Task 11: Wire backend-only deployment configuration

**Files:**

- Modify: `corevia-devops/.env.windows.example`
- Modify: `corevia-devops/docker-compose.windows.yml`
- Modify: `corevia-devops/WINDOWS_DEPLOY.md`

- [ ] **Step 1: Document variable names without values**

Add:

```dotenv
# Signworld values are backend-only. Never commit the real username/password.
# Required in production: set the exact authorized HTTPS origin.
SIGNWORLD_ALLOWED_ORIGIN=
# Required in production: inject through the server's protected environment.
SIGNWORLD_USERNAME=
SIGNWORLD_PASSWORD=
SIGNWORLD_REMOTE_ENABLED=false
```

`SIGNWORLD_REMOTE_ENABLED=false` keeps manual fallback active until Task 1 fixtures and live contract checks pass.

- [ ] **Step 2: Pass variables only to backend**

```yaml
SIGNWORLD_ALLOWED_ORIGIN: ${SIGNWORLD_ALLOWED_ORIGIN:?SIGNWORLD_ALLOWED_ORIGIN must be set}
SIGNWORLD_USERNAME: ${SIGNWORLD_USERNAME:?SIGNWORLD_USERNAME must be set}
SIGNWORLD_PASSWORD: ${SIGNWORLD_PASSWORD:?SIGNWORLD_PASSWORD must be set}
SIGNWORLD_REMOTE_ENABLED: ${SIGNWORLD_REMOTE_ENABLED:-false}
```

Do not add these variables to frontend build/runtime configuration.

- [ ] **Step 3: Validate compose without exposing values**

On a safe environment with variables set:

```bash
docker compose -f docker-compose.yml -f docker-compose.windows.yml config --quiet
```

Expected: exit 0. Do not print the expanded config because it contains secrets.

- [ ] **Step 4: Commit only targeted devops files**

```bash
cd corevia-devops
git add .env.windows.example docker-compose.windows.yml WINDOWS_DEPLOY.md
git diff --cached --check
git commit -m "feat: configure backend Signworld integration"
```

Confirm `git status --short` still shows the unrelated `docker-compose.yml` change unstaged.

---

### Task 12: Full verification, backup, deploy, and live acceptance

**Files:** No new source files; follow `WINDOWS_DEPLOY.md` and report evidence without secrets.

- [ ] **Step 1: Run final local gates**

```bash
cd smartcity-be && ./gradlew clean test bootJar
cd ../smartcity-fe && npm test && npm run typecheck && npm run build
cd ../corevia-devops && git diff --check
```

Expected: all pass.

- [ ] **Step 2: Back up production before migration**

On Windows, create a timestamped backup directory and save database dump, `.env`, compose files, current backend/frontend image IDs, and current application health. Restrict the backup ACL to administrators; do not copy secrets into the repository or chat.

- [ ] **Step 3: Build/push immutable backend and frontend images**

Tag both images by commit SHA. Record the SHA and image digest in the deployment report. Do not use an unrecorded mutable image for rollback-sensitive deployment.

- [ ] **Step 4: Validate migration against a restored backup**

Restore the production dump to a disposable database, run the new backend once with Flyway, and query only schema/status fields to confirm V28, company `13494`, terminal `signworld.inova`, and machine `8238`.

- [ ] **Step 5: Deploy only backend and frontend**

```powershell
docker compose -f docker-compose.yml -f docker-compose.windows.yml pull backend frontend
docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d --no-deps backend
docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d --no-deps frontend
```

Do not restart `postgres`, `redis`, `mosquitto`, `mediamtx`, Caddy, or WireGuard. Flyway runs as part of backend startup.

- [ ] **Step 6: Verify health and unchanged services**

Confirm backend health, frontend HTTPS, and pre/post container IDs for MQTT/MediaMTX/DB/Redis. Confirm bench/bin MQTT telemetry and camera/HLS remain functional.

- [ ] **Step 7: Run the live assisted flow**

In SmartCity Totems:

1. Open the `signworld.inova` integration and confirm machine `8238`.
2. Connect Signworld and manually solve the displayed CAPTCHA.
3. Publish a uniquely timestamped scrolling message.
4. Confirm state `AWAITING_CODE`.
5. Enter the e-mail code in SmartCity.
6. Confirm `PUBLISHING`, then `PUBLISHED`.
7. Confirm Signworld reports exactly one target.
8. Physically verify the message on the totem.
9. Verify the manual package fallback still downloads.

- [ ] **Step 8: Produce the final report**

Report modified files, migration version/checksum, test/build commands and outcomes, deployed image digests, services recreated, unchanged services, live publication ID/status, and rollback location. Redact credentials, CAPTCHA values, codes, cookies, tokens, and session ciphertext.

---

## Plan self-review checklist

- Contract capture precedes every real vendor request; no nested message/check payload is guessed.
- Machine targeting is server-side and fixed to the integration value `8238` for the verified Salaj row.
- Credentials never enter frontend DTOs/state.
- Session material is encrypted with the existing AES-GCM service.
- CAPTCHA and e-mail verification remain human-assisted.
- Manual export remains usable before, during, and after rollout.
- Tests cover login, CAPTCHA, wrong/expired code, success/failure, polling, redaction, target enforcement, and SSRF.
- Deployment touches backend/frontend only and preserves MQTT, WireGuard, cameras, MediaMTX, and Caddy.
