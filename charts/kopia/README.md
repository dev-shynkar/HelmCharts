# kopia

Helm chart for [Kopia](https://kopia.io/): it snapshots local paths into an
SFTP repository, incrementally, with optional web UI.

Built for the case this repository actually has: a few hundred gigabytes of
photos and video on a node, pushed to a NAS over SSH.

## Two modes

```yaml
mode: cronjob   # or: server
```

| | `cronjob` (default) | `server` |
| --- | --- | --- |
| What runs | a CronJob on `schedule` | one long-running `kopia server` |
| Sources | `sources` in values.yaml | picked in the UI, from what is mounted |
| Schedule | Kubernetes cron | Snapshot Frequency, per source, in the UI |
| Retention, compression | values.yaml, rewritten every run | the UI owns them |
| A failed backup looks like | a Job in state `Failed` | a line in a pod log; the pod stays `Ready` |
| Web UI | optional, read-only | always, writable |
| Verification | `verify.enabled` — a CronJob, in both modes | same |

`server` is the KopiaUI-on-Windows experience: browse, add a directory, pick a
frequency. `cronjob` trades that for a failure you can alert on.

One limit applies to both, and it is Kubernetes rather than kopia: **a container
only sees what is mounted into it.** Mount the whole data disk and every
subdirectory under it becomes selectable in the UI; anything outside it needs a
values change either way.

## Layout

| Path | Contents |
| --- | --- |
| `/sources/<name>` | one **read-only** mount per entry in `sources`. Use `mountPath` to keep the node's own path |
| `/restore` | the one **writable** mount, when `restore.enabled` — where UI restores land |
| `/kopia` | repository config file and the content/metadata caches (`stateDir`) |
| `/kopia-ssh` | private key and `known_hosts`, projected from the auth Secret |
| `/tmp` | scratch space and kopia's log directory (emptyDir) |
| `/scripts` | the generated script |

The official `kopia/kopia` image has `ENTRYPOINT ["/bin/kopia"]`, so the chart
replaces `command` to run its own script instead.

## Installing

Everything lives in one Secret you create yourself. The chart never generates
or stores a credential.

```sh
ssh-keygen -t ed25519 -N '' -f ./kopia_key
ssh-copy-id -i ./kopia_key.pub backup@nas.example.com
ssh-keyscan -p 22 nas.example.com > ./known_hosts

kubectl create secret generic kopia-secret -n backups \
  --from-literal=KOPIA_PASSWORD="$(openssl rand -base64 32)" \
  --from-file=id_ed25519=./kopia_key \
  --from-file=known_hosts=./known_hosts
```

`KOPIA_PASSWORD` encrypts the repository. **There is no recovery path if you
lose it** — the snapshots become permanently unreadable. Store it somewhere
that is not backed up by this chart.

```yaml
# my-values.yaml
auth:
  existingSecret: kopia-secret

sftp:
  host: nas.example.com
  port: 22
  username: backup
  path: /volume1/backups/kopia    # must already exist on the server

sources:
  - name: photos
    type: hostPath
    hostPath: /mnt/data/photos
  - name: video
    type: hostPath
    hostPath: /mnt/data/video

# hostPath data does not move with the pod, so pin it.
nodeSelector:
  kubernetes.io/hostname: k3s-node-1

schedule: "17 3 * * *"
timeZone: "Europe/Kyiv"

verify:
  enabled: true          # weekly verification CronJob
```

```sh
helm install kopia ./kopia -n backups --create-namespace -f my-values.yaml
helm test kopia -n backups          # read-only connection check
```

## Configuring everything in the browser

If you would rather not put the repository into values at all:

```yaml
mode: server
repository:
  configureInUI: true
ui:
  acknowledgeWritable: true
```

Three keys, and that is the whole file. `sftp.*`, `auth.existingSecret` and
`sources` all become optional; the pod starts with no repository and the UI
opens on its setup screen.

This works because `kopia server start` opens its repository as *optional* —
in kopia's CLI every other command passes `required=true`, and `server start`
passes `false`. So the server runs and serves the UI whether or not anything is
connected.

Three things to know before choosing it:

* **Nothing about the repository is in Git.** `helm install` on an empty
  cluster gives you a blank server again. Turn on `verify.enabled` once you are
  connected — its policy export is then your only copy of the configuration.
* **The repository password ends up on the state PVC.** The chart sets
  `KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=true`, because the image sets it to
  `false` and the connection would otherwise be gone at the next restart. It is
  stored the same way KopiaUI stores it on a desktop.
* **`helm test` is skipped** — there is nothing to test until you connect.

You can still set `auth.existingSecret` to get the SSH key mounted at
`/kopia-ssh/id_key`, and point the UI's SFTP form at that path. And you still
need `sources` before anything can actually be backed up — a server with none
mounted can only browse and restore.

## Creating the repository

The chart refuses to create one by default, because "connect failed" also
describes a typo in `sftp.path` — and kopia would then happily create an empty
repository at the wrong place and upload everything into it.

Either create it from a machine that has the key:

```sh
kopia repository create sftp \
  --path=/volume1/backups/kopia --host=nas.example.com \
  --port=22 --username=backup \
  --keyfile=./kopia_key --known-hosts=./known_hosts
```

or let the chart do it for exactly one run:

```sh
helm upgrade kopia ./kopia -n backups -f my-values.yaml --set repository.createIfMissing=true
kubectl create job --from=cronjob/kopia kopia-init -n backups
kubectl logs -f job/kopia-init -n backups
helm upgrade kopia ./kopia -n backups -f my-values.yaml   # back off again
```

## Seeding a large first backup

500 GB over a 50 Mbit/s uplink is roughly a day of continuous transfer, and the
first run is the one most likely to be interrupted. A kopia repository is just
a directory of blobs, so seed it locally and move it:

```sh
# on the node, against a local directory
kopia repository create filesystem --path=/mnt/scratch/kopia-seed
kopia snapshot create /mnt/data/photos /mnt/data/video

# then move the whole thing to the server, once
rsync -a --info=progress2 /mnt/scratch/kopia-seed/ backup@nas:/volume1/backups/kopia/
```

Point the chart at that path with `repository.createIfMissing: false` and the
first scheduled run is an ordinary incremental.

Two things to raise before a large run that is *not* seeded:

* `activeDeadlineSeconds` — 86400 by default, and the Job is failed hard when
  it fires. Kopia resumes from its checkpoints, so this costs progress rather
  than data, but it will keep happening every night until the backup fits.
* `snapshot.parallel` — SFTP pays a round trip per file, so this is the single
  biggest lever on throughput. 8 is the default; 16–32 helps on a high-latency
  link if the server tolerates it.

## Web UI

In `mode: cronjob` the UI is off by default; turning it on adds a second,
read-only workload next to the CronJob. In `mode: server` it is the only
workload and it is writable.

**The UI has no password by default.** `kopia server` is started with
`--without-password`, and because the server binds a non-loopback address over
plain HTTP, kopia will not do that unless the chart also passes
`--allow-extremely-dangerous-unauthenticated-server-on-the-network`. It does.
Kopia's own description of that flag: it "exposes full repository and control
API to the network without authentication which allows any external attacker to
take full control of the server host".

That is a reasonable default on a LAN with no Ingress. Behind an Ingress it is
not, and setting a password is the only way to avoid the flag:

```sh
kubectl create secret generic kopia-secret -n backups \
  --from-literal=KOPIA_UI_PASSWORD="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

```yaml
ui:
  auth:
    passwordKey: KOPIA_UI_PASSWORD    # username defaults to "kopia"
```

```yaml
ui:
  enabled: true
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: kopia.home.lan
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: kopia-tls
        hosts:
          - kopia.home.lan
```

Without an Ingress:

```sh
kubectl port-forward -n backups svc/kopia-ui 51515:51515
```

### It is read-only by default

`ui.readOnly: true` puts `--readonly` on the repository connection itself, so
nothing this pod runs can delete a snapshot, edit a policy, or take maintenance
ownership away from the backup Job. Browsing and restoring both work — restore
reads from the repository and writes to local disk.

Turning it off requires `ui.acknowledgeWritable: true` as well. That is a speed
bump, not a lock.

### It connects under the same identity as the backup

Kopia organises snapshots by source, so matching the identity is what makes the
UI open on the sources this release actually backs up instead of an empty list.
Safe precisely because the connection is read-only. Override with
`ui.identity.*` if you would rather see the two connections separately.

### Where restores go

Sources are mounted read-only and stay that way, so a restore can never land on
top of the originals. Give it somewhere writable instead:

```yaml
restore:
  enabled: true
  type: hostPath              # or pvc + existingClaim
  hostPath: /mnt/data/restore
  mountPath: /restore         # what you type in the UI's restore dialog
```

Prepare the directory on the node first. The pod runs as UID 1000 and `fsGroup`
does not apply to hostPath, so an auto-created root-owned directory would make
every restore fail with `permission denied` from inside the UI — which is why
`hostPathType` defaults to `Directory` rather than `DirectoryOrCreate`:

```sh
mkdir -p /mnt/data/restore && chown 1000:1000 /mnt/data/restore
```

A hostPath restore target has to be on the node the server pod lands on, and
the chart refuses to render unless that pod is pinned — `ui.nodeSelector` in
cronjob mode, the top-level `nodeSelector` in server mode.

For a one-off "I deleted a photo", KopiaUI on your desktop against the same
repository is still simpler — same binary, same repository, and the file lands
straight where you want it. Just do not let it take snapshots or claim
maintenance ownership.

### TLS

The server always speaks plain HTTP inside the cluster — it has no certificate
of its own, by design. Terminate TLS at the Ingress:

```yaml
ui:
  ingress:
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
    tls:
      - secretName: kopia-tls
        hosts:
          - kopia.home.lan
```

If the UI loads but every action fails behind your proxy, try
`ui.disableCSRFChecks: true` — some reverse proxies break kopia's CSRF token.

### It has its own cache, deliberately

`ui.persistence.cache` is a separate claim from `persistence.state`. Two kopia
processes sharing one config file and one cache directory is undefined
behaviour, and ReadWriteOnce does not prevent it: access modes are enforced per
node, not per pod.

### NetworkPolicy covers the two workloads separately

The backup pod and the UI pod carry different `app.kubernetes.io/component`
labels, and each gets its own policy. The backup policy is a genuine deny-all
ingress; the UI policy has to let the Ingress controller in, so it is not:

```yaml
networkPolicy:
  enabled: true
  uiIngressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Leave `uiIngressFrom` empty and the usual trap applies — a rule with ports and
no `from` matches every source in the cluster.

### Configuring everything from the browser: `mode: server`

```yaml
mode: server

sources:
  - name: data
    type: hostPath
    hostPath: /mnt/data
    mountPath: /mnt/data      # same path as on the node, so what you pick in
                              # the UI reads the way you expect

restore:
  enabled: true
  hostPath: /mnt/data/restore

ui:
  acknowledgeWritable: true   # this server takes AND can delete snapshots
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: kopia.home.lan
        paths:
          - path: /
            pathType: Prefix

nodeSelector:
  kubernetes.io/hostname: k3s-node-1
```

No CronJob is rendered. You add sources and schedules in the UI, and kopia's
own scheduler runs them. `schedule`, `snapshotPaths`, `verify` and `policy.*`
are cronjob-only; the chart rejects the two that would silently do nothing
rather than leaving you to wonder.

What you give up is stated once in the table at the top: a failed snapshot is a
log line, not a `Failed` Job. Watch it with

```sh
kubectl logs -f -n backups deploy/kopia-ui
```

and check the Snapshots tab now and then.

### What server mode ignores

kopia owns these once you switch, and the chart does not half-apply them:

| Ignored | Because |
| --- | --- |
| `schedule`, `suspend`, `concurrencyPolicy`, `backoffLimit`, `activeDeadlineSeconds`, `startingDeadlineSeconds`, `ttlSecondsAfterFinished`, `*JobsHistoryLimit` | no backup CronJob exists. `timeZone` still applies — the verify CronJob falls back to it |
| `snapshot.*`, `policy.*` | set per source in the UI |
| `ui.readOnly`, `ui.identity`, `ui.persistence.cache` | the server is the backup client, so it is writable and uses `identity.*` and `persistence.state` |

`terminationGracePeriodSeconds` still applies — it is what gives kopia time to
flush a checkpoint when the pod is asked to stop, so leave it generous.

`snapshotPaths` is rejected outright rather than ignored: silently dropping it
would leave you believing a path is backed up when nothing is looking at it.

### A middle option

If the only thing you actually want to change by hand is retention, stay on
`mode: cronjob` and hand the policies to a writable UI:

```yaml
policy:
  apply: false              # stop rewriting policies every night
ui:
  enabled: true
  readOnly: false
  acknowledgeWritable: true
  identity:
    hostname: kopia-ui      # so it does not fight for maintenance ownership
```

Paths and schedule stay in values.yaml; retention, compression and ignore rules
live in the UI and survive.

## Things worth knowing

### Snapshot identity is pinned, and it has to be

Kopia files every snapshot under `username@hostname:path`. Every Job creates a
pod with a fresh random name, so without an override each night's snapshot
would belong to a *different source*. Retention is per source, so nothing would
ever be pruned; the snapshot list would grow one dead source per night; and
policies would apply to a source that never comes back.

The chart passes `--override-hostname` and `--override-username` on connect,
defaulting to the release fullname and `kopia`. Change `identity.*` after the
first backup and kopia sees an entirely new source — the content is
deduplicated, so nothing is re-uploaded, but the history restarts.

### The chart owns the policy

Policies are stored in the repository, not in Kubernetes. With
`policy.apply: true` (the default) the chart rewrites them on every run, which
makes `values.yaml` the source of truth — and means a policy you edit by hand
in the CLI reverts at 03:00. Set `policy.apply: false` if you would rather
manage them in kopia.

`--add-ignore` appends rather than replaces, so the chart emits `--clear-ignore`
first whenever `policy.ignore` is non-empty. Without that the ignore list would
grow by one copy of every rule per run.

### Compression is off, and for photos and video that is right

JPEG, HEIC, MP4 and MKV are already compressed. Running zstd over them spends
CPU to make the data very slightly larger. Set
`policy.compression: zstd-fastest` for documents, source code or database
dumps.

The same reasoning limits what deduplication buys you here: it is what makes
the *incremental* runs cheap (an unchanged file is not re-uploaded), but it
will not meaningfully shrink a media library on the first pass.

### The pod must be able to read your files

The container runs as `podSecurityContext.runAsUser` (1000 by default), not
root. `fsGroup` fixes ownership on the state volume but does **not** apply to
hostPath mounts, so that UID needs read access to the real data:

```sh
stat -c '%U %G %a' /mnt/data/photos
```

Kopia treats an unreadable file as a snapshot error rather than skipping it
silently, so a permission problem shows up as a failed Job. That is the good
outcome. `policy.ignoreFileErrors: true` turns it into a quietly incomplete
backup, which is why it is empty by default.

### Maintenance is what actually frees space

Retention marks snapshots for deletion. *Full* maintenance is what deletes the
underlying blobs. With `maintenance.full: false` the repository grows forever
no matter how aggressive the retention policy looks.

The chart does not run maintenance itself — it calls `kopia maintenance set` so
kopia's own scheduler does, at `maintenance.quickInterval` and
`maintenance.fullInterval`. Note that `--owner=me` takes ownership away from
any other client currently holding it: if several machines share one
repository, exactly one of them should have `maintenance.enabled: true`.

### Verification

`kopia snapshot verify` does two different jobs, and confusing them leads to
either a useless check or an enormous bandwidth bill.

**Structural** — what it does with `percent` at 0. It walks every snapshot and
confirms that every content they reference actually exists in the repository.
Indexes only, no file data, so it covers 100% of an 800 GB repository in
minutes. This catches the failure that actually happens: blobs missing after
bad maintenance, an interrupted upload, or someone tidying up the NAS.

**Content** — what `percent > 0` adds. Kopia downloads a random sample of files
and re-hashes them. It is the only way to catch bit rot, and it costs real
transfer.

Two things about that sample are easy to get wrong. It is a percentage of
**files by count, not bytes** — in a mixed photo and video library a random 2%
might pull 500 MB one week and 40 GB the next. And sampling is independent each
run, so coverage compounds slowly: after N runs at rate p the unverified
fraction is `(1-p)^N`. Weekly at 2% leaves about a third of the repository
untouched after a full year; reaching 90% inside a year needs roughly 4.3% a
week, which on 800 GB is about 34 GB every week.

So: let the structural check carry the load, keep content sampling small as a
canary on the SFTP path, and put real bit-rot detection where it belongs — a
ZFS scrub or btrfs/Synology Data Scrubbing on the NAS reads every block against
its checksum locally, at disk speed, for nothing.

It runs as a CronJob of its own, in either mode:

```yaml
verify:
  enabled: true
  schedule: "23 5 * * 0"     # weekly, away from the backup window
```

`percent` defaults to `0.5` and `maxErrors` to `100`.

It connects **read-only**, so it can neither delete a snapshot nor take
maintenance ownership from whatever is doing the backups. Its cache is an
emptyDir, deliberately: verification reads content it has not read before, so a
warm cache buys nothing and a shared one would collide with the backup
workload.

Sizing it for a large repository:

| Knob | Why |
| --- | --- |
| `percent: 0` | structural only — full coverage, minutes, no data transfer |
| `percent: 0.5` (the default) | a bit-rot canary on top; budget `percent × repo size` per run, with wide variance |
| `activeDeadlineSeconds: 21600` | 6 h. 16 GB inside it needs about 6 Mbit/s sustained — trivial on a LAN NAS, tight over a slow WAN |
| `maxErrors: 100` (the default) | kopia's own default of 0 is rewritten to 1 internally — it stops at the first bad file. The run fails either way, so this only decides whether you get a list or one line. Negative is unlimited |
| `extraArgs: ["--parallel=16"]` | default is 8; worth raising against a LAN NAS |
| `extraArgs: ["--sources=user@host:/path"]` | verify one source per week instead of sampling everything |

Worth doing once, separately: a full `--verify-files-percent=100` after the
first seed, to prove the whole thing landed. On a LAN that is an evening; over
a WAN, budget for downloading the entire repository once.

Two things make it the piece you should not skip:

**It fails visibly.** In server mode the backup pod reports `Ready` whether or
not it is still backing anything up. This Job goes red. Point an alert at it:

```sh
kubectl get jobs -n backups -l app.kubernetes.io/component=verify
```

**It exports your configuration.** In server mode the sources, schedules and
retention live in the repository rather than in values.yaml, so `helm install`
on an empty cluster would not bring them back. The Job dumps them to its log
between markers:

```sh
kubectl logs -n backups job/kopia-verify-1 \
  | sed -n '/BEGIN POLICY EXPORT/,/END POLICY EXPORT/p' > kopia-policies.json
# restore with: kopia policy import < kopia-policies.json
```

Set `verify.exportPath` to also write it to a file — that needs a
writable mount, since the root filesystem is read-only, and the chart refuses
to render a path outside `/tmp` without one.

### Knowing that a backup failed

The verification Job above covers the repository. A snapshot that failed
tonight is kopia's own business, and kopia can tell you directly — notification
profiles live in the repository, so configure one once from the UI or a
throwaway pod:

```sh
kopia notification profile configure webhook \
  --profile-name=homelab --endpoint=https://ntfy.sh/your-topic \
  --min-severity=warning
```

`email` and `pushover` senders exist too, and `--send-test-notification` proves
it works. In `mode: server` this is not optional decoration — it is what
replaces the red Job you gave up.

### hostPath must be pinned to a node

A hostPath volume does not follow the pod. The chart refuses to render a
hostPath source unless `nodeSelector` or `affinity` is set, and defaults
`hostPathType` to `Directory` so a missing path stops the Job outright.

`DirectoryOrCreate` is the dangerous setting here: the kubelet would create an
empty directory, kopia would snapshot it, record the empty snapshot as a
success, and retention would then start pruning the snapshots that held the
real data.

Note what `Directory` does *not* catch: a disk that failed to mount after a
reboot leaves a real, empty directory behind. For that, add an `initContainer`
that checks for a marker file — it is applied to whichever workload mounts the
sources, the CronJob or the server Deployment:

```yaml
initContainers:
  - name: guard
    image: busybox:1.36
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: [ALL]}
    command:
      - sh
      - -c
      - test -f /mnt/data/.mounted || { echo "FATAL: disk not mounted"; exit 1; }
    volumeMounts:
      - name: src-data       # the chart names source volumes src-<name>
        mountPath: /mnt/data
        readOnly: true
```

Put the `.mounted` marker on the disk itself, not in the mount point.

### Rotating the repository password

Changing `KOPIA_PASSWORD` in the Secret does not change the repository
password. The Job reads the Secret fresh on every run — unlike a Deployment,
there is nothing to restart — so the new value takes effect immediately and
immediately fails to open the repository. Change it on the repository first:

```sh
kopia repository change-password
```

### NetworkPolicy

Unlike the other charts in this repository, `ingress: []` here is a genuine
deny-all: nothing in this pod listens on a port.

Egress is the side that matters, and it stays completely unrestricted while
`networkPolicy.egress` is empty — the chart does not declare the `Egress`
policyType at all, because declaring it with no rules would deny everything,
DNS and the SFTP server included. Add one rule and everything else is denied:

```yaml
networkPolicy:
  enabled: true
  egress:
    - to:
        - ipBlock:
            cidr: 192.168.1.10/32
      ports:
        - port: 22
          protocol: TCP
  allowDNS: true    # unnecessary if you addressed the server by IP
```

### Labels and annotations on everything

`commonLabels` and `commonAnnotations` reach every object the chart renders.
`commonLabels` deliberately stays out of the selector labels, which the
NetworkPolicy podSelector matches on.

On the state PVC, `persistence.state.retain` is applied *after* the annotation
merge, so `commonAnnotations` can never remove `helm.sh/resource-policy: keep`
by accident.

### SFTP is kopia's slowest backend

It pays a round trip per file, and kopia writes many blobs. If the remote host
is yours and can run something, MinIO or `rclone serve s3` in front of the same
disk is noticeably faster. If it is a NAS that only speaks SFTP, this works
fine — raise `snapshot.parallel` and leave it alone.

### The state volume is not precious

Unlike duplicati's `/data`, nothing on it is irreplaceable: the config file is
rebuilt by the next `repository connect` and a cache is a cache. Losing it
costs one slow run, not a backup. `retain: true` is the default for consistency
with the other charts here, and because rebuilding a cold cache over SFTP is
slow enough to be worth not doing by accident.

## Running it from Terraform

The chart renders no `lookup` calls, so `helm template` and a Terraform plan
agree. Two things still bite:

* The Secret must exist before the release. If the same apply creates both, add
  an explicit `depends_on`.
* Values passed through a provider `set` block arrive as strings. That is fine
  everywhere except fractional numbers — `verify.percent` accepts both forms
  for exactly this reason. Prefer a values file.

## Testing a release

```sh
helm test kopia -n backups
```

The test pod connects to the repository **read-only**, using its own emptyDir
cache, so it never touches the CronJob's state volume and can run while a
backup is in progress. It proves the host key, the private key, the path and
the repository password all line up — which is most of what goes wrong.

## Values

See [`values.yaml`](values.yaml); every key is commented inline, and
[`values.schema.json`](values.schema.json) validates the important ones at
install time.
