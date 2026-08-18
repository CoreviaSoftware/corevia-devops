# Signworld assisted publishing — design specification

**Status**: approved
**Date**: 2026-08-17
**Scope**: `smartcity-be`, `smartcity-fe`, and backend environment wiring in `corevia-devops`

## 1. Goal

Publish scrolling text and media programs from the existing SmartCity Totems module
to the Signworld terminal that was physically verified with these identifiers:

- company ID: `13494`
- terminal name: `signworld.inova`
- machine ID: `8238`
- verified manual publication: `128744`, result `Published 1/1`

The operator completes Signworld CAPTCHA and e-mail verification inside SmartCity.
SmartCity does not bypass either control. Manual Signworld publication and the
existing JSON-package export remain available as fallback.

This feature does not modify WireGuard, cameras, MediaMTX, Caddy, or the MQTT
ingestion used by benches and bins. WireGuard is not a Signworld dependency.

## 2. Current state

The application already has:

- a locality-scoped Totems module;
- `display_content` and `display_integration` persistence;
- `manual` and `signworld` providers;
- `usb` and `remote_cms` modes;
- a `signworld-content-package/v1` manual export;
- AES-256-GCM encryption through `CryptoService` and `APP_SECRET_KEY`.

The current remote sync is not a vendor integration. It returns `dry_run` or
`simulate` results and performs no Signworld HTTP request. There is no
`machine_id`, Signworld session, CAPTCHA flow, verification flow, publication
record, or progress polling.

## 3. Design decisions

### 3.1 Integration boundary

All vendor traffic originates in `smartcity-be`. The browser never calls
Signworld directly. A `SignworldGateway` interface isolates the vendor contract
from orchestration and allows deterministic mock-server tests.

The production implementation uses Spring's synchronous `RestClient`, matching
the blocking Spring MVC application. It keeps one cookie-aware HTTP session per
SmartCity display integration. Redirects are restricted to the configured
Signworld origin.

### 3.2 Origin configuration and SSRF protection

`display_integration.cms_url` remains the per-totem portal URL. A deployment
secret/config value named `SIGNWORLD_ALLOWED_ORIGIN` defines the only permitted
scheme, host, and effective port.

Before every vendor request, the backend requires:

- an absolute HTTPS URL;
- exact origin equality with `SIGNWORLD_ALLOWED_ORIGIN`;
- no user-info component;
- no fragment;
- no redirect outside that origin.

A missing or mismatched origin produces a configuration error before any
network request. Administrators cannot use `cmsUrl` as a general-purpose proxy.

### 3.3 Credentials and sensitive data

The Signworld username and password are supplied only to the backend through
`SIGNWORLD_USERNAME` and `SIGNWORLD_PASSWORD`. They are not columns, request
fields, response fields, frontend state, audit fields, or log parameters.

The authenticated Signworld cookie/token material is encrypted at rest using
the existing `CryptoService`. The database stores only ciphertext prefixed with
`enc:`. CAPTCHA answers and e-mail verification codes are transient request
values: they are forwarded once, never persisted, and never logged.

Logs may contain the SmartCity publication UUID, content UUID, machine ID,
state, HTTP status class, and a sanitized vendor error code. Logs must not
contain credentials, CAPTCHA images/answers, verification codes, cookies,
tokens, full vendor response bodies, or signed URLs.

### 3.4 Exact vendor contract gate

The known current routes are:

- `GET /apic/user/graph/code`
- `POST /apic/user/login`
- `GET /apic/user/publishing/emailcode`
- `POST /apic/user/check`
- `GET/POST /apip/program`
- `POST /apip/publishing/program`
- `GET /apip/publishing/message/progress/{id}`

Previously observed login fields are `username`, `password`, `code`, and `key`.
Previously observed scrolling-message fields include `name`,
`messages=JSON.stringify(...)`, and
`machineIds=JSON.stringify([8238])`.

Those observations are not sufficient to invent the nested `messages` schema
or the publication-confirmation schema. Before enabling remote publication, the
current official portal bundle or an authorized browser network capture must be
saved as sanitized contract fixtures. Fixtures retain field names and value
shapes while replacing credentials, cookies, CAPTCHA values, e-mail codes, and
personal data with deterministic test values.

The real adapter is considered complete only when each outbound request is
generated from a fixture-backed DTO and a mock-server test proves byte-level
form/JSON compatibility. Until those fixtures exist, `remote_cms` reports a
configuration error and manual export remains usable. There is no generic
request proxy and no guessed vendor payload.

## 4. Persistence model

### 4.1 `display_integration`

Migration `V28__signworld_assisted_publishing.sql` adds:

- `machine_id BIGINT NULL`;
- a check constraint requiring a positive value when present.

The data correction targets only the known integration rows whose company ID is
`13494` or terminal name is `signworld-inova`:

- `integration_company_id = '13494'`;
- `terminal_name = 'signworld.inova'`;
- `machine_id = 8238`.

