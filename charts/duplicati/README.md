# duplicati

Helm chart for [Duplicati](https://duplicati.com/), using the **official**
[`duplicati/duplicati`](https://hub.docker.com/r/duplicati/duplicati) image.

Not the linuxserver.io image — the two differ in ways that matter: the official
one takes `UID`/`GID` (not `PUID`/`PGID`) and keeps its configuration in `/data`
(`XDG_CONFIG_HOME`), not `/config`.

## Layout

| Path | Contents |
| --- | --- |
| `/data` | server database: backup definitions, schedules, encryption passphrases |
| `/source` | what you back up — mounted read-only by default |
| `/backups` | a local backup destination, if you use one instead of a remote backend |

Port 8200 serves the web UI and the API.

## Installing

A default install starts on its own — no Secret required, and `/data` is
persistent out of the box:

```sh
helm install duplicati ./duplicati -n backups --create-namespace
```

Duplicati will print a one-time sign-in link in the pod log. For anything beyond
a first look, give it credentials and something to back up:

```sh
kubectl create secret generic duplicati-secret -n backups \
  --from-literal=DUPLICATI__WEBSERVICE_PASSWORD='<ui password>' \
  --from-literal=SETTINGS_ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

```yaml
# my-values.yaml
auth:
  existingSecret: duplicati-secret

persistence:
  config:
    enabled: true          # the default
    size: 1Gi
    storageClassName: local-path
  source:
    enabled: true
    type: hostPath
    hostPath: /mnt/data/source
    hostPathType: Directory   # the default: refuse to start if it is missing
    readOnly: true

# hostPath data does not move with the pod, so pin it.
nodeSelector:
  kubernetes.io/hostname: k3s-node-1

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: backup.example.com
      paths:
        - path: /
          pathType: Prefix
```

## Things worth knowing

### `SETTINGS_ENCRYPTION_KEY` is not the UI password

It encrypts the server database so backend credentials are not stored in the
clear. Two consequences:

- Without it, anyone who can read the config volume can read your S3/B2/SSH
  credentials.
- **Losing it means losing that database.** Store it somewhere outside these
  backups — a key you can only recover by restoring the backup it protects is
  not a key you have.

Blank `auth.keys.encryptionKey` if you deliberately want the database
unencrypted; `NOTES.txt` will say so on every install.

### Allowed hostnames are computed for you

Duplicati rejects any request whose `Host` header it does not recognise, which
is the usual reason the UI will not open behind an Ingress. The chart builds
`DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES` from `localhost`, the Service's DNS
names, and every `ingress.hosts[].host`:

```
localhost;127.0.0.1;duplicati;duplicati.backups;duplicati.backups.svc;duplicati.backups.svc.cluster.local;backup.example.com
```

Set `env.DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES` to take over. If you do, keep
`localhost` in the list — the probes send that Host header deliberately, because
the kubelet would otherwise use the pod IP and get rejected. `"*"` disables the
check entirely, which upstream does not recommend.

### Running as UID/GID, not root

The image entrypoint (`run-as-user.sh`) only drops privileges when both `UID`
and `GID` are set:

```sh
if [[ -n "$UID" && -n "$GID" ]]; then
    ... chown -R "$UID:$GID" /opt/duplicati /data
    exec su duplicati -c "$@"
else
    exec "$@"        # still root
fi
```

The chart sets `UID: "1000"` / `GID: "1000"` in `env`. Because the container has
to start as root to run that `chown`, `runAsNonRoot: true` cannot be combined
with this approach.

What it does instead is drop every capability and add back only the six that
`run-as-user.sh` actually uses:

| Capability | Needed for |
| --- | --- |
| `CHOWN`, `FOWNER`, `DAC_OVERRIDE` | `chown -R` over `/data` and `/opt/duplicati` |
| `SETUID`, `SETGID` | `su` dropping to `UID:GID` |
| `AUDIT_WRITE` | `su` on this Debian-based image goes through PAM, which writes an audit record |

`allowPrivilegeEscalation: false` is safe alongside `su`: the process is already
root and moves *down*, which uses `SETUID`, not the setuid bit. The pod also runs
under `seccompProfile: RuntimeDefault`.

If a future image changes its entrypoint and the pod crashloops at start, comment
out `securityContext.capabilities` — do **not** go back to running as root.

The `chown -R` on `/data` runs on every start, so a large config volume adds a
little to boot time. That is also why this approach was chosen over pod-level
`runAsUser`: the image fixes existing ownership for you.

### hostPath must be pinned to a node

The chart refuses to render when `persistence.source.type` or
`persistence.backups.type` is `hostPath` and neither `nodeSelector` nor
`affinity` is set.

This is stricter than it looks, and deliberately so. If the pod moves to another
node, an auto-created empty `/source` means Duplicati backs up nothing, records
it as a **successful** version — and your retention policy then starts pruning
the versions that held real data. A backup tool failing quietly in the direction
of "everything is fine" is the worst possible failure mode, so the chart makes
you say which node the data lives on.

The second half of that guard is `hostPathType`:

| Value | Missing path behaves as |
| --- | --- |
| `Directory` (default for `source`) | the pod does not start |
| `DirectoryOrCreate` (default for `backups`) | the kubelet creates an empty directory |

`backups` differs because a backup *destination* legitimately does not exist yet
on the first deploy. A backup *source* never does.

Know the limit: `Directory` catches a wrong path and a directory that was never
created, but not a disk that failed to mount after a reboot — the mount point is
then a real, empty directory and passes the check. For that case add an
`initContainer` that looks for a marker file:

```yaml
initContainers:
  - name: assert-source-mounted
    image: busybox:1.36
    command: ["sh", "-c", "test -f /source/.mounted || { echo '/source is not the real volume'; exit 1; }"]
    volumeMounts:
      - name: source
        mountPath: /source
        readOnly: true
```

Check the first run before trusting it either way:

```sh
kubectl exec deploy/duplicati -n backups -- ls -la /source
```

### Probes

- **startupProbe** — up to 5 minutes. First boot runs database migrations; 0.18.x
  had no startup probe and default liveness settings, so a slow start was killed
  after roughly 30 seconds.
- **readinessProbe** — `httpGet /` with an explicit `Host: localhost`.
- **livenessProbe** — plain `tcpSocket`. A restart aborts whatever backup is
  running, so liveness only ever fires for a genuinely dead process, never for
  an HTTP detail like a rejected Host header.

`terminationGracePeriodSeconds` is 120 so a running backup can wind down.

### No autoscaling

0.18.x shipped an HPA using `autoscaling/v2beta1`, an API removed in Kubernetes
1.26 — `autoscaling.enabled: true` would have failed with `no matches for kind`
on any current cluster. It was also wrong in principle: `maxReplicas: 100` for a
tool whose entire state is one SQLite file on a ReadWriteOnce volume. Both the
template and the values are gone, and `replicaCount` above 1 is rejected.

### Rolling updates are rejected

`strategy.type: RollingUpdate` fails at render time whenever `/data` is a
chart-managed `ReadWriteOnce` claim. That is not pedantry:

- With one replica the default `maxUnavailable` rounds down to 0, so Kubernetes
  starts the new pod **before** stopping the old one.
- If it lands on another node you get a `Multi-Attach` error and an upgrade that
  hangs until it times out. Annoying, but visible.
- If it lands on the **same** node it succeeds, and that is the bad case:
  ReadWriteOnce is enforced per node, not per pod. Both pods mount the volume and
  two Duplicati processes write the same SQLite server database — the exact
  corruption the `replicaCount: 1` rule exists to prevent.

The check is skipped when `existingClaim` is set, because the real access mode
then lives outside these values and guessing would reject working setups. If your
volume genuinely is `ReadWriteMany`, say so in `accessModes` and `RollingUpdate`
is allowed.

### Rotating the Secret does not restart the pod

`auth.existingSecret` is read into environment variables once, at startup.
Changing a value in the Secret does nothing until the pod restarts, and the chart
cannot add a `checksum/secret` annotation for a Secret it does not own without
`lookup`, which breaks `helm template` and every GitOps dry run.

So after rotating either key:

```sh
kubectl rollout restart deploy/duplicati -n backups
```

### NetworkPolicy is not a firewall by default

Enabling `networkPolicy` with the default `ingressFrom: []` restricts the port
number and nothing else. A NetworkPolicy ingress rule with `ports` and no `from`
matches **every** source in the cluster, so port 8200 stays reachable from any
pod in any namespace. Name the callers you actually allow:

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Egress is left completely unrestricted while `egress: []` — the chart does not
even declare the `Egress` policyType, because declaring it with no rules denies
all outbound traffic. The moment you add one rule, everything else is denied,
DNS included. `allowDNS: true` (the default) appends the kube-system `:53`
UDP/TCP rule for you, and is ignored while `egress` is empty.

### Labels and annotations on everything

`commonLabels` and `commonAnnotations` are applied to every object the chart
renders. Two deliberate exclusions:

- `commonLabels` never reaches the **selector** labels. A Deployment's
  `spec.selector` is immutable, so folding arbitrary labels into it would turn
  every later upgrade into a hard failure.
- On a PVC, `persistence.*.retain` still wins. Setting
  `helm.sh/resource-policy` through `commonAnnotations` cannot switch off the
  volume protection by accident.

### Reinstalling after `helm uninstall`

`retain: true` puts `helm.sh/resource-policy: keep` on the PVC, so `helm
uninstall` leaves it behind — that is the point, it is what saves the data. The
cost is that the *next* `helm install` renders a PVC with the same name and
fails:

```
Warning: These resources were kept due to the resource policy:
  [PersistentVolumeClaim] duplicati-config
Error: persistentvolumeclaims "duplicati-config" already exists
```

Helm will adopt an existing object instead of failing, but only if its ownership
metadata matches the release being installed. Check what is actually on it:

```sh
kubectl get pvc duplicati-config -n backups -o jsonpath=\
'{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}{.metadata.annotations.meta\.helm\.sh/release-namespace}{"\n"}'
```

If those are not exactly `Helm`, the release name, and the namespace, stamp them
and install again — Helm then takes the volume over with its data intact:

```sh
kubectl label pvc duplicati-config -n backups \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate pvc duplicati-config -n backups \
  meta.helm.sh/release-name=duplicati \
  meta.helm.sh/release-namespace=backups --overwrite
```

Prefer `helm upgrade --install` over uninstall/install so this never comes up.
And if you drive Helm from Terraform, keep `atomic = false`: on a *failed
install* atomic uninstalls rather than rolls back, which produces exactly this
state on the following apply.

## Upgrading from 0.19.x

Nothing about storage naming moves: PVC names, `existingClaim`, `claimName` and
`retain` behave exactly as in 0.19.0, so an existing release keeps its volumes on
a plain `helm upgrade`. Three defaults do change.

**`persistence.config.enabled` is now `true`.** If your values file sets it
explicitly — either way — nothing happens. If it does not, and you were running
with it off, the upgrade creates a PVC and mounts it at `/data`, and Duplicati
starts from an empty configuration. Whatever was in `/data` was already lost on
every restart, so nothing that survived a restart is lost now, but the sign-in
link is reissued and any backup definitions from the current pod's lifetime are
gone. Export them first if you care:

```sh
kubectl exec deploy/duplicati -n backups -- ls -la /data
```

**`persistence.source.hostPathType` defaults to `Directory`.** A `hostPath`
source whose path does not exist on the pinned node now keeps the pod in
`ContainerCreating` instead of silently backing up an empty directory. That is
the point of the change, but it does turn a silent problem into a visible one —
so check the path exists before upgrading:

```sh
kubectl debug node/k3s-node-1 -it --image=busybox -- ls -la /host/mnt/data/source
```

Set `persistence.source.hostPathType: DirectoryOrCreate` to keep the old
behaviour. `backups` already defaults to `DirectoryOrCreate` and is unaffected.

**`strategy.type: RollingUpdate` is now rejected** over a chart-managed
ReadWriteOnce `/data` — see above. The chart default has always been `Recreate`,
so this only affects you if you overrode it.

Everything else is additive: `commonLabels`, `commonAnnotations`,
`networkPolicy.allowDNS`, `persistence.*.hostPathType`, `tests.image`,
`tests.runAsUser`, `TZ` in `env`, dropped capabilities and
`seccompProfile: RuntimeDefault`.

## Upgrading from 0.18.x

Four things were broken rather than merely rough:

- The Deployment declared `replicas` and `selector` **twice**. Helm installed it
  (the duplicate values were identical and yaml.v2 keeps the last one), but it
  fails under any strict validation — `kubectl apply`, ArgoCD/Flux, server-side
  apply.
- `envFromSecret.secretName` defaulted to `duplicati-secret` with four
  non-optional `secretKeyRef`s, so a fresh install died in
  `CreateContainerConfigError` unless you had already created a Secret with all
  four exact keys. Two of them — allowed-hostnames and timezone — are not
  secrets at all.
- `persistence.*.enabled` was ignored for `hostPath`: the volume was mounted
  whenever `type: hostPath`, enabled or not.
- The HPA used a removed API (see above).

**Resource names change.** 0.18.x hardcoded `nameOverride`/`fullnameOverride` to
`duplicati`, and the PVCs were literals (`pvc-duplicati-config`, `-source`,
`-backups`) that did not follow the release name at all. Both are fixed, so a
release named `duplicati` still produces `duplicati` — but its config PVC is now
`duplicati-config`, not `pvc-duplicati-config`.

**Keep the old PVC names before upgrading**, or Helm provisions empty ones and
Duplicati comes up with no backup configuration.

Use `claimName`, **not** `existingClaim`:

```yaml
persistence:
  config:
    enabled: true
    claimName: pvc-duplicati-config
  source:
    enabled: true
    claimName: pvc-duplicati-source
  backups:
    enabled: true
    claimName: pvc-duplicati-backups
```

The difference matters and gets this wrong in a way that destroys data:

| | Rendered by the chart? | Effect on a 0.18.x PVC |
| --- | --- | --- |
| `claimName: pvc-duplicati-config` | yes, with that name | Helm keeps managing the same object and patches it in place |
| `existingClaim: pvc-duplicati-config` | no | the PVC drops out of the release manifest, and **Helm deletes it on upgrade** — the 0.18.x PVCs carry no `helm.sh/resource-policy: keep` to stop that |

`existingClaim` is for volumes this chart never created. `claimName` is for
keeping one it did.

Before upgrading, take the safety net regardless — the annotation makes the PVC
survive even a mistaken `helm uninstall`:

```sh
kubectl get pvc -n backups
kubectl annotate pvc pvc-duplicati-config -n backups helm.sh/resource-policy=keep
```

Then check that the rendered spec still matches. `storageClassName` and
`accessModes` are immutable and the size can only grow, so if your values do not
match what is on the cluster the patch is rejected:

```sh
kubectl get pvc pvc-duplicati-config -n backups \
  -o jsonpath='{.spec.storageClassName}{"\n"}{.spec.accessModes}{"\n"}{.spec.resources.requests.storage}{"\n"}'
```

The Deployment selector is **unchanged** (`app.kubernetes.io/name` +
`app.kubernetes.io/instance`, and `duplicati.name` resolves to `duplicati`
either way), so a plain `helm upgrade` patches it in place. No orphan-delete
dance is needed here — unlike the transmission chart, where the selector really
did change.

Other values changes:

| 0.18.x | 0.19.0 |
| --- | --- |
| `namespace` | removed — use `helm --namespace` |
| `nameOverride`/`fullnameOverride` hardcoded | `""` |
| `autoscaling.*` | removed |
| `envFromSecret.*` (4 mandatory keys) | `auth.existingSecret` + `auth.keys` (2 keys, optional) |
| hostnames / timezone in the Secret | computed / `env` |
| `env`, `envFrom` (referenced, never defined) | real `env` map, `extraEnv` list, standard `envFrom` |
| `persistence.*.accessMode` (string) | `accessModes` (list) |
| `resources: {}` | requests + limits by default |
| PVC names hardcoded `pvc-duplicati-*` | `<fullname>-<volume>`, overridable with `claimName` |
| — | `existingClaim`, `claimName` and `retain` on all three volumes, `startupProbe`, PDB, NetworkPolicy |

`namespace` is gone because it was applied to only two of six templates
(Deployment and the PVCs). It happened to work as long as you also passed
`--namespace` with the same value, but nothing enforced that: diverge and the
pod cannot find its ServiceAccount and the Service has no endpoints.

## Testing a release

```sh
helm test duplicati -n backups
```

Fetches `/` through the Service — which also confirms the allowed-hostnames list
accepts the in-cluster DNS name. The test pod runs as `env.UID` so it does not
quietly pass under a user the real workload never uses; override with
`tests.runAsUser` and `tests.image`.

## Values

See [`values.yaml`](values.yaml); every key is commented inline, and
[`values.schema.json`](values.schema.json) validates the important ones at
install time.
