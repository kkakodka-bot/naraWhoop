# Temporary experiment event recorder

The Today screen (classic and liquid layouts) has an Event recorder card. Choose
an activity or enter a custom name under Other, tap Start, then tap Stop. Only
one event can be active. Starting/stopping labels does not control the sensors.
An unfinished event remains active across navigation, backgrounding and relaunch;
the user must stop it explicitly. Record quiet-rest examples as well as activities.

Tap Export, then Share JSON to share a snapshot of all labels, including any
unfinished event. A later start/stop invalidates the prepared share snapshot.
Labels are local to this app installation; there is no cloud synchronization.

The durable sidecar is `Library/Application Support/OpenWhoop/experiment-events.json`,
alongside the sensor database. It is a JSON array containing:

- `id`: stable event UUID
- `label`: selected activity or trimmed custom text
- `deviceId`: BLE device identity captured when Start was tapped
- `startUnixSeconds` / `endUnixSeconds`: UTC Unix seconds with fractional precision;
  an unfinished event has no end field
- `timeZoneIdentifier`: phone time zone at start, for display/provenance
- `source`: `manual_experiment`

The sidecar is independent of the existing SQLite export; include it explicitly
when retrieving sensor data, or use the card's Share JSON action. Export preserves
incomplete intervals for review; do not treat them as completed training examples.
Phone tap times need alignment checks against strap acquisition timestamps. Each
event is an independent episode for splitting training and evaluation data.

Writes are atomic and precede UI state changes. A failed write displays an error
and leaves the previous event state intact. Unreadable existing labels are not
overwritten. The recorder creates no timer, network request or background task.

Run the persistence checks from the repository root:

```sh
swiftc Strand/Data/ExperimentEventLog.swift scripts/test_experiment_event_log.swift -o /tmp/noop-event-log-test
/tmp/noop-event-log-test
```

To remove the temporary UI, remove the single `ExperimentEventRecorder()` call
in each Today layout. The saved sidecar can remain for later analysis.
