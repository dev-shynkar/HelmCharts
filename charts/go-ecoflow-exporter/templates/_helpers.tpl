{{/*
Chart name
*/}}
{{- define "go-ecoflow-exporter.name" -}}
{{ .Chart.Name }}
{{- end }}

{{/*
Full name
*/}}
{{- define "go-ecoflow-exporter.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{/*
Validation logic
*/}}
{{- define "go-ecoflow-exporter.validate" -}}

{{- if eq .Values.exporter.type "mqtt" }}
{{- if and (not .Values.exporter.devices) (not .Values.exporter.devicesPrettyNames) }}
{{- fail "MQTT exporter requires exporter.devices or exporter.devicesPrettyNames" }}
{{- end }}
{{- if not .Values.existingSecret.name }}
{{- fail "MQTT exporter requires existingSecret with ECOFLOW_EMAIL and ECOFLOW_PASSWORD" }}
{{- end }}
{{- end }}

{{- if eq .Values.exporter.type "rest" }}
{{- if not .Values.existingSecret.name }}
{{- fail "REST exporter requires existingSecret with ECOFLOW_ACCESS_KEY and ECOFLOW_SECRET_KEY" }}
{{- end }}
{{- end }}

{{- end }}
