{{/* Chart name. */}}
{{- define "cadmium.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name, truncated so that the longest suffix ("-headless") still
fits in a 63 character DNS label.
*/}}
{{- define "cadmium.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 54 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 54 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 54 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "cadmium.agentName" -}}
{{- printf "%s-agent" (include "cadmium.fullname" .) }}
{{- end }}

{{- define "cadmium.headlessServiceName" -}}
{{- printf "%s-headless" (include "cadmium.fullname" .) }}
{{- end }}

{{- define "cadmium.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels for every resource. */}}
{{- define "cadmium.labels" -}}
helm.sh/chart: {{ include "cadmium.chart" . }}
{{ include "cadmium.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cadmium
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels. These are immutable on a DaemonSet: never add anything here that can
change between upgrades (versions, chart labels, user-supplied labels).
*/}}
{{- define "cadmium.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cadmium.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: agent
{{- end }}

{{- define "cadmium.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cadmium.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "cadmium.secretName" -}}
{{- default (include "cadmium.fullname" .) .Values.secret.existingSecret }}
{{- end }}

{{- define "cadmium.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* PHX_HOST: explicit value, else the first ingress host, else localhost. */}}
{{- define "cadmium.host" -}}
{{- if .Values.dashboard.host }}
{{- .Values.dashboard.host }}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts }}
{{- (first .Values.ingress.hosts).host }}
{{- else -}}
localhost
{{- end }}
{{- end }}
