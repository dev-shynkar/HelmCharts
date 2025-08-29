{{- /*
Return the name of the chart
*/ -}}
{{- define "transmission.name" -}}
{{- if .Values.nameOverride }}
{{- .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- /*
Return the fullname of the release, з урахуванням fullnameOverride
*/ -}}
{{- define "transmission.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "transmission.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
