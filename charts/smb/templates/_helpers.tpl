{{/* Ім'я чарту */}}
{{- define "samba.name" -}}
samba
{{- end }}

{{/* Повне ім'я release + chart */}}
{{- define "samba.fullname" -}}
{{ .Release.Name }}-{{ include "samba.name" . }}
{{- end }}

{{/* Chart name + версія */}}
{{- define "samba.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
