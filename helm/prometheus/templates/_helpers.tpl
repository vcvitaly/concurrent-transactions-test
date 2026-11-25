{{- define "prometheus.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The Service is named after the release, so the default release gives a Service called "prometheus". */}}
{{- define "prometheus.fullname" -}}
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

{{- define "prometheus.selectorLabels" -}}
app.kubernetes.io/name: {{ include "prometheus.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "prometheus.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "prometheus.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "prometheus.config" -}}
global:
  scrape_interval: {{ .Values.scrape.interval }}
  evaluation_interval: {{ .Values.scrape.interval }}

# Only the app is scraped. Prometheus doesn't scrape itself: teardown reads its /metrics directly.
scrape_configs:
  - job_name: concurrent-transactions
    scrape_interval: {{ .Values.scrape.interval }}
    metrics_path: {{ .Values.scrape.path }}
    dns_sd_configs:
      - names:
          - {{ required "scrape.dnsName is required (the app's headless metrics Service)" .Values.scrape.dnsName | quote }}
        type: A
        port: {{ .Values.scrape.port }}
        refresh_interval: 5s
{{- with .Values.remoteWrite.url }}

remote_write:
  - url: {{ . | quote }}
{{- end }}
{{- end }}
