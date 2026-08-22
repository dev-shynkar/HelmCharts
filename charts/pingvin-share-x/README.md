# pingvin-share-x

Helm chart for [Pingvin Share X](https://github.com/smp46/pingvin-share-x), a self-hosted file sharing platform.

## How the container is wired

The image runs two Node.js processes and, optionally, a Caddy reverse proxy:

| Process | Port | Notes |
| --- | --- | --- |
| Next.js frontend | `3333` | hardcoded by `scripts/docker/entrypoint.sh` |
| NestJS backend | `8080` | `BACKEND_PORT`, serves everything under `/api` |
| Caddy | `3000` | only started when `CADDY_DISABLED != "true"` |

**This chart sets `CADDY_DISABLED=true`** and routes `/api` from the Ingress
instead. That drops a proxy hop and avoids running Caddy as UID 1000 without a
writable `$HOME`. The trade-off is that the Ingress *must* carry an `/api` route
— the chart refuses to render without one.

If you would rather keep Caddy, see [Re-enabling Caddy](#re-enabling-caddy).

## Installing

```sh
helm install pingvin ./pingvin-share-x \
  --namespace pingvin --create-namespace \
  -f my-values.yaml
```

A minimal `my-values.yaml` for an ingress-nginx cluster:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    # Uploads are chunked at 10 MB; the 1 MB default would 413 every one of them.
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  hosts:
    - host: share.example.com
      paths:
        - path: /api
          pathType: Prefix
          port: api
        - path: /
          pathType: Prefix
          port: http
  tls:
    - secretName: pingvin-tls
      hosts:
        - share.example.com

data:
  persistence:
    size: 100Gi
    storageClass: longhorn
```

The first account to register at `/auth/signup` becomes the administrator.

## Things worth knowing

### One replica only

Pingvin Share X keeps its state in SQLite on a `ReadWriteOnce` volume and caches
in process memory. `replicaCount` above 1 will corrupt data unless you *also*
configure Redis caching (`cache.redis-enabled`), S3 storage and a `ReadWriteMany`
volume. There is deliberately **no HPA template** in this chart.

For the same reason `updateStrategy.type` is `Recreate`: a rolling update would
deadlock with the new pod waiting for a PVC the old pod still holds.

### Ingress body size

This is the single most common failure for a file sharing deployment. Pingvin
uploads in 10 MB chunks (`share.chunkSize`), and ingress-nginx caps request
bodies at 1 MB by default, so every upload fails with HTTP 413 until you set
`proxy-body-size`. Traefik has no size cap but does buffer — attach a
`Middleware` with `buffering.maxRequestBodyBytes: 0` for large files.

### Secrets

`config.yaml` can contain `smtp.password`, `ldap.bindPassword`,
`oauth.*.clientSecret` and S3 credentials, so the chart renders it into a
**Secret**, not a ConfigMap. Two ways to supply it:

```yaml
# Inline — ends up in your values file, so keep that file out of git.
config:
  enabled: true
  data:
    general:
      appUrl: https://share.example.com

# Or point at a Secret you manage with SOPS / External Secrets.
config:
  enabled: true
  existingSecret: pingvin-config   # must have a "config.yaml" key
```

Enabling `config.yaml` makes the settings **read-only in the admin UI**.

For plain environment variables use `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: pingvin-smtp
```

### Data retention

Both PVCs carry `helm.sh/resource-policy: keep` by default, so `helm uninstall`
leaves your shares and database in place. Set `data.persistence.retain: false`
if you actually want them deleted with the release.

### PUID / PGID

Deliberately unset. The image entrypoint (`scripts/docker/create-user.sh`) bails
out with `[ "$(id -u)" -ne 0 ] && exec "$@"` before it ever reads them, and this
chart always runs as UID 1000. Ownership comes from `podSecurityContext.fsGroup`
instead. Setting `PUID`/`PGID` in `env` does nothing.

### CPU limits

Creating a share builds a zip at compression level 9 by default
(`share.zipCompressionLevel`), which is CPU bound. The chart requests 100m and
limits to 1000m; if downloads of large multi-file shares feel slow, raise the
limit or drop it entirely and keep only the request.

### Read-only root filesystem

Not the default, because Next.js writes its incremental cache under
`/opt/app/frontend/.next/cache`. To turn it on:

```yaml
securityContext:
  readOnlyRootFilesystem: true

extraVolumes:
  - name: next-cache
    emptyDir: {}
extraVolumeMounts:
  - name: next-cache
    mountPath: /opt/app/frontend/.next/cache
```

`/tmp` already gets an `emptyDir` unconditionally.

### Re-enabling Caddy

```yaml
env:
  CADDY_DISABLED: "false"

containerPorts:
  http: 3000        # Caddy fronts both processes here

# Caddy needs a writable config/data dir; without $HOME it falls back to a
# relative path under /opt/app, which UID 1000 cannot write to.
extraEnv:
  - name: HOME
    value: /tmp
  - name: XDG_DATA_HOME
    value: /tmp
  - name: XDG_CONFIG_HOME
    value: /tmp

ingress:
  hosts:
    - host: share.example.com
      paths:
        - path: /
          pathType: Prefix
          port: http
```

Note that the `/api` guard in `templates/ingress.yaml` will reject this — remove
the guard or keep an `/api` path pointing at `port: http`.

### ClamAV

```yaml
extraEnv:
  - name: CLAMAV_HOST
    value: clamav.security.svc.cluster.local
  - name: CLAMAV_PORT
    value: "3310"
```

If `networkPolicy.enabled` is on with egress rules, remember to allow that
traffic — and DNS.

## Upgrading from 0.1.x

0.1.x shipped `CADDY_DISABLED=true` together with `containerPort: 3000`, which
meant nothing was listening on the port the Service and probes pointed at. It
also referenced a ServiceAccount that no template created. Both are fixed, but
the values layout changed:

| 0.1.x | 0.2.0 |
| --- | --- |
| `service.port: 3000` | `service.ports.http` / `service.ports.api` |
| — | `containerPorts.http` / `containerPorts.api` |
| `ingress.hosts[].paths[]` (one `/`) | add a `/api` entry with `port: api` |
| `env.PUID`, `env.PGID` | removed, no effect (see above) |
| `autoscaling.*` | removed, never had an HPA template |
| `livenessProbe.httpGet.path: /` | `/api/health` on the `api` port |
| `config` → ConfigMap | `config` → Secret, mounted at `/opt/app/config/` |

The PVC names are unchanged, so your data carries over.

## Testing a release

```sh
helm test pingvin --namespace pingvin
```

Hits `/api/health` and the frontend index through the Service.

## Values

See [`values.yaml`](values.yaml) — every key is commented inline, and
[`values.schema.json`](values.schema.json) validates the important ones at
install time.
