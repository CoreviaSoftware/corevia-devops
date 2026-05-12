# Totems page — design spec

**Status**: approved
**Date**: 2026-05-08
**Scope**: smartcity-be (rename + new device type) + smartcity-fe (new `/totems` page)

## 1. Goal

Manage a fleet of digital ad totems. Each totem is a CoreVia device of a new type
`smart_ad_totem_v1`, locality-scoped, displaying a `media_playlist` content item
published to a Signworld CMS (or USB-exported as fallback).

### v1 in scope

- Configuration: identity, location, ad playlist (videos/images with durations),
  Signworld integration config.
- Fleet status: online/offline + last-sync state per totem, sourced from the
  existing telemetry pipeline (`equipmentStatus`, `displayHealth`).
- Publishing: push the playlist to Signworld as a `signworld-content-package/v1`
  JSON. In USB mode the same JSON is downloaded for manual transfer.

### v1 out of scope

- Playback heartbeat, impression analytics, A/B scheduling.
- Multi-playlist rotation per totem (DB allows it; UI exposes one active playlist).
- Media file upload — URLs are free-text in v1.

## 2. Backend changes

### 2.1 Rename `station_*` to `display_*`

The existing `station_content` and `station_display_integration` tables are
device-agnostic — only the names imply bus stations. Rename them now while the
frontend has zero consumers.

**Migration `V38__rename_station_tables_to_display.sql`**:

```sql
ALTER TABLE station_content              RENAME TO display_content;
ALTER TABLE station_display_integration  RENAME TO display_integration;
ALTER INDEX idx_station_content_device   RENAME TO idx_display_content_device;
ALTER INDEX idx_station_content_locality RENAME TO idx_display_content_locality;
ALTER INDEX idx_station_content_status   RENAME TO idx_display_content_status;
```

No column changes.

**Java package `ro.smartcity.station` → `ro.smartcity.display`**, with class renames:

| old | new |
|---|---|
| `StationContent` (entity) | `DisplayContent` |
| `StationContentRepository` | `DisplayContentRepository` |
| `StationContentService` | `DisplayContentService` |
| `StationContentMapper` | `DisplayContentMapper` |
| `StationContentController` | `DisplayContentController` |
| `StationDisplayIntegration` | `DisplayIntegration` |
| `StationDisplayIntegrationRepository` | `DisplayIntegrationRepository` |
| `StationDisplayIntegrationService` | `DisplayIntegrationService` |
| `StationDisplayIntegrationController` | `DisplayIntegrationController` |
| DTOs under `dto/` | renamed to drop `Station` prefix |

Mappers stay hand-written `@Component` classes per `smartcity-be/CLAUDE.md`.
`SignworldPackageBuilder` keeps its name (vendor-correct).
`ContentKind`, `ContentPublishStatus`, `DisplayIntegrationMode`,
`DisplayIntegrationProvider` move with the package.

### 2.2 REST URL changes

Old paths are deleted, not deprecated (FE has no consumers, no external clients).

| old | new |
|---|---|
| `GET    /api/localities/{localityId}/stations/{stationId}/content` | `GET    /api/localities/{localityId}/devices/{deviceId}/display/content` |
| `POST   .../stations/{stationId}/content` | `POST   .../devices/{deviceId}/display/content` |
| `PUT    .../stations/{stationId}/content/{contentId}` | `PUT    .../devices/{deviceId}/display/content/{contentId}` |
| `DELETE .../stations/{stationId}/content/{contentId}` | `DELETE .../devices/{deviceId}/display/content/{contentId}` |
| `POST   .../stations/{stationId}/content/{contentId}/publish` | `POST   .../devices/{deviceId}/display/content/{contentId}/publish` |
| `GET    .../stations/{stationId}/content/{contentId}/signworld-package` | `GET    .../devices/{deviceId}/display/content/{contentId}/signworld-package` |
| `GET    .../stations/{stationId}/display-integration` | `GET    .../devices/{deviceId}/display/integration` |
| `PUT    .../stations/{stationId}/display-integration` | `PUT    .../devices/{deviceId}/display/integration` |
| `POST   .../stations/{stationId}/display-integration/sync` | `POST   .../devices/{deviceId}/display/integration/sync` |

Path variable renamed from `stationId` to `deviceId` everywhere.

### 2.3 Audit log strings

| old | new |
|---|---|
| `CREATE_STATION_CONTENT` | `CREATE_DISPLAY_CONTENT` |
| `UPDATE_STATION_CONTENT` | `UPDATE_DISPLAY_CONTENT` |
| `DELETE_STATION_CONTENT` | `DELETE_DISPLAY_CONTENT` |
| `PUBLISH_STATION_CONTENT` | `PUBLISH_DISPLAY_CONTENT` |
| `UPDATE_STATION_DISPLAY_INTEGRATION` | `UPDATE_DISPLAY_INTEGRATION` |
| `SYNC_STATION_DISPLAY` | `SYNC_DISPLAY` |

