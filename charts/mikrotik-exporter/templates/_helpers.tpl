{{- define "mikrotik-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mikrotik-exporter.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "mikrotik-exporter.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "mikrotik-exporter.labels" -}}
app.kubernetes.io/name: {{ include "mikrotik-exporter.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "mikrotik-exporter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mikrotik-exporter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}