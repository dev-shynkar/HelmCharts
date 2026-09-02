# transmission

Helm chart for [Transmission](https://transmissionbt.com/) using the
[linuxserver.io image](https://github.com/linuxserver/docker-transmission).

## Ports

| Port | Purpose | How this chart exposes it |
| --- | --- | --- |
| 9091 | web UI / RPC | Service (+ optional Ingress) |
| 51413 TCP | BitTorrent peers | `hostPort` on the node |
| 51413 UDP | DHT and µTP | `hostPort` on the node |

The peer port is the one that matters for performance. Without it Transmission
can only open outgoing connections: seeding barely works and download speeds are
a fraction of what they should be. A ClusterIP Service cannot help here — those
connections come from the internet — so the chart binds the port on the node
itself.

**You still have to forward it on your router**, TCP *and* UDP, to the LAN
address of the node running the pod. Forwarding only TCP leaves DHT and µTP
broken. Verify from the web UI: Preferences → Network shows "Port is open".

## Installing

```sh
kubectl create secret generic transmission-auth -n media \
  --from-literal=USER=admin --from-literal=PASS='<pick one>'

helm install transmission ./transmission -n media -f my-values.yaml
```

```yaml
# my-values.yaml
auth:
  existingSecret: transmission-auth

# hostPath data does not move with the pod, so pin it.
nodeSelector:
  kubernetes.io/hostname: k3s-node-1

persistence:
  config:
    enabled: true
    size: 1Gi
    storageClassName: local-path
    # Reuse a PVC you already have instead of letting the chart create one.
    # Required when migrating from 0.3.x under a release name other than
    # "transmission" — otherwise the chart provisions a fresh, empty PVC and
    # Transmission forgets every torrent. See "Upgrading from 0.3.x".
    # existingClaim: transmission-config
  downloads:
    enabled: true
    type: hostPath
    hostPath: /media/k3s-data
```

## Things worth knowing

### The web UI has no authentication by default

The linuxserver.io image enables RPC auth only when both `USER` and `PASS` are
set. Until then anyone who can reach port 9091 can add torrents and browse the
filesystem through the UI. **Do not enable the Ingress without `auth.existingSecret`.**

Two optional hardening variables, both unset by default:

```yaml
env:
  # Restrict RPC to these addresses (rpc-whitelist).
  WHITELIST: "127.0.0.1,10.0.0.0/8,192.168.0.0/16"
  # Restrict the accepted Host header (rpc-host-whitelist), anti DNS-rebinding.
  HOST_WHITELIST: "transmission.example.com"
```

`HOST_WHITELIST` being unset is why an Ingress with a custom hostname works out
of the box. Note that enabling password auth also makes Transmission accept any
hostname.

### hostPath downloads must be pinned to a node

The chart refuses to render when `persistence.downloads.type: hostPath` and
neither `nodeSelector` nor `affinity` is set. This is deliberate: hostPath data
stays on one machine, but the scheduler is free to move the pod. When it does,
an auto-created empty directory on the new node makes every torrent look lost —
then reappear if the pod ever lands back on the original.

The second half of that guard is `hostPathType`:

| Value | Missing path behaves as |
| --- | --- |
| `Directory` (default for `downloads`) | the pod does not start |
| `DirectoryOrCreate` (default for `watch`) | the kubelet creates an empty directory |

`watch` differs because it is a drop folder that holds no data of its own — an
empty one is the normal state. A downloads directory never is.

Know the limit: `Directory` catches a wrong path and a directory that was never
created, but not a disk that failed to mount after a reboot — the mount point is
then a real, empty directory and passes the check. For that case add an
`initContainer` that looks for a marker file:

```yaml
initContainers:
  - name: assert-downloads-mounted
    image: busybox:1.36
    command: ["sh", "-c", "test -f /downloads/.mounted || { echo '/downloads is not the real volume'; exit 1; }"]
    volumeMounts:
      - name: downloads
        mountPath: /downloads
```

With `DirectoryOrCreate`, Kubernetes creates the directory as `root:root` 0755,
which UID 1000 cannot write to. If downloads fail with permission errors:

```sh
sudo chown -R 1000:1000 /media/k3s-data
```

Use `type: pvc` with a real storage class if you would rather not deal with this.

### Recreate, not RollingUpdate

`/config` is a ReadWriteOnce volume and the peer port is an exclusive hostPort.
A rolling update would have the new pod waiting for both while the old pod still
holds them — a deadlock. `replicaCount` above 1 is rejected for the same reason.

Since 0.5.0 this is enforced rather than merely defaulted: `updateStrategy.type:
RollingUpdate` fails at render time whenever either half applies.

- **hostPort** — with one replica the default `maxUnavailable` rounds down to 0,
  so the new pod starts before the old one stops and can never bind port 51413.
  Always checked while `peerPort.hostPort` is on.
- **ReadWriteOnce `/config`** — landing on another node gives a `Multi-Attach`
  error. Landing on the **same** node is worse and silent: ReadWriteOnce is
  enforced per node, not per pod, so both pods mount `/config` and two
  Transmission processes write the same `settings.json` and resume files.
  Skipped when `existingClaim` is set, because the real access mode then lives
  outside these values.

### Rotating the auth Secret does not restart the pod

`USER` and `PASS` are read into environment variables once, at startup. Changing
them in the Secret does nothing until the pod restarts, and the chart cannot add
a `checksum/secret` annotation for a Secret it does not own without `lookup`,
which breaks `helm template` and every GitOps dry run.

```sh
kubectl rollout restart deploy/transmission -n <ns>
```

### NetworkPolicy

Off by default. Enabling it with the default `ingressFrom: []` restricts the port
number and nothing else — a NetworkPolicy ingress rule with `ports` and no `from`
matches **every** source in the cluster. Name the callers you actually allow:

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Only the web UI / RPC port is covered. The BitTorrent peer port arrives on the
node through the `hostPort`, not through the cluster network, so no
NetworkPolicy governs it either way — that is your router's job.

Egress is left completely unrestricted while `egress: []`; the chart does not
even declare the `Egress` policyType, because declaring it with no rules denies
all outbound traffic. Restricting egress on a torrent client is mostly pointless
anyway — it has to reach arbitrary peers on arbitrary ports, so any workable rule
ends up allowing `0.0.0.0/0`. The real use case is a VPN sidecar, where you want
to allow only the tunnel. `allowDNS: true` (the default) appends the kube-system
`:53` rule for you and is ignored while `egress` is empty.

### Labels and annotations on everything

`commonLabels` and `commonAnnotations` are applied to every object the chart
renders. Two deliberate exclusions:

- `commonLabels` never reaches the **selector** labels. A Deployment's
  `spec.selector` is immutable, so folding arbitrary labels into it would turn
  every later upgrade into a hard failure.
- On a PVC, `persistence.*.retain` still wins. Setting `helm.sh/resource-policy`
  through `commonAnnotations` cannot switch off the volume protection.

### Probes use tcpSocket, not httpGet

Transmission checks authorization *before* it redirects `/` to the web UI
([`rpc-server.cc`](https://github.com/transmission/transmission/blob/4.0.6/libtransmission/rpc-server.cc)),
so an `httpGet /` probe starts returning 401 the moment you set `USER`/`PASS`.
A TCP check proves the RPC server is listening either way. `/transmission/rpc`
is no better — it answers 409 without a session id, which probes treat as
failure.

There are three probes since 0.5.0: a `startupProbe` gives a large torrent list
up to 5 minutes to load before liveness is allowed to fire at all, then readiness
and liveness take over. `terminationGracePeriodSeconds: 90` gives Transmission
room to write its resume files on shutdown instead of being killed mid-write and
re-verifying on the next start.

### Image version

`appVersion` is pinned at **4.0.6** while linuxserver.io ships 4.1.x. That tag
still exists in the registry, so nothing breaks, but it no longer receives
base-image security updates.

Moving up is a deliberate choice — Transmission 4.1 rewrites `settings.json`, so
back up `/config` first:

```yaml
image:
  tag: "4.1.3-r0-ls358"
```

Prefer the full `<version>-r<n>-ls<build>` form over a bare `4.1.3`, which
floats.

### Hardening

The image runs as root under s6-overlay and drops to `PUID`/`PGID` itself, so
`runAsNonRoot: true` will not work as-is. Since 0.5.0 the chart drops every
capability and adds back only what s6-overlay needs:

| Capability | Needed for |
| --- | --- |
| `CHOWN`, `FOWNER`, `FSETID`, `DAC_OVERRIDE` | chowning `/config` to `PUID:PGID` |
| `SETUID`, `SETGID`, `SETFCAP`, `SETPCAP` | `s6-setuidgid` dropping privileges |
| `KILL` | `s6-svscan` supervising its services |
| `AUDIT_WRITE` | the audit record PAM writes |

What that actually buys you is the capabilities *not* in the list — above all
`NET_RAW` (raw sockets), plus `MKNOD`, `SYS_CHROOT` and `NET_BIND_SERVICE`. Both
ports this chart uses are above 1024, so nothing needs to bind low.

The set is wider than the duplicati chart's because s6-overlay does more at
startup than a single chown plus `su`. **This is the one change in 0.5.0 that can
stop an otherwise-working pod.** If it crashloops at start, comment out
`securityContext.capabilities` and nothing else:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false
  # capabilities: ...
```

Do not go back to running as root instead. The pod also runs under
`seccompProfile: RuntimeDefault`.

linuxserver.io documents both [read-only](https://docs.linuxserver.io/misc/read-only/)
and [non-root](https://docs.linuxserver.io/misc/non-root/) operation if you want
to go further.

### VPN sidecar

`sidecars` and `initContainers` are passthrough lists, so a gluetun sidecar fits
here. Remember that routing Transmission through a VPN means the peer `hostPort`
no longer receives anything — you would use the VPN provider's forwarded port
instead.

### Reinstalling after `helm uninstall`

`retain: true` puts `helm.sh/resource-policy: keep` on the PVC, so `helm
uninstall` leaves it behind — that is the point, it is what saves the data. The
cost is that the *next* `helm install` renders a PVC with the same name and
fails:

```
Warning: These resources were kept due to the resource policy:
  [PersistentVolumeClaim] transmission-config
Error: persistentvolumeclaims "transmission-config" already exists
```

Helm will adopt an existing object instead of failing, but only if its ownership
metadata matches the release being installed. Check what is actually on it:

```sh
kubectl get pvc transmission-config -n media -o jsonpath=\
'{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}{.metadata.annotations.meta\.helm\.sh/release-namespace}{"\n"}'
```

If those are not exactly `Helm`, the release name, and the namespace, stamp them
and install again — Helm then takes the volume over with its data intact:

```sh
kubectl label pvc transmission-config -n media \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate pvc transmission-config -n media \
  meta.helm.sh/release-name=transmission \
  meta.helm.sh/release-namespace=media --overwrite
```

Prefer `helm upgrade --install` over uninstall/install so this never comes up.
And if you drive Helm from Terraform, keep `atomic = false`: on a *failed
install* atomic uninstalls rather than rolls back, which produces exactly this
state on the following apply.

## Upgrading from 0.4.x

Storage naming does not move: PVC names, `existingClaim`, `claimName` and
`retain` behave exactly as in 0.4.0, so an existing release keeps its volumes on
a plain `helm upgrade`. But there is one thing to check afterwards, and two
default changes.

### The leftover PVC template — check your claim after upgrading

0.4.x shipped `templates/pvc.yaml` alongside `pvc-config.yaml` and
`pvc-downloads.yaml`. It rendered the same two claims a second time, and its copy
was the poorer one:

| | `pvc-config.yaml` | the leftover `pvc.yaml` |
| --- | --- | --- |
| `helm.sh/resource-policy: keep` | per `retain` | **absent** |
| labels | yes | absent |
| `accessModes` | from values | hardcoded `ReadWriteOnce` |
| `existingClaim` | skips rendering | ignored — created it anyway |

Helm orders manifests of one kind by file path, so `pvc.yaml` was applied last
and its annotation-free version won. On a fresh install the duplicate failed
outright with `persistentvolumeclaims "transmission-config" already exists`; on
an upgrade it quietly stripped the protection `retain: true` is there to provide.

The file is gone in 0.5.0. **Verify the annotation is back on your live claim**,
because the last 0.4.x upgrade removed it:

```sh
kubectl get pvc transmission-config -n <ns> \
  -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}{"\n"}'
```

Empty output means the volume is currently unprotected. A `helm upgrade` to
0.5.0 puts it back; if you want it protected *before* upgrading:

```sh
kubectl annotate pvc transmission-config -n <ns> helm.sh/resource-policy=keep
```

### `persistence.downloads.hostPathType` defaults to `Directory`

A hostPath downloads directory that does not exist on the pinned node now keeps
the pod in `ContainerCreating` instead of silently presenting an empty
`/downloads`. Check the path exists before upgrading:

```sh
kubectl debug node/k3s-node-1 -it --image=busybox -- ls -la /host/media/k3s-data
```

Set `persistence.downloads.hostPathType: DirectoryOrCreate` to keep the old
behaviour. `watch` defaults to `DirectoryOrCreate` and is unaffected.

### Capabilities are now dropped

See "Hardening" above. This is the change most likely to need a rollback, and it
is a one-line one.

Everything else is additive: `NetworkPolicy`, `commonLabels`,
`commonAnnotations`, `startupProbe`, `terminationGracePeriodSeconds: 90`,
`persistence.watch.claimName`, `tests.image`, `tests.runAsUser`, and a
`RollingUpdate` guard that only fires on a setting the chart never defaulted to.

## Upgrading from 0.3.x

**Resource names change.** 0.3.x hardcoded `nameOverride`/`fullnameOverride` to
`transmission`, so every release produced identically named objects with an
identical `app: transmission` selector — a second release in the same namespace
would collide, and two Deployments could fight over the same pods. Both are now
`""`, so a release named `transmission` produces `transmission` (unchanged) but
a release named `media` now produces `media-transmission`.

This matters most for the **config PVC**. Downloads on a hostPath are keyed by
the filesystem path, so they are unaffected — but `/config` holds `settings.json`,
the torrent list and all resume data. Under a new name the chart provisions a
fresh, empty PVC, and Transmission comes up knowing about none of your torrents
even though the files are still on disk.

Either keep the old names:

```yaml
fullnameOverride: transmission
```

or keep the new names and keep the old volume:

```yaml
persistence:
  config:
    enabled: true
    claimName: transmission-config
```

Use `claimName`, **not** `existingClaim` — the difference destroys data if you
get it backwards:

| | Rendered by the chart? | Effect on a 0.3.x PVC |
| --- | --- | --- |
| `claimName: transmission-config` | yes, with that name | Helm keeps managing the same object and patches it in place |
| `existingClaim: transmission-config` | no | the PVC drops out of the release manifest, and **Helm deletes it on upgrade** — the 0.3.x PVCs carry no `helm.sh/resource-policy: keep` to stop that |

`existingClaim` is for volumes this chart never created. `claimName` is for
keeping one it did.

Take the safety net before upgrading either way:

```sh
kubectl get pvc -n media
kubectl annotate pvc transmission-config -n media helm.sh/resource-policy=keep
```

`storageClassName` and `accessModes` are immutable and the size can only grow,
so make sure your values still match what is on the cluster:

```sh
kubectl get pvc transmission-config -n media \
  -o jsonpath='{.spec.storageClassName}{"\n"}{.spec.accessModes}{"\n"}{.spec.resources.requests.storage}{"\n"}'
```

The pod template keeps an `app: <name>` label alongside the standard
`app.kubernetes.io/*` set, so existing dashboards and NetworkPolicies still
match. The Deployment **selector** did change, though, and selectors are
immutable: `helm upgrade` will fail with `field is immutable`. Delete the old
Deployment first, keeping the PVCs:

```sh
kubectl delete deployment transmission -n media --cascade=orphan
helm upgrade transmission ./transmission -n media -f my-values.yaml
```

Other values changes:

| 0.3.x | 0.4.0 |
| --- | --- |
| `namespace` | removed — use `helm --namespace` |
| `nameOverride`/`fullnameOverride` hardcoded | `""` |
| `resources: {}` | requests + limits by default |
| — | `peerPort.*`, `auth.*`, `serviceAccount.*`, `persistence.watch.*` |
| — | `persistence.*.existingClaim`, `accessModes`, `retain` |
| `persistence.downloads.size` (undocumented) | documented, default 10Gi |

The `namespace` value is gone because `metadata.namespace` in a template
overrides where objects land while Helm still records the release against
`--namespace` — so `helm uninstall` would leave the objects behind.

## Testing a release

```sh
helm test transmission -n media
```

Checks that the RPC endpoint answers over HTTP (409 or 401 both count — they
prove the server is up). The test pod runs as `env.PUID` so it does not quietly
pass under a user the real workload never uses; override with `tests.runAsUser`
and `tests.image`.

## Values

See [`values.yaml`](values.yaml); every key is commented inline, and
[`values.schema.json`](values.schema.json) validates the important ones at
install time.