One-time historical-event-name break — acceptable; audit log is internal.

### 2.4 New device type seed

**Migration `V39__seed_smart_ad_totem.sql`**:

```sql
INSERT INTO device_types (code, category, name, description,
    metrics_schema, threshold_rules, field_mapping_defaults,
    canonical_metric_roles, supported_protocols)
VALUES (
  'smart_ad_totem_v1', 'DIGITAL_SIGNAGE', 'Ad totem',
  'Standalone digital signage totem playing video/image ad playlists. Driven via Signworld CMS (remote_cms) or USB drop (usb fallback).',
  $${
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "timestamp":       {"type": ["string", "null"]},
      "equipmentStatus": {"type": ["string", "null"], "enum": ["healthy","warning","fault","maintenance","offline", null]},
      "displayHealth":   {"type": ["string", "null"], "enum": ["online","offline","degraded", null]},
      "faultAlarms":     {"type": ["array", "null"], "items": {"type": "string"}}
    },
    "additionalProperties": false
  }$$::jsonb,
  $$[
    {"id":"display-offline","metric":"displayHealth","operator":"==","value":"offline",
     "severity":"HIGH","titleTemplate":"Ad totem display offline",
     "descriptionTemplate":"Display health is offline"},
    {"id":"fault-alarm","metric":"faultAlarms","operator":"nonEmpty",
     "severity":"CRITICAL","titleTemplate":"Ad totem hardware fault",
     "descriptionTemplate":"Alarms: {{faultAlarms}}"}
  ]$$::jsonb,
  '{}'::jsonb,
  '["timestamp","equipmentStatus","displayHealth","faultAlarms"]'::jsonb,
  ARRAY['mqtt','rest','folder','webhook']
);
```

Mirrors `camera_v1` plus `displayHealth` from `smart_bus_station_v1`. No
playback heartbeat — totems are not required to report.

## 3. Frontend changes

### 3.1 Type renames

In `smartcity-fe/src/shared/types/smartcity.ts`:

| old | new |
|---|---|
| `StationContent` | `DisplayContent` |
| `StationContentKind` | `DisplayContentKind` |
| `StationDisplayIntegration` | `DisplayIntegration` |

No component currently imports these, so it's a search-and-replace in the types
file plus the re-export in `@smartcity/shared`.

### 3.2 New feature module

```
smartcity-fe/src/features/totems/
  api.ts            React Query hooks (see 3.3)
  index.ts          public exports
  types.ts          re-exports from @smartcity/shared
  components/
    TotemsView.tsx          list page body
    TotemFormDialog.tsx     create/edit identity (name, location, locality)
    DeleteTotemDialog.tsx
    detail/
      TotemDetailView.tsx       composes the cards below
      TotemHeader.tsx           name/location/online status + actions menu
      TotemPlaylistCard.tsx     ad playlist editor
      TotemIntegrationCard.tsx  Signworld config + Sync now + last-sync state
      TotemStatusCard.tsx       equipmentStatus, displayHealth, last seen, faults
      TotemIncidentsCard.tsx    reuses DeviceIncidentsCard pattern
```

### 3.3 Routes and React Query hooks

**Routes**:
- `app/[locale]/(app)/totems/page.tsx` → `TotemsView`
- `app/[locale]/(app)/totems/[id]/page.tsx` → `TotemDetailView`

**Hooks** in `features/totems/api.ts`:
- `useTotems(filters)` — thin wrapper over the existing
  `useDevicesPaged({ category: 'DIGITAL_SIGNAGE', ...filters })` from
  `features/devices/api.ts`. Reuses its built-in fan-out across localities for
  super-admins. No new backend endpoint.
- `useTotem(deviceId)` — full device record.
- `useTotemPlaylist(deviceId)` — list of `display_content` rows (v1 expects 0 or 1).
- `useUpdateTotem(deviceId)` — PATCH device identity.
- `useUpsertPlaylist(deviceId)` — POST or PUT the single media_playlist row.
- `usePublishPlaylist(deviceId, contentId)` — calls `/publish` then triggers
  `/integration/sync` in one atomic flow (see 3.5).
- `useUpdateIntegration(deviceId)` — PUT integration.
- `useSyncIntegration(deviceId)` — POST `/integration/sync`.

### 3.4 Sidebar

In `smartcity-fe/src/shared/layout/Sidebar.tsx`, insert after the `cameras`
entry (line 36):

```ts
{ key: 'totems', href: '/totems', icon: Tv, adminOnly: true },
```

`adminOnly: true` matches the ADMIN + SUPER_ADMIN permission gate.

