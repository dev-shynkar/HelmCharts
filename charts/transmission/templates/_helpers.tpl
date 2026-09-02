{{/*
Expand the name of the chart.
*/}}
{{- define "transmission.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "transmission.fullname" -}}
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

{{- define "transmission.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "transmission.labels" -}}
helm.sh/chart: {{ include "transmission.chart" . }}
{{ include "transmission.selectorLabels" . }}
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

`app` is kept on the pod template for backwards compatibility with 0.3.x, but it
is deliberately NOT here — being the only thing identifying the pods was what let
two releases claim each other's.

commonLabels must never reach these either: a Deployment's spec.selector is
immutable, so any change here turns every later upgrade into a hard failure.
*/}}
{{- define "transmission.selectorLabels" -}}
app.kubernetes.io/name: {{ include "transmission.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "transmission.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "transmission.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "transmission.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/*
PVC names. Three cases, in priority order:
  existingClaim  a volume this chart does NOT manage — mounted only
  claimName      a volume this chart DOES manage, under a name you choose;
                 this is how you keep the 0.3.x names on an upgrade
  neither        <fullname>-<volume>
*/}}
{{- define "transmission.claimName" -}}
{{- $p := index .ctx.Values.persistence .vol -}}
{{- if $p.existingClaim -}}
{{- $p.existingClaim -}}
{{- else -}}
{{- $p.claimName | default (printf "%s-%s" (include "transmission.fullname" .ctx) .vol) -}}
{{- end -}}
{{- end }}

{{- define "transmission.configClaimName" -}}
{{- include "transmission.claimName" (dict "ctx" . "vol" "config") -}}
{{- end }}

{{- define "transmission.downloadsClaimName" -}}
{{- include "transmission.claimName" (dict "ctx" . "vol" "downloads") -}}
{{- end }}

{{- /*
  watch has no size/accessModes of its own — the chart never creates that PVC,
  it only mounts one you point it at. Kept as a helper anyway so the deployment
  cannot render an empty claimName, which is what it did before.
*/ -}}
{{- define "transmission.watchClaimName" -}}
{{- $w := .Values.persistence.watch -}}
{{- $w.existingClaim | default $w.claimName -}}
{{- end }}

{{/*
Environment variables.
*/}}
{{- define "transmission.env" -}}
{{- /*
  A values file that clears env ("env:" with nothing under it) makes this nil.
  range over nil is harmless, but hasKey on nil is a render-time panic.
*/ -}}
{{- $userEnv := .Values.env | default dict -}}
{{- range $name, $value := $userEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- if and .Values.peerPort.enabled (not (hasKey $userEnv "PEERPORT")) }}
{{- /* Pins the listening port; without it Transmission may pick a random one
       and the port you forwarded would be the wrong one. */}}
- name: PEERPORT
  value: {{ .Values.peerPort.port | quote }}
{{- end }}
{{- with .Values.auth.existingSecret }}
- name: USER
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.auth.keys.username }}
- name: PASS
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.auth.keys.password }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Validation.
*/}}
{{- define "transmission.validate" -}}

{{- $dl := .Values.persistence.downloads -}}
{{- if $dl.enabled }}
{{- if not (has $dl.type (list "hostPath" "pvc")) }}
{{- fail (printf "persistence.downloads.type must be \"hostPath\" or \"pvc\", got %q" $dl.type) }}
{{- end }}
{{- if eq $dl.type "hostPath" }}
{{- if not $dl.hostPath }}
{{- fail "persistence.downloads.hostPath must be set when type is hostPath" }}
{{- end }}
{{- /*
  hostPath data does not follow the pod. Without a node constraint the scheduler
  is free to move it, DirectoryOrCreate makes an empty directory on the new
  node, and every torrent looks lost.
*/}}
{{- if and (not .Values.nodeSelector) (not .Values.affinity) }}
{{- fail "persistence.downloads.type is hostPath, so the pod must be pinned to the node holding the data: set nodeSelector (e.g. kubernetes.io/hostname: <node>) or affinity" }}
{{- end }}
{{- end }}
{{- end }}

{{- $w := .Values.persistence.watch }}
{{- if $w.enabled }}
{{- if eq $w.type "hostPath" }}
{{- if not $w.hostPath }}
{{- fail "persistence.watch.hostPath must be set when type is hostPath" }}
{{- end }}
{{- else }}
{{- /*
  This chart never creates the watch PVC. Without one of these the rendered
  claimName was empty, which the API server rejects with a message that says
  nothing about /watch.
*/}}
{{- if not (or $w.existingClaim $w.claimName) }}
{{- fail "persistence.watch.type is pvc, so set persistence.watch.existingClaim (or claimName) to the volume to mount at /watch — this chart does not create it" }}
{{- end }}
{{- end }}
{{- end }}

{{- if gt (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: Transmission keeps its state on a ReadWriteOnce volume and claims the peer hostPort, so a second pod cannot start" }}
{{- end }}

{{- /*
  RollingUpdate deadlocks twice over here.

  With one replica the default maxUnavailable rounds down to 0, so Kubernetes
  starts the new pod before stopping the old one. It then waits for two things
  the old pod still holds: the ReadWriteOnce /config volume, and — if hostPort
  is on — peer port 51413 on the node. Neither is released until the old pod
  goes away, which a rolling update will not do first.

  Landing on the SAME node is the quiet case for the volume: ReadWriteOnce is
  enforced per node, not per pod, so both pods mount /config and two Transmission
  processes write the same settings.json and resume files.

  The volume half is skipped with existingClaim, where the real access mode lives
  outside these values. The hostPort half always applies.
*/}}
{{- if eq (.Values.updateStrategy.type | default "Recreate") "RollingUpdate" }}
{{- $cfg := .Values.persistence.config }}
{{- if and .Values.peerPort.enabled .Values.peerPort.hostPort }}
{{- fail "updateStrategy.type must be Recreate while peerPort.hostPort is true: the new pod cannot bind the peer port until the old one releases it, so a rolling update never completes" }}
{{- end }}
{{- if and $cfg.enabled (not $cfg.existingClaim) (has "ReadWriteOnce" $cfg.accessModes) }}
{{- fail "updateStrategy.type must be Recreate while persistence.config uses ReadWriteOnce: a rolling update would run two Transmission processes against the same /config. Use ReadWriteMany, or keep Recreate." }}
{{- end }}
{{- end }}

{{- end }}
