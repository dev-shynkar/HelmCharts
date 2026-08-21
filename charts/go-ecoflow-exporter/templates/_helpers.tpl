{{/*
Expand the name of the chart.
*/}}
{{- define "go-ecoflow-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "go-ecoflow-exporter.fullname" -}}
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

{{- define "go-ecoflow-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "go-ecoflow-exporter.labels" -}}
helm.sh/chart: {{ include "go-ecoflow-exporter.chart" . }}
{{ include "go-ecoflow-exporter.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/component: exporter
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels. Never add anything version-dependent here — the Deployment
selector is immutable once created.
*/}}
{{- define "go-ecoflow-exporter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "go-ecoflow-exporter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "go-ecoflow-exporter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "go-ecoflow-exporter.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image reference.
*/}}
{{- define "go-ecoflow-exporter.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/*
Checksum of the referenced Secret's contents.

Hashing the Secret's *name* (as this chart used to) is a constant: rotating the
EcoFlow password would leave the pod running with the old credentials, because
the exporter only reads its environment at startup.

`lookup` returns nothing during `helm template` and `--dry-run`, which is fine —
the annotation is only meaningful against a live cluster.
*/}}
{{- define "go-ecoflow-exporter.secretChecksum" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.existingSecret.name -}}
{{- if $secret -}}
{{- $secret.data | toYaml | sha256sum -}}
{{- else -}}
not-found
{{- end -}}
{{- end }}

{{/*
Environment variables.
*/}}
{{- define "go-ecoflow-exporter.env" -}}
{{- $secretName := .Values.existingSecret.name -}}
{{- $keys := .Values.existingSecret.keys -}}
{{- /* Prometheus is always on: with zero metric handlers main.go calls os.Exit(1). */}}
- name: PROMETHEUS_ENABLED
  value: "true"
- name: PROMETHEUS_PORT
  value: {{ .Values.containerPort | quote }}
- name: METRIC_PREFIX
  value: {{ .Values.exporter.metricPrefix | quote }}
- name: EXPORTER_TYPE
  value: {{ .Values.exporter.type | quote }}
{{- /* The app reads DEBUG_ENABLED, not DEBUG. */}}
- name: DEBUG_ENABLED
  value: {{ .Values.debug.enabled | quote }}

{{- if eq .Values.exporter.type "mqtt" }}
- name: MQTT_DEVICE_OFFLINE_THRESHOLD_SECONDS
  value: {{ .Values.exporter.mqtt.deviceOfflineThresholdSeconds | quote }}
- name: MQTT_PING_INTERVAL_SECONDS
  value: {{ .Values.exporter.mqtt.pingIntervalSeconds | quote }}
- name: MQTT_STATE_REFRESH_INTERVAL_SECONDS
  value: {{ .Values.exporter.mqtt.stateRefreshIntervalSeconds | quote }}
{{- if $secretName }}
- name: ECOFLOW_EMAIL
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $keys.email }}
- name: ECOFLOW_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $keys.password }}
{{- end }}
{{- end }}

{{- if eq .Values.exporter.type "rest" }}
- name: SCRAPING_INTERVAL
  value: {{ .Values.exporter.rest.scrapingIntervalSeconds | quote }}
{{- if $secretName }}
- name: ECOFLOW_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $keys.accessKey }}
- name: ECOFLOW_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $keys.secretKey }}
{{- end }}
{{- end }}

{{- /*
  Device mapping applies to both exporter types: getDeviceMapping() is called by
  the REST path as well, which is where pretty names come from there.
  Values win; otherwise fall back to the Secret so existing installs keep working.
*/}}
{{- if .Values.exporter.devices }}
- name: ECOFLOW_DEVICES
  value: {{ join "," .Values.exporter.devices | quote }}
{{- else if $secretName }}
- name: ECOFLOW_DEVICES
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $keys.devices }}
      optional: true
{{- end }}
{{- if .Values.exporter.devicesPrettyNames }}
- name: ECOFLOW_DEVICES_PRETTY_NAMES
  value: {{ toJson .Values.exporter.devicesPrettyNames | quote }}
{{- else if $secretName }}
- name: ECOFLOW_DEVICES_PRETTY_NAMES
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $keys.devicesPrettyNames }}
      optional: true
{{- end }}

{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Validation.
*/}}
{{- define "go-ecoflow-exporter.validate" -}}

{{- /* An unknown type makes the app log "Unknown exporter type" and exit. */}}
{{- if not (has .Values.exporter.type (list "mqtt" "rest")) }}
{{- fail (printf "exporter.type must be \"mqtt\" or \"rest\", got %q" .Values.exporter.type) }}
{{- end }}

{{- /* Credentials are mandatory and can only come from one of these two. */}}
{{- if and (not .Values.existingSecret.name) (not .Values.envFrom) }}
{{- fail "set existingSecret.name, or supply the EcoFlow credentials through envFrom — the exporter exits without them" }}
{{- end }}

{{- if lt (int .Values.exporter.mqtt.pingIntervalSeconds) 1 }}
{{- fail "exporter.mqtt.pingIntervalSeconds must be at least 1" }}
{{- end }}

{{- end }}
