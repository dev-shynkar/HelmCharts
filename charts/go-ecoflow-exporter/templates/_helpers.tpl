{{- define "go-ecoflow-exporter.name" -}}
go-ecoflow-exporter
{{- end }}

{{- define "go-ecoflow-exporter.fullname" -}}
{{ include "go-ecoflow-exporter.name" . }}-{{ .Release.Name }}
{{- end }}
