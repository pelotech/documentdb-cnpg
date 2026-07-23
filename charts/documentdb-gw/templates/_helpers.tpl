{{- define "documentdb-gw.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "documentdb-gw.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}{{ printf "%s-%s" .Release.Name (include "documentdb-gw.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}{{- end -}}

{{- define "documentdb-gw.labels" -}}
app.kubernetes.io/name: {{ include "documentdb-gw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "documentdb-gw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "documentdb-gw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* PG host: explicit override, else <cluster>-rw.<ns>.svc (FQDN, matching docs/gateway + e2e) */}}
{{- define "documentdb-gw.pgHost" -}}
{{- if .Values.gateway.pg.host -}}{{ .Values.gateway.pg.host -}}
{{- else -}}{{ printf "%s-rw.%s.svc" .Values.cluster.name .Release.Namespace -}}{{- end -}}
{{- end -}}

{{/* backend CA secret: explicit override, else <cluster>-ca */}}
{{- define "documentdb-gw.caSecret" -}}
{{- if .Values.gateway.pg.caSecret -}}{{ .Values.gateway.pg.caSecret -}}
{{- else -}}{{ printf "%s-ca" .Values.cluster.name -}}{{- end -}}
{{- end -}}

{{/* PG password secret: chart-managed in create mode, else existingSecret */}}
{{- define "documentdb-gw.pgSecretName" -}}
{{- if .Values.gateway.pg.existingSecret -}}{{ .Values.gateway.pg.existingSecret -}}
{{- else -}}{{ printf "%s-pg" (include "documentdb-gw.fullname" .) -}}{{- end -}}
{{- end -}}

{{/* fail-fast validation: attach mode requires backend refs; certManager needs an issuerRef */}}
{{- define "documentdb-gw.validate" -}}
{{- if not .Values.cluster.create -}}
{{- if not .Values.gateway.pg.existingSecret -}}{{ fail "cluster.create=false requires gateway.pg.existingSecret (the backend password secret)" }}{{- end -}}
{{- if not .Values.gateway.pg.caSecret -}}{{ fail "cluster.create=false requires gateway.pg.caSecret (the backend CA secret)" }}{{- end -}}
{{- if and (not .Values.gateway.pg.host) (eq .Values.cluster.name "ddb-pg") -}}{{ fail "cluster.create=false requires gateway.pg.host or cluster.name set to the existing cluster" }}{{- end -}}
{{- end -}}
{{- if and (eq .Values.gateway.listenerTLS.mode "certManager") (not .Values.gateway.listenerTLS.certManager.issuerRef.name) -}}{{ fail "listenerTLS.mode=certManager requires gateway.listenerTLS.certManager.issuerRef.name" }}{{- end -}}
{{- if and (eq .Values.gateway.listenerTLS.mode "existing") (not .Values.gateway.listenerTLS.existingSecret) -}}{{ fail "listenerTLS.mode=existing requires gateway.listenerTLS.existingSecret" }}{{- end -}}
{{- end -}}

{{/* listener TLS secret name per mode */}}
{{- define "documentdb-gw.listenerTlsSecretName" -}}
{{- if eq .Values.gateway.listenerTLS.mode "existing" -}}{{ .Values.gateway.listenerTLS.existingSecret -}}
{{- else -}}{{ printf "%s-listener-tls" (include "documentdb-gw.fullname" .) -}}{{- end -}}
{{- end -}}
