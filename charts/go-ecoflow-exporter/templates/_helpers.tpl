{{/*
Name helpers
*/}}
{{- define "go-ecoflow-exporter.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "go-ecoflow-exporter.fullname" -}}
{{ .Release.Name }}
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
