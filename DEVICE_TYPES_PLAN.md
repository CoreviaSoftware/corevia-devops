# Device Types Consolidation & Per-Device Detail Pages

## Goal

Consolidate the device catalog to **4 types** (smart bench, smart trash bin, smart bus station, smart WiFi AP) and add a per-device detail page on the FE that renders type-specific information.

Cameras are dropped from the device-type catalog and continue to live only in the dedicated `features/cameras` page.

## Decisions

### Naming (short categories, aligned across layers)

| Layer                       | Bench          | Trash bin     | Bus station          | WiFi AP             |
|-----------------------------|----------------|---------------|----------------------|---------------------|
| BE `DeviceType.category`    | `BENCH`        | `TRASH_BIN`   | `BUS_STATION`        | `WIFI_AP`           |
| BE `DeviceKind` wire        | `smart_bench`  | `smart_bin`   | `smart_bus_station`  | `smart_wifi_ap`     |
| FE `DeviceType` union       | `SMART_BENCH`  | `SMART_BIN`   | `SMART_BUS_STATION`  | `SMART_WIFI_AP`     |

FE rename: `SMART_TRASH_BIN` → `SMART_BIN` (matches BE wire — single source of truth).
Drop everywhere: `CAMERA`.

### Counters semantics

`lidAccessCount`, `wifiAccessCount`, `chargingSessions` are treated as **cumulative lifetime counters** as reported by the device.
The FE shows total + delta over a selected window (today / 7d / 30d), computed by diffing the newest vs. oldest reading in the window. No schema change — `sensor_readings` already stores the time series.

### Capabilities model

Add `Device.capabilities` jsonb:

```json
{ "hasWifi": false }
```

- `hasWifi` is meaningful only on `BUS_STATION`. Bench wifi is always-present per requirements; WiFi AP is itself a wifi device.
- The detail page hides cards/metrics whose capability flag is false.

### No battery telemetry

Battery level is **not** part of the product (dropped 2026-07-31, migration `V24__drop_battery_metric.sql`): field devices don't report a trustworthy charge level. The only health signal is ONLINE/OFFLINE from `OfflineDetector` — which covers a dead battery, a comms failure and a power cut alike. Do not re-add a `batteryPercent` role, a low-battery rule or a battery card.

## Per-device detail page — content matrix

| Card                                | Bench         | Trash bin     | Bus station                | WiFi AP       |
|-------------------------------------|---------------|---------------|----------------------------|---------------|
| Header (name, status, location, last seen) | ✓     | ✓             | ✓                          | ✓             |
| Configured full/not-full sensor + alarm | —          | ✓                         | —                | —             |
| Lid access count (+ 7d sparkline)   | —             | ✓             | —                          | —             |
| Last emptied timestamp              | —             | ✓             | —                          | —             |
| Charging sessions (+ 7d sparkline)  | ✓             | —             | —                          | —             |
| WiFi access count (+ 7d sparkline)  | ✓             | —             | ✓ (if `hasWifi`)           | ✓             |
| Connected clients / throughput      | —             | —             | —                          | ✓             |
| Telemetry chart                     | ✓             | ✓             | ✓                          | ✓             |

## Backend changes (`smartcity-be`)

1. **`DeviceKind.java`** — remove `CAMERA` enum value; drop the `CAMERA` case in `fromCategory(...)`.
2. **`Device.java`** — add jsonb column:
   ```java
   @Type(JsonType.class)
   @Column(name = "capabilities", columnDefinition = "jsonb", nullable = false)
   private Map<String, Object> capabilities = Map.of();
   ```
3. **Flyway migration** `V<next>__device_capabilities_and_cleanup.sql`:
   - `ALTER TABLE devices ADD COLUMN capabilities jsonb NOT NULL DEFAULT '{}'::jsonb;`
   - Remove any `device_types` rows with `category = 'CAMERA'` (see open caveat).
4. **`DeviceMapper.java` / `DeviceController.java`** — include `capabilities` (and existing `lastTelemetry`) in the device DTO returned by `GET /api/devices/{id}`. Hand-written mapper, per project convention (no MapStruct).
5. **Readings endpoint** — `GET /api/devices/{id}/readings?metric=<role>&from=<iso>&to=<iso>` for the detail-page chart. Extend `SensorController` if a comparable endpoint exists; otherwise add to `DeviceController`.

## Frontend changes (`smartcity-fe`)

1. **`shared/types/smartcity.ts`**
   - `DeviceType` union → `'SMART_BENCH' | 'SMART_BIN' | 'SMART_BUS_STATION' | 'SMART_WIFI_AP' | string` (drop `SMART_TRASH_BIN` and `CAMERA`).
   - `DeviceKind` → drop `'camera'`.
   - `Device` → add `capabilities?: { hasWifi?: boolean }`.

2. **New route** — `app/[locale]/(app)/devices/[id]/page.tsx`. Fetches the device, branches on `deviceTypeCategory` to render the right panel.

3. **New components** under `features/devices/components/detail/`:
   - `DeviceDetailHeader.tsx` — name, status pill, location, last seen, online indicator.
   - `TrashBinPanel.tsx` — full/not-full state, lid-access total + sparkline, last-emptied.
   - `BenchPanel.tsx` — charging sessions total + sparkline, wifi access total + sparkline.
   - `BusStationPanel.tsx` — wifi access total + sparkline (only if `hasWifi`); displays/schedules from `stationConfig` if non-empty.
   - `WifiApPanel.tsx` — wifi access total + sparkline, connected clients (current), throughput.
   - `TelemetryChart.tsx` — shared sparkline/area chart, accepts metric role + window.

4. **`features/devices/api.ts`** — add `getDevice(id)` and `getDeviceReadings(id, metric, window)`.

5. **List view** (`features/devices/components/DevicesView.tsx`) — make rows link to `/devices/[id]`.

## Implementation order

1. BE: entity field + Flyway migration + mapper + controller DTO surface.
2. BE: readings endpoint (or extension of existing one).
3. FE: type updates.
4. FE: detail route + shared header + telemetry chart.
5. FE: type-specific panels (bench, trash bin, bus station, wifi ap).
6. FE: link list rows to detail page.

## Open caveats

- **CAMERA cleanup** — confirm whether real `CAMERA` rows exist in `device_types` / `devices` in any environment. If yes, the migration needs to reassign those devices first (or cascade-delete). If no, plain `DELETE FROM device_types WHERE category = 'CAMERA'` is safe.
- **Tests** — no tests will be added (per project convention). If existing tests break from the `CAMERA` removal or the new column, fix the production code or test setup; do not add new assertions.

## Conventions reminder

- Hand-written `@Component` mappers only; no MapStruct.
- No new tests.
