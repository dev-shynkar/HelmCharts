{{/*
Expand the name of the chart.
*/}}
{{- define "duplicati.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "duplicati.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "duplicati.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "duplicati.labels" -}}
helm.sh/chart: {{ include "duplicati.chart" . }}
{{ include "duplicati.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels.

commonLabels must never reach these: a Deployment's spec.selector is immutable,
so any change here turns every later upgrade into a hard failure.
*/}}
{{- define "duplicati.selectorLabels" -}}
app.kubernetes.io/name: {{ include "duplicati.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "duplicati.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "duplicati.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "duplicati.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/*
PVC names. Templated on fullname so two releases in one namespace do not fight
over the same claims (0.18.x hardcoded "pvc-duplicati-*").

Three cases, in priority order:
  existingClaim  a volume this chart does NOT manage — mounted only
  claimName      a volume this chart DOES manage, under a name you choose;
                 this is how you keep the 0.18.x names on an upgrade
  neither        <fullname>-<volume>
*/}}
{{- define "duplicati.claimName" -}}
{{- $p := index .ctx.Values.persistence .vol -}}
{{- if $p.existingClaim -}}
{{- $p.existingClaim -}}
{{- else -}}
{{- $p.claimName | default (printf "%s-%s" (include "duplicati.fullname" .ctx) .vol) -}}
{{- end -}}
{{- end }}

{{- define "duplicati.configClaimName" -}}
{{- include "duplicati.claimName" (dict "ctx" . "vol" "config") -}}
{{- end }}

{{- define "duplicati.sourceClaimName" -}}
{{- include "duplicati.claimName" (dict "ctx" . "vol" "source") -}}
{{- end }}

{{- define "duplicati.backupsClaimName" -}}
{{- include "duplicati.claimName" (dict "ctx" . "vol" "backups") -}}
{{- end }}

{{/*
Allowed hostnames for the web service.

Duplicati rejects any request whose Host header it does not recognise, which is
the usual reason the UI refuses to open behind an Ingress. Build the list from
everything that legitimately reaches it: the probes (localhost), in-cluster
callers (the Service DNS names) and each Ingress host.
*/}}
{{- define "duplicati.allowedHostnames" -}}
{{- $fullname := include "duplicati.fullname" . -}}
{{- $names := list "localhost" "127.0.0.1" $fullname (printf "%s.%s" $fullname .Release.Namespace) (printf "%s.%s.svc" $fullname .Release.Namespace) (printf "%s.%s.svc.cluster.local" $fullname .Release.Namespace) -}}
{{- if .Values.ingress.enabled -}}
{{- range .Values.ingress.hosts -}}
{{- if .host -}}
{{- $names = append $names .host -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join ";" (uniq $names) -}}
{{- end }}

{{/*
Environment variables.
*/}}
{{- define "duplicati.env" -}}
{{- $userEnv := .Values.env | default dict -}}
{{- range $name, $value := $userEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- if not (hasKey $userEnv "DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES") }}
- name: DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES
  value: {{ include "duplicati.allowedHostnames" . | quote }}
{{- end }}
{{- with .Values.auth.existingSecret }}
{{- if $.Values.auth.keys.password }}
- name: DUPLICATI__WEBSERVICE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.auth.keys.password }}
{{- end }}
{{- if $.Values.auth.keys.encryptionKey }}
- name: SETTINGS_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.auth.keys.encryptionKey }}
{{- end }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Validation.
*/}}
{{- define "duplicati.validate" -}}

{{- range $vol := list "source" "backups" }}
{{- $p := index $.Values.persistence $vol }}
{{- if $p.enabled }}
{{- if not (has $p.type (list "pvc" "hostPath")) }}
{{- fail (printf "persistence.%s.type must be \"pvc\" or \"hostPath\", got %q" $vol $p.type) }}
{{- end }}
{{- if eq $p.type "hostPath" }}
{{- if not $p.hostPath }}
{{- fail (printf "persistence.%s.hostPath must be set when type is hostPath" $vol) }}
{{- end }}
{{- /*
  A hostPath that follows the pod to another node is worse here than in most
  charts: Duplicati would back up the empty DirectoryOrCreate, mark it a
  successful version, and retention would then prune the versions that held
  real data.
*/}}
{{- if and (not $.Values.nodeSelector) (not $.Values.affinity) }}
{{- fail (printf "persistence.%s.type is hostPath, so the pod must be pinned to the node holding the data: set nodeSelector (e.g. kubernetes.io/hostname: <node>) or affinity" $vol) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- if gt (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: several Duplicati instances writing the same server database in /data will corrupt it" }}
{{- end }}

{{- /*
  RollingUpdate over a ReadWriteOnce /data volume.

  With one replica the default maxUnavailable rounds down to 0, so Kubernetes
  starts the new pod before stopping the old one. Landing on another node gives
  a Multi-Attach error and an upgrade that hangs until it times out. Landing on
  the SAME node is worse and silent: ReadWriteOnce is enforced per node, not per
  pod, so both pods mount the volume and two Duplicati processes write the same
  SQLite database — exactly what the replicaCount check above prevents.

  Only checked for a claim this chart creates. With existingClaim the real
  access mode lives outside these values, so guessing here would reject working
  setups.
*/}}
{{- $cfg := .Values.persistence.config }}
{{- if and (eq (.Values.strategy.type | default "Recreate") "RollingUpdate") $cfg.enabled (not $cfg.existingClaim) (has "ReadWriteOnce" $cfg.accessModes) }}
{{- fail "strategy.type must be Recreate while persistence.config uses ReadWriteOnce: a rolling update would run two Duplicati processes against the same server database. Use ReadWriteMany, or keep Recreate." }}
{{- end }}

{{- end }}
