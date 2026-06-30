{{/*
Build the JSON list of partner certs seeded into the partner_keys table at
migrate-time (local crypto backend): operator-provided global.sparPartnerCerts
plus, when the trial test partner is enabled, the committed test cert under
PARTNER_<MNEMONIC> for each global.testPartnerMnemonics (incl. PARTNER_G2P_BRIDGE).
Compact JSON (PEM newlines escaped) for the SPAR_MAPPER_PARTNER_API_CRYPTO_PARTNER_CERTS
env var. Reads global only, so it works from the component-scoped env render context.
*/}}
{{- define "openg2p-spar.partnerCertsJson" -}}
{{- $g := .Values.global -}}
{{- $certs := list -}}
{{- range $g.sparPartnerCerts -}}
{{- $certs = append $certs (dict "reference_id" .referenceId "public_key" .publicKey) -}}
{{- end -}}
{{- if $g.testPartnerEnabled -}}
{{- range $g.testPartnerMnemonics -}}
{{- $certs = append $certs (dict "reference_id" (printf "PARTNER_%s" .) "public_key" $g.testPartnerCertPem) -}}
{{- end -}}
{{- end -}}
{{- $certs | toJson -}}
{{- end -}}

{{/*
Expand the name of the chart.
*/}}
{{- define "spar.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "spar.fullname" -}}
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
{{- define "spar.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "spar.labels" -}}
helm.sh/chart: {{ include "spar.chart" . }}
{{ include "spar.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "spar.selectorLabels" -}}
app.kubernetes.io/name: {{ include "spar.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
