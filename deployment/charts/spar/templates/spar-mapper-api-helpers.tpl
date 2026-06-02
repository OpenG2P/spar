{{/*
Expand the name of the chart.
*/}}
{{- define "mapper.name" -}}
{{- $values := index .Values "sparMapperAPI" -}}
{{- default "spar-mapper-api" $values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mapper.fullname" -}}
{{- $values := index .Values "sparMapperAPI" -}}
{{- if $values.fullnameOverride }}
{{- $values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "spar-mapper-api" $values.nameOverride }}
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
{{- define "mapper.chart" -}}
{{- printf "%s-%s" "spar-mapper-api" .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mapper.labels" -}}
helm.sh/chart: {{ include "mapper.chart" . }}
{{ include "mapper.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mapper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mapper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mapper.serviceAccountName" -}}
{{- $values := index .Values "sparMapperAPI" -}}
{{- if $values.serviceAccount.create }}
{{- default (include "mapper.fullname" .) $values.serviceAccount.name }}
{{- else }}
{{- default "default" $values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "mapper.tpl" -}}
{{- $value := typeIs "string" .value | ternary .value (.value | toYaml) }}
{{- if contains "{{" (toJson .value) }}
  {{- tpl $value .context }}
{{- else }}
    {{- $value }}
{{- end }}
{{- end -}}

{{/*
Render Env values section
*/}}
{{- define "mapper.baseEnvVars" -}}
{{- $context := .context -}}
{{- range $k, $v := .envVars }}
- name: {{ $k }}
{{- if or (kindIs "int64" $v) (kindIs "float64" $v) (kindIs "bool" $v) }}
  value: {{ $v | quote }}
{{- else if kindIs "string" $v }}
  value: {{ include "mapper.tpl" (dict "value" $v "context" $context) | squote }}
{{- else }}
  valueFrom: {{- include "mapper.tpl" (dict "value" $v "context" $context) | nindent 4}}
{{- end }}
{{- end }}
{{- end -}}

{{- define "mapper.envVars" -}}
{{- $values := index .Values "sparMapperAPI" -}}
{{- $envVars := merge (deepCopy ($values.envVars | default dict)) (deepCopy ($values.envVarsFrom | default dict)) -}}
{{- include "mapper.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}
