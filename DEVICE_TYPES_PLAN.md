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
{ "hasBattery": true, "hasWifi": false }
```

- `hasBattery` is meaningful on all four types (optional per physical unit).
- `hasWifi` is meaningful only on `BUS_STATION`. Bench wifi is always-present per requirements; WiFi AP is itself a wifi device.
- The detail page hides cards/metrics whose capability flag is false.

### Battery alarm

Add canonical metric role `batteryPercent`. Threshold rule: `< 15` → severity `WARNING`, alarm `LOW_BATTERY`. Applies only when `capabilities.hasBattery === true`.

## Per-device detail page — content matrix

| Card                                | Bench         | Trash bin     | Bus station                | WiFi AP       |
|-------------------------------------|---------------|---------------|----------------------------|---------------|
| Header (name, status, location, last seen) | ✓     | ✓             | ✓                          | ✓             |
| Fill level + alarm threshold        | —             | ✓             | —                          | —             |
| Lid access count (+ 7d sparkline)   | —             | ✓             | —                          | —             |
| Last emptied timestamp              | —             | ✓             | —                          | —             |
| Charging sessions (+ 7d sparkline)  | ✓             | —             | —                          | —             |
| WiFi access count (+ 7d sparkline)  | ✓             | —             | ✓ (if `hasWifi`)           | ✓             |
| Connected clients / throughput      | —             | —             | —                          | ✓             |
| Battery (current % + low-battery)   | if `hasBattery` | if `hasBattery` | if `hasBattery`        | if `hasBattery` |
| Telemetry chart                     | ✓             | ✓             | ✓                          | ✓             |

## Backend changes (`smartcity-be`)

1. **`DeviceKind.java`** — remove `CAMERA` enum value; drop the `CAMERA` case in `fromCategory(...)`.
2. **`CanonicalMetricRoles.java`** — add `public static final String BATTERY_PERCENT = "batteryPercent";`.
3. **`Device.java`** — add jsonb column:
   ```java
   @Type(JsonType.class)
   @Column(name = "capabilities", columnDefinition = "jsonb", nullable = false)
   private Map<String, Object> capabilities = Map.of();
   ```
4. **Flyway migration** `V<next>__device_capabilities_and_cleanup.sql`:
   - `ALTER TABLE devices ADD COLUMN capabilities jsonb NOT NULL DEFAULT '{}'::jsonb;`
   - Append low-battery threshold rule to existing `device_types` rows for the four kept categories.
   - Remove any `device_types` rows with `category = 'CAMERA'` (see open caveat).
5. **`ThresholdEvaluator.java`** — verify it picks up the new rule purely from `DeviceType.thresholdRules` without code change. Adjust only if the rule schema doesn't match.
6. **`DeviceMapper.java` / `DeviceController.java`** — include `capabilities` (and existing `lastTelemetry`) in the device DTO returned by `GET /api/devices/{id}`. Hand-written mapper, per project convention (no MapStruct).
7. **Readings endpoint** — `GET /api/devices/{id}/readings?metric=<role>&from=<iso>&to=<iso>` for the detail-page chart. Extend `SensorController` if a comparable endpoint exists; otherwise add to `DeviceController`.

## Frontend changes (`smartcity-fe`)

1. **`shared/types/smartcity.ts`**
   - `DeviceType` union → `'SMART_BENCH' | 'SMART_BIN' | 'SMART_BUS_STATION' | 'SMART_WIFI_AP' | string` (drop `SMART_TRASH_BIN` and `CAMERA`).
   - `DeviceKind` → drop `'camera'`.
   - `Device` → add `capabilities?: { hasBattery?: boolean; hasWifi?: boolean }`.

2. **New route** — `app/[locale]/(app)/devices/[id]/page.tsx`. Fetches the device, branches on `deviceTypeCategory` to render the right panel.

3. **New components** under `features/devices/components/detail/`:
   - `DeviceDetailHeader.tsx` — name, status pill, location, last seen, online indicator.
   - `BatteryCard.tsx` — shown only when `capabilities.hasBattery`; current %, low-battery state at < 15%.
   - `TrashBinPanel.tsx` — fill-level gauge, alarm threshold, lid-access total + sparkline, last-emptied.
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