No global default is added at database level. New Signworld integrations require
an explicit machine ID; the Salaj UI pre-fills `8238` for the known terminal.

### 4.2 `signworld_session`

One row per display integration:

- `device_id UUID PRIMARY KEY` and foreign key to `display_integration`;
- `encrypted_session TEXT`;
- `expires_at TIMESTAMPTZ`;
- `authenticated_at TIMESTAMPTZ`;
- `updated_at TIMESTAMPTZ NOT NULL`.

CAPTCHA challenges are not stored in this table. They live in an in-memory,
bounded, expiring challenge store for at most five minutes. Each challenge is
bound to the authenticated SmartCity user, locality, device, and an opaque
challenge UUID. The store contains only the vendor challenge key and CAPTCHA
bytes needed for the next login attempt.

A backend restart invalidates pending CAPTCHA challenges but does not destroy an
encrypted authenticated session.

### 4.3 `signworld_publication`

Each publish attempt receives its own row:

- `id UUID PRIMARY KEY`;
- `device_id UUID NOT NULL`;
- `content_id UUID NOT NULL`;
- `machine_id BIGINT NOT NULL`;
- `vendor_publication_id VARCHAR(120)`;
- `state VARCHAR(40) NOT NULL`;
- `progress_percent INTEGER`;
- `sanitized_error_code VARCHAR(120)`;
- `sanitized_error_message TEXT`;
- `created_by UUID`;
- `created_at`, `updated_at`, and `completed_at` timestamps.

The service always copies the machine ID from the integration and rejects any
client-supplied target. For this deployment it must equal `8238`. A uniqueness
guard prevents two non-terminal publication attempts for the same content.

## 5. State machine

The public API exposes these states:

- `UNAUTHENTICATED` — no reusable vendor session;
- `CAPTCHA_REQUIRED` — authentication requires a human-solved CAPTCHA; a
  five-minute challenge may be requested or refreshed;
- `READY` — the encrypted vendor session is valid;
- `AWAITING_CODE` — Signworld accepted the publication request and sent e-mail verification;
- `PUBLISHING` — verification succeeded and vendor progress is being polled;
- `PUBLISHED` — Signworld reported `Published` for the sole target;
- `ERROR` — a terminal or retryable failure with a sanitized message.

Allowed transitions:

```text
UNAUTHENTICATED -> CAPTCHA_REQUIRED -> READY
READY -> AWAITING_CODE -> PUBLISHING -> PUBLISHED
CAPTCHA_REQUIRED -> ERROR
AWAITING_CODE -> ERROR
PUBLISHING -> ERROR
READY -> CAPTCHA_REQUIRED       (vendor session expired)
ERROR -> CAPTCHA_REQUIRED       (authentication retry)
ERROR -> READY                  (publication retry with a valid session)
```

`PUBLISHED` is set only after vendor progress confirms success for exactly one
target and that target is machine `8238`. A successful HTTP response alone is
not publication success.

## 6. SmartCity backend API

All routes are under:

`/api/localities/{localityId}/devices/{deviceId}/display/signworld`

They require `ADMIN` or `SUPER_ADMIN` and enforce the existing locality scope.

### Authentication

- `GET /status` — integration configuration plus public state; never secrets.
- `POST /captcha` — requests a fresh vendor challenge and returns
  `{challengeId, imageDataUrl, expiresAt, state}`.
- `POST /login` with `{challengeId, captchaAnswer}` — uses backend credentials,
  encrypts the resulting session, consumes the challenge, and returns `READY`.

Only `image/*` CAPTCHA responses within a small configured size limit are
accepted. `imageDataUrl` is returned with `Cache-Control: no-store`.

### Publication

- `POST /publications` with `{contentId}` — validates the content and integration,
  creates/saves the scrolling message or media program, fixes the target to
  `8238`, requests the Signworld e-mail code, and returns `AWAITING_CODE`.
- `POST /publications/{publicationId}/confirm` with `{code}` — forwards the code
  once and begins progress polling after successful verification.
- `GET /publications/{publicationId}` — returns sanitized state and progress.
- `POST /publications/{publicationId}/retry` — retries only from `ERROR`; it does
  not reuse an expired e-mail code.

The existing manual package endpoint remains unchanged. The existing
`/display/integration/sync` endpoint stops accepting `dry_run`/`simulate`; for
Signworld remote mode it returns the current Signworld public status and directs
new publication work through `/display/signworld/publications`.

## 7. Vendor operations

### 7.1 Authentication

1. Fetch CAPTCHA bytes and opaque vendor challenge key.
2. Return only the image and SmartCity challenge UUID to the frontend.
3. On login, submit backend username/password plus operator CAPTCHA answer and
   the stored vendor challenge key.
4. Reject ambiguous responses, missing authenticated cookies, or cross-origin
   redirects.
5. Encrypt and persist the authenticated session.

### 7.2 Scrolling text

The adapter converts the selected `DisplayContent` into the exact fixture-backed
Signworld scrolling-message DTO. The request always serializes
`machineIds` from the server-side constant list containing only `8238`.

