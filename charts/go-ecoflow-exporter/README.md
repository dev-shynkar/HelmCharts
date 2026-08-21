# go-ecoflow-exporter

Helm chart for [go-ecoflow-exporter](https://github.com/tess1o/go-ecoflow-exporter),
a Prometheus exporter for EcoFlow power stations.

## Two collection modes

| | `mqtt` | `rest` |
| --- | --- | --- |
| Credentials | EcoFlow account email + password | developer access key + secret key |
| Freshness | pushed by the broker, near real-time | polled every `scrapingIntervalSeconds` |
| Device list | **required** | optional (discovered via the API) |

Both serve `/metrics` on port 2112. Prometheus output is always enabled — see
[Why there is no `prometheus.enabled`](#why-there-is-no-prometheusenabled).

## Installing

Credentials come from a Secret you create yourself; the chart never renders one,
so they stay out of your values file and out of Helm's release storage.

```sh
kubectl create namespace monitoring

# MQTT mode
kubectl create secret generic go-ecoflow-exporter -n monitoring \
  --from-literal=ECOFLOW_EMAIL=you@example.com \
  --from-literal=ECOFLOW_PASSWORD='...'

helm install ecoflow ./go-ecoflow-exporter -n monitoring -f my-values.yaml
```

```yaml
# my-values.yaml
exporter:
  type: mqtt
  devices:
    - R33XXXXXXXXX
  devicesPrettyNames:
    R33XXXXXXXXX: Delta 2

serviceMonitor:
  enabled: true
  labels:
    # kube-prometheus-stack's serviceMonitorSelector usually requires this.
    release: kube-prometheus-stack
```

For REST mode use `ECOFLOW_ACCESS_KEY` / `ECOFLOW_SECRET_KEY` instead and set
`exporter.type: rest`.

If your Secret uses different key names (External Secrets, SOPS, a shared
credentials Secret), remap them rather than renaming the Secret's contents:

```yaml
existingSecret:
  name: ecoflow-shared
  keys:
    email: ecoflow-username
    password: ecoflow-password
```

Or skip `existingSecret` entirely and inject everything with `envFrom`:

```yaml
existingSecret:
  name: ""
envFrom:
  - secretRef:
      name: ecoflow-credentials
```

## Getting Prometheus to scrape it

Nothing scrapes the exporter out of the box. Pick one:

```yaml
serviceMonitor:
  enabled: true              # Prometheus Operator / kube-prometheus-stack
```

```yaml
prometheusScrapeAnnotations:
  enabled: true              # plain Prometheus with annotation-based discovery
```

The Service port is named `metrics`, and the ServiceMonitor selects it by name.

## Things worth knowing

### The probes cannot tell you the collector is healthy

`/metrics` is the only route the exporter serves, and `enablePrometheus()`
starts that HTTP server *before* the MQTT/REST collector connects. A 200 means
the process is alive — nothing more. If the connection to EcoFlow dies, the
endpoint keeps returning 200 with stale or empty metrics, and the liveness probe
will never notice.

There is no `/health` endpoint upstream, so this is a limitation of the app, not
something the chart can work around. Alert on the data instead:

```yaml
- alert: EcoflowExporterNoData
  expr: absent(ecoflow_online)
  for: 10m

- alert: EcoflowDeviceOffline
  expr: ecoflow_online == 0
  for: 15m
```

### The MQTT collector can wedge permanently

**Symptom:** metrics work after deploy. You switch the station off, switch it
back on some time later, and metrics never return. Restarting the pod fixes it
immediately.

This is an upstream bug, not a chart misconfiguration. Three things combine:

1. `monitorDeviceStatus()` treats "every device is offline" as "the broker
   connection is broken". Switching the station off triggers exactly that, so
   the exporter tears down a perfectly healthy connection:

   ```go
   m.c.Client.Disconnect(250)
   time.Sleep(5 * time.Second)
   m.c.Client.Connect()   // token discarded, error never checked
   ```

2. The MQTT credentials are fetched **once**, at process start
   (`getMqttCredentials` inside `NewMqttClient`). They are short-lived
   `/iot-auth/app/certification` credentials, and every reconnect — paho's
   automatic one and the forced one above — reuses them. Once they expire, no
   reconnect can ever succeed for the life of the process.

3. Recovery is then impossible from inside the process. Both
   `monitorDeviceStatus()` and `startPingRoutine()` open with
   `if !m.c.Client.IsConnected() { continue }`, so once the client is down the
   reconnect branch is never reached again. paho 1.4.3 compounds it: `Connect()`
   returns a fake success without doing anything whenever the client's status is
   not exactly `disconnected`.

A pod restart works because it re-runs the EcoFlow login and gets fresh
credentials.

**Diagnosing it.** Set `debug.enabled=true` and look at what follows
`All devices are either offline or we don't receive messages from MQTT topic`:

| Log | Meaning |
| --- | --- |
| `Trying to reconnect to the broker...` repeatedly, never `Connected to the broker` | expired credentials (cause 2) |
| nothing at all | client wedged (causes 1 + 3) |
| `Connected to the broker` and `Subscribed to receive parameters`, still no data | different problem — subscription or topic |

Note the exporter never installs paho's loggers (they default to `NOOPLogger`),
so MQTT-level errors are invisible no matter what log level you set.

**Working around it from the chart:**

```yaml
mqttStallRecovery:
  enabled: true
  afterMinutes: 15
```

This replaces the liveness probe with an exec probe that also fails when no
device has been online for `afterMinutes`, so the kubelet performs the restart
for you:

```sh
wget -q -O - http://127.0.0.1:2112/metrics \
  | awk '/^ecoflow_online[{ ]/ && $NF != 0 { ok = 1 } END { exit ok ? 0 : 1 }'
```

It passes as long as **at least one** device is online, matching the upstream
condition — one device of several being genuinely off will not trigger a restart.

The trade-off: while your station is genuinely switched off, the pod restarts
every `afterMinutes`. There is nothing to scrape during that time either way, so
the cost is log noise and a restart counter, but raise `afterMinutes` if it
bothers you.

Separately, `exporter.mqtt.deviceOfflineThresholdSeconds` now defaults to 180
instead of 30. That check runs once per threshold, so the old value ran the
destructive disconnect/reconnect path every 30 seconds for as long as the
station was off, thrashing the connection and hammering EcoFlow's API.

### One replica

Each replica logs into EcoFlow independently and reports the same devices. The
MQTT client IDs are random UUIDs (`ANDROID_<uuid>_<userId>`), so nothing
disconnects anything else — you simply get duplicate series and twice the API
load. `updateStrategy` is `Recreate` for the same reason: a rolling update would
briefly run two collectors.

### Credential rotation restarts the pod

The exporter reads its environment once at startup, so the Deployment carries a
`checksum/secret` annotation derived from the referenced Secret's **contents**
(via `lookup`). Update the Secret, run `helm upgrade`, and the pod rolls.

One caveat: `lookup` returns nothing during `helm template` and `--dry-run`, so
the annotation renders as `not-found` there. `helm diff` will show it as a change
on every run against a cluster where the Secret exists — expected, not a bug.

### Device serial numbers are not secret

`exporter.devices` and `exporter.devicesPrettyNames` live in values. When both
are empty the chart falls back to the `ECOFLOW_DEVICES` /
`ECOFLOW_DEVICES_PRETTY_NAMES` keys of the Secret (marked `optional: true`), so
older installs that put them there keep working.

Unlike chart 0.8.x, these apply to **both** modes. REST mode calls the same
`getDeviceMapping()` internally, which is where pretty names come from there.

### Why there is no `prometheus.enabled`

`main.go` exits with code 1 when no metric handler is registered:

```go
if len(handlers) == 0 {
	slog.Error("No metric handlers enabled...")
	os.Exit(1)
}
```

This chart wires up only the Prometheus handler, so `prometheus.enabled: false`
could do exactly one thing: put the pod in `CrashLoopBackOff`. The value is gone
and `PROMETHEUS_ENABLED=true` is now hardcoded.

The exporter also supports TimescaleDB and Redis sinks. Those are out of scope
here — this chart is a Prometheus exporter.

## Upgrading from 0.8.x

Four things in 0.8.x looked configured but were not:

- `DEBUG` was sent; the app reads `DEBUG_ENABLED`. Debug logging never worked.
- `serviceAccountName` was omitted entirely when `serviceAccount.create: false`,
  so a custom `serviceAccount.name` was ignored and the pod ran as `default`.
- `checksum/secret` hashed the Secret's *name* — a constant — so credential
  rotation never restarted the pod.
- `existingSecret.enabled`, `exporter.devices` and `exporter.devicesPrettyNames`
  were never referenced by any template.

Values changes:

| 0.8.x | 0.9.0 |
| --- | --- |
| `prometheus.enabled` | removed, always true |
| `existingSecret.enabled` | removed, was dead |
| `exporter.devices: "A,B"` (string) | `exporter.devices: [A, B]` (list) |
| `exporter.devicesPrettyNames: '{"A":"x"}'` | `exporter.devicesPrettyNames: {A: x}` (map) |
| `securityContext` (pod-level fields mixed in) | `podSecurityContext` + `securityContext` |
| — | `existingSecret.keys.*`, `serviceMonitor.*`, `nameOverride`/`fullnameOverride` |

**Resource names change.** `fullname` used to be just the release name; it is now
the standard `<release>-<chart>`. A release named `ecoflow` goes from `ecoflow`
to `ecoflow-go-ecoflow-exporter`. To keep the old names:

```yaml
fullnameOverride: ecoflow
```

Also note `readOnlyRootFilesystem` is now `true` (safe — the exporter is a static
`CGO_ENABLED=0` binary that writes nothing to disk) and `automountServiceAccountToken`
is `false`.

## Testing a release

```sh
helm test ecoflow -n monitoring
```

Fetches `/metrics` through the Service and checks it is valid exposition format.
It deliberately does not assert on device metrics — those only appear after the
collector's first successful cycle.

## Values

See [`values.yaml`](values.yaml); every key is commented inline, and
[`values.schema.json`](values.schema.json) validates the important ones at
install time.
