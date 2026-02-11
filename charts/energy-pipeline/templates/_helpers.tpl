{{/*
Expand the name of the chart.
*/}}
{{- define "energy-pipeline.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "energy-pipeline.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "energy-pipeline.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "energy-pipeline.labels" -}}
helm.sh/chart: {{ include "energy-pipeline.chart" . }}
{{ include "energy-pipeline.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
assignment-id: {{ .Values.assignmentId | quote }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "energy-pipeline.selectorLabels" -}}
app.kubernetes.io/name: {{ include "energy-pipeline.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Ingestion API labels
*/}}
{{- define "energy-pipeline.ingestionApi.labels" -}}
{{ include "energy-pipeline.labels" . }}
app.kubernetes.io/component: ingestion-api
{{- end }}

{{/*
Ingestion API selector labels
*/}}
{{- define "energy-pipeline.ingestionApi.selectorLabels" -}}
{{ include "energy-pipeline.selectorLabels" . }}
app.kubernetes.io/component: ingestion-api
{{- end }}

{{/*
Processing Service labels
*/}}
{{- define "energy-pipeline.processingService.labels" -}}
{{ include "energy-pipeline.labels" . }}
app.kubernetes.io/component: processing-service
{{- end }}

{{/*
Processing Service selector labels
*/}}
{{- define "energy-pipeline.processingService.selectorLabels" -}}
{{ include "energy-pipeline.selectorLabels" . }}
app.kubernetes.io/component: processing-service
{{- end }}

{{/*
Redis host
*/}}
{{- define "energy-pipeline.redisHost" -}}
{{- if .Values.redis.enabled }}
{{- printf "%s-redis-master" .Release.Name }}
{{- else }}
{{- .Values.externalRedis.host }}
{{- end }}
{{- end }}
