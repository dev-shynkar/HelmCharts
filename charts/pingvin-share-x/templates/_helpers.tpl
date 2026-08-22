{{/*
Expand the name of the chart.
*/}}
{{- define "pingvin-share-x.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "pingvin-share-x.fullname" -}}
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

{{/*
Chart label.
*/}}
{{- define "pingvin-share-x.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "pingvin-share-x.labels" -}}
helm.sh/chart: {{ include "pingvin-share-x.chart" . }}
{{ include "pingvin-share-x.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: {{ include "pingvin-share-x.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "pingvin-share-x.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pingvin-share-x.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "pingvin-share-x.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pingvin-share-x.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image reference. Falls back to "v<appVersion>" so the image cannot
drift away from the chart, and prefers a digest when one is given.
*/}}
{{- define "pingvin-share-x.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- $tag := .Values.image.tag | default (printf "v%s" .Chart.AppVersion) -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Name of the PVC (or existing claim) backing the backend data directory.
*/}}
{{- define "pingvin-share-x.dataClaimName" -}}
{{- .Values.data.persistence.existingClaim | default (printf "%s-data" (include "pingvin-share-x.fullname" .)) -}}
{{- end }}

{{/*
Name of the PVC (or existing claim) backing the frontend image directory.
*/}}
{{- define "pingvin-share-x.imagesClaimName" -}}
{{- .Values.images.persistence.existingClaim | default (printf "%s-images" (include "pingvin-share-x.fullname" .)) -}}
{{- end }}

{{/*
Name of the Secret holding config.yaml.
*/}}
{{- define "pingvin-share-x.configSecretName" -}}
{{- .Values.config.existingSecret | default (printf "%s-config" (include "pingvin-share-x.fullname" .)) -}}
{{- end }}

{{/*
Environment variables.

The port wiring is derived from .Values.containerPorts so the Service, the probes
and the processes inside the container can never disagree:

  CADDY_DISABLED  the chart routes /api from the Ingress, so the bundled Caddy
                  (which is the only thing that would listen on :3000) stays off
  BACKEND_PORT    the port the NestJS backend binds to
  API_URL         where the Next.js server-side renderer reaches that backend

.Values.env is merged on top, so users can override any of them.
*/}}
{{- define "pingvin-share-x.env" -}}
{{- $defaults := dict
      "CADDY_DISABLED" "true"
      "BACKEND_PORT" (.Values.containerPorts.api | toString)
      "API_URL" (printf "http://127.0.0.1:%v" .Values.containerPorts.api)
-}}
{{- if .Values.config.enabled -}}
{{- $_ := set $defaults "CONFIG_FILE" "/opt/app/config/config.yaml" -}}
{{- end -}}
{{- if .Values.uvThreadpoolSize -}}
{{- $_ := set $defaults "UV_THREADPOOL_SIZE" (.Values.uvThreadpoolSize | toString) -}}
{{- end -}}
{{- /*
  Explicit hasKey check rather than `merge`: sprig's merge is backed by mergo,
  which treats zero values in the destination as absent, so `env.CADDY_DISABLED:
  false` (a bool, not a string) would be silently replaced by the default.
*/}}
{{- $userEnv := .Values.env | default dict -}}
{{- range $name, $value := $defaults }}
{{- if not (hasKey $userEnv $name) }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- range $name, $value := $userEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end -}}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end -}}
{{- end }}