After Signworld saves the message, the adapter requests e-mail verification and
persists the vendor publication ID needed for confirmation and progress.

### 7.3 Image and video programs

Image/video content uses only:

- `GET/POST /apip/program` for program discovery/creation;
- `POST /apip/publishing/program` for publication;
- the corresponding fixture-confirmed progress endpoint.

Media bytes or URLs are not sent until the current bundle fixtures establish
the exact upload/reference contract. Unsupported content returns a validation
error and leaves manual export available.

### 7.4 Progress polling

Polling starts only after successful e-mail-code verification. It uses bounded
backoff, one poller per publication, and a fixed overall timeout. Application
restart recovery resumes non-terminal `PUBLISHING` rows that have a vendor
publication ID and a valid encrypted session.

Polling stops on `Published`, explicit vendor failure, timeout, missing target,
multiple targets, or session expiry. Session expiry changes authentication state
to `CAPTCHA_REQUIRED`; it never triggers automated CAPTCHA solving.

## 8. Frontend design

The existing Totem editor gains one Signworld publication panel. It does not
create a separate application or page family.

### Settings

The integration dialog adds `machineId`. It displays `8238` for the known Salaj
terminal and validates a positive integer. `companyId`, `terminalName`, and
`cmsUrl` remain editable by administrators. Password and username fields do not
exist in the frontend.

### Assisted authentication

When state is `UNAUTHENTICATED`, publishing offers “Connect Signworld”. The panel
requests and displays the CAPTCHA with a refresh action and expiry countdown.
The operator enters the CAPTCHA answer; the input is cleared immediately after
submission regardless of result.

### Assisted publication

When state is `READY`, “Publish to Signworld” saves the content and starts the
publication. At `AWAITING_CODE`, the panel displays one verification-code input
and an explicit confirmation button. The code is cleared immediately after
submission.

At `PUBLISHING`, the UI polls the SmartCity publication endpoint and displays
vendor-confirmed progress. `PUBLISHED` includes completion time. `ERROR` includes
a sanitized actionable message and either retry-publication or reconnect action.

Closing or refreshing the browser does not cancel a server-side publication;
the panel restores state from the backend.

All seven labels are translated in Romanian, Hungarian, and English:

- Neautentificat / Unauthenticated
- CAPTCHA necesar / CAPTCHA required
- Pregătit / Ready
- Așteaptă codul / Awaiting code
- Se publică / Publishing
- Publicat / Published
- Eroare / Error

## 9. Error handling

Errors are classified without leaking vendor bodies:

- configuration/origin error;
- CAPTCHA expired or incorrect;
- credentials rejected;
- vendor session expired;
- e-mail code incorrect or expired;
- unsupported content contract;
- vendor validation failure;
- publication timeout;
- vendor publication failure;
- unexpected or ambiguous vendor response.

Authentication failures invalidate only the Signworld session. Publication
failures update only their publication/content/integration status. They do not
affect device telemetry, MQTT runtimes, cameras, networking, or other containers.

## 10. Testing

### Backend

Mock-server contract tests cover:

- CAPTCHA image and challenge binding;
- CAPTCHA refresh and expiry;
- successful login and encrypted-session persistence;
- incorrect CAPTCHA and rejected credentials;
- absence of secrets in responses and captured logs;
- session reuse and session expiry;
- scrolling-message request fixture;
- program request fixture;
- enforced single target `8238`;
- e-mail code request;
- wrong and expired codes;
- successful confirmation;
- progress `PUBLISHING -> PUBLISHED`;
- vendor failure and timeout;
- restart recovery;
- rejection of non-HTTPS, mismatched-origin, and cross-origin redirect URLs;
- locality and role authorization.

Database tests cover migration safety, the targeted `signworld-inova` correction,
and the one-active-publication guard.

### Frontend

Component/hook tests cover all seven states, CAPTCHA refresh/expiry, answer and
code clearing, wrong/expired code messages, polling completion, polling failure,
page restoration, fixed machine display, and manual fallback.

### Live acceptance

1. Back up database, backend configuration, and current application images.
2. Configure the allowed origin and backend-only Signworld credentials.
3. Run Flyway migration and deploy only backend/frontend changes.
4. Confirm MQTT benches/bins and camera services were not restarted or changed.
5. Connect Signworld from Totems using a human-entered CAPTCHA.
6. Publish a uniquely identifiable scrolling message to machine `8238`.
7. Enter the e-mail code in SmartCity.
8. Observe `PUBLISHING` and then `PUBLISHED` in SmartCity.
9. Physically confirm the unique message on the totem.
10. Confirm Signworld reports one target and manual publication still works.

## 11. Rollback

Application rollback redeploys the prior backend/frontend images. The additive
tables and nullable `machine_id` column may remain without affecting old code.
The migration is not reversed in production. Manual Signworld publication and
package export remain the operational fallback throughout rollout.
