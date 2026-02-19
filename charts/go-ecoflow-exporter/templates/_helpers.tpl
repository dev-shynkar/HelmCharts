{{/*
Name helpers
*/}}
{{- define "go-ecoflow-exporter.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "go-ecoflow-exporter.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "go-ecoflow-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "go-ecoflow-exporter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "go-ecoflow-exporter.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Validation logic
*/}}
{{- define "go-ecoflow-exporter.validate" -}}

{{- if not .Values.existingSecret.name }}
{{- fail "existingSecret.name must be set" }}
{{- end }}

{{- if eq .Values.exporter.type "mqtt" }}
{{- /* devices are validated by the application at runtime */ -}}
{{- end }}

{{- if eq .Values.exporter.type "rest" }}
{{- /* credentials validated by the application */ -}}
{{- end }}

{{- end }}
