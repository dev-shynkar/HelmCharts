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
{{- end }}

{{/*
Selector labels.

`app` is kept alongside the standard labels for backwards compatibility with
0.3.x, but it is no longer the only thing identifying the pods — that was what
let two releases claim each other's pods.
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

{{/*
Environment variables.
*/}}
{{- define "transmission.env" -}}
{{- range $name, $value := .Values.env }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- if and .Values.peerPort.enabled (not (hasKey .Values.env "PEERPORT")) }}
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

{{- if and .Values.persistence.watch.enabled (eq .Values.persistence.watch.type "hostPath") (not .Values.persistence.watch.hostPath) }}
{{- fail "persistence.watch.hostPath must be set when type is hostPath" }}
{{- end }}

{{- if gt (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: Transmission keeps its state on a ReadWriteOnce volume and claims the peer hostPort, so a second pod cannot start" }}
{{- end }}

{{- end }}
