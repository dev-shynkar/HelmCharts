{{- define "tapo-exporter.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tapo-exporter.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "tapo-exporter.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "tapo-exporter.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "tapo-exporter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tapo-exporter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tapo-exporter.secretName" -}}
{{- default (include "tapo-exporter.fullname" .) .Values.credentials.existingSecret }}
{{- end }}

{{/* Validate values early with readable errors. */}}
{{- define "tapo-exporter.validate" -}}
{{- if not .Values.image.repository }}
{{- fail "image.repository is required (build the image from the repo Dockerfile and push it to a registry)" }}
{{- end }}
{{- if not .Values.devices }}
{{- fail "devices is required: group -> name -> IP, see values.yaml" }}
{{- end }}
{{- range $group, $devs := .Values.devices }}
{{- if not (kindIs "map" $devs) }}
{{- fail (printf "devices.%v must be a map of name: IP" $group) }}
{{- end }}
{{- end }}
{{- if and (not .Values.credentials.existingSecret) (or (not .Values.credentials.email) (not .Values.credentials.password)) }}
{{- fail "set credentials.existingSecret, or credentials.email and credentials.password" }}
{{- end }}
{{- if ne (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: each replica polls every plug separately (use exporter.cacheTTL for several Prometheus servers)" }}
{{- end }}
{{- end }}
