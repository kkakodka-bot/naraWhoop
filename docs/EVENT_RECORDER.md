# Experiment event recorder

The Today screen (classic and liquid layouts) includes an Event recorder card for
marking ground-truth activities without controlling the sensors. Built-in and
saved custom events appear as one-tap tiles. Use **New event** to enter a custom
name and optional note, and optionally save the name as another quick tile.

Only one event can be active. Its timer and draft note remain available across
navigation, backgrounding, and relaunch; stop it explicitly to complete the
interval. Recent completed events can be renamed, edited, or deleted. Custom quick
tiles can also be removed without deleting events that already use that label.

## Local persistence and export

The durable sidecar is
`Library/Application Support/OpenWhoop/experiment-events.json`, alongside the
sensor database. Writes are atomic and precede UI state changes. A failed write
displays an error and leaves the previous state intact; unreadable existing data
is never overwritten.

The current versioned document contains `schemaVersion`, `events`, and
`customLabels`. Each event has:

- `id`: stable event UUID
- `label`: activity name
- `note`: optional free-text context
- `deviceId`: BLE device identity at start, or the installation source identity
  when no strap identity is available
- `startUnixSeconds` / `endUnixSeconds`: UTC Unix seconds with fractional precision;
  an active event has no end time
- `timeZoneIdentifier`: phone time zone at start
- `source`: `manual_experiment`

Legacy bare event arrays are migrated when read. **Share JSON** creates a
versioned, timestamped snapshot without changing the saved log. Incomplete
intervals are retained for review and should not be treated as completed training
examples.

## Cloud upload

**Upload now** uses the existing opt-in Cloud Push worker. Under push protocol
1.2, the recorder contributes the file-backed `eventLabel` stream. The sender
uploads bounded authoritative UTC-day snapshots for each device identity, so
renamed and deleted events converge remotely as well as new events without a
whole-history size ceiling. The receiver projects
these rows into `noop_event_labels`, preserving the stable event identity, note,
time zone, source, batch, and installation provenance.

The Supabase migration and Edge Function changes must be deployed before the
receiver advertises `eventLabel`. Until then the stream remains local and its push
progress is retained. Cloud Push credentials, cadence, retry behavior, and status
are shared with the existing upload feature; the recorder creates no separate
background task or network client.

Phone tap times still need alignment checks against strap acquisition timestamps.
Each event is an independent episode when splitting training and evaluation data.

Run the persistence checks from the repository root:

```sh
swiftc Strand/Data/ExperimentEventLog.swift scripts/test_experiment_event_log.swift -o /tmp/noop-event-log-test
/tmp/noop-event-log-test
```