### 3.5 Page UX

**`/totems` (list view)**:
- Header: "Totems" title + "Add Totem" button (right).
- Filters row: locality select, status filter (online/offline/all), search by name.
- Table columns: name | locality | online status | actions menu.
  - "Last published at" and "last sync status" are deferred to v1.1 — surfacing
    them in the list would require either an N+1 fetch (one
    `display_content` + `display_integration` query per row) or a new BE
    endpoint that pre-joins. Both are out of v1 scope. They live on the detail
    page in v1.
- Empty state: "No totems yet — add your first one to push ads to Signworld."

**Add Totem dialog** fields: name, location (free text), locality, Signworld
terminal name (defaults to totem name). On submit:
1. `POST /api/localities/{id}/devices` with `deviceTypeCode: 'smart_ad_totem_v1'`.
2. `PUT /api/localities/{id}/devices/{deviceId}/display/integration` with the
   provided terminal name and defaults (`provider: 'signworld'`, `mode: 'remote_cms'`).
3. Redirect to `/totems/{deviceId}`.

**`/totems/[id]` (detail view)** — stacked cards top-to-bottom:
1. **Header card** — name, location, online dot, "Edit" / "Delete" / "Sync now".
2. **Status card** — `equipmentStatus`, `displayHealth`, last telemetry timestamp,
   active fault alarms.
3. **Ad Playlist card** — list of playlist items (drag to reorder), per-row
   inline edit (`title`, `url`, `mediaType`, `durationSeconds`), "+ Add item".
   Actions: "Save draft" / "Publish to Signworld" (or "Download package" in
   USB mode). Shows `publish_status` + `published_at`.
4. **Signworld Integration card** — `provider`, `mode`, `cmsUrl`, `serverHost`,
   `companyId`, `terminalName`, `notes`. "Sync now" + last-sync status/time/message.
5. **Recent incidents card** — reuses `DeviceIncidentsCard`.

**Single-playlist model**: each totem has at most one active `media_playlist`
content row in v1. The DB still supports many; UI does not.

**Publish flow (one click)** in `remote_cms` mode:
1. Save current playlist edits.
2. `POST .../display/content/{contentId}/publish` — marks
   `publish_status='pending_external_sync'`.
3. `POST .../display/integration/sync` — pushes to Signworld; updates
   `last_sync_*` and `publish_status` to `published` or `failed`.
   Frontend awaits both; toast on success/failure.

**Publish flow in `usb` mode**: button reads "Download package" and triggers
`GET .../signworld-package` which returns the JSON for manual transfer. No sync.

### 3.6 i18n

Add a `totems` namespace to the locale messages (en, ro — matching what
`cameras` already ships) with keys for: page title, table column headers, all
form labels, status pill labels, dialog titles, action button labels, empty
state, error toasts.

Add `nav.totems` key for the sidebar label.

## 4. Permissions

ADMIN and SUPER_ADMIN see the sidebar entry and can call all endpoints. Regular
users get 403. Implementation: copy the existing `@PreAuthorize` annotations
from `StationContentController`/`StationDisplayIntegrationController` into the
renamed controllers — the permission model carries over unchanged.

## 5. Error handling

- React Query toasts on mutation errors (matches `cameras` feature).
- Sync failures persist to `display_integration.last_sync_*` server-side; the
  Integration card surfaces them.
- The detail page renders cards independently — a failure to load incidents or
  status does not block the playlist editor.

## 6. Testing

Per `smartcity-be/CLAUDE.md`: no tests are written by collaborators. The owner
authors the suite once the app is stable.

## 7. Decisions and answers from brainstorming

- **Page scope v1**: configuration + fleet status (online/offline, last sync).
  No playback heartbeat — totems are not required to report.
- **Locality scope**: every totem belongs to a locality (same as bus stations
  and cameras).
- **Sidebar**: label "Totems", positioned after "Cameras".
- **Tables**: rename `station_*` → `display_*` now (cheapest moment, FE has no
  consumers).
- **Permissions**: ADMIN + SUPER_ADMIN.
- **Publish**: save + sync in one click (remote_cms mode).
- **Media URLs**: free-text only in v1.
- **Old endpoints**: deleted, not deprecated.

## 8. Migration order and risk

1. `V38__rename_station_tables_to_display.sql` — rename tables and indexes.
2. Java rename across `ro.smartcity.station` → `ro.smartcity.display` + URL
   path changes + audit string changes. Atomic with V38 in the same PR.
3. `V39__seed_smart_ad_totem.sql` — seed the new device type.
4. FE type renames in `shared/types/smartcity.ts`.
5. New `features/totems/` module + routes + sidebar entry + i18n.

Risk: medium-low. No data migration. Rename is reversible by reverting. The new
device type seed is purely additive.
