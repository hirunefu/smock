{{/*
Fails rendering, with a message that says what to change, for values that
would make a Pod that cannot start or does not do what they ask.
*/}}
{{- define "smock.validate" -}}
{{- if not (kindIs "invalid" .Values.terminationGracePeriodSeconds) -}}
{{- if le (mul (int64 .Values.terminationGracePeriodSeconds) 1000) (int64 .Values.drainTimeoutMs) -}}
{{- fail (printf "terminationGracePeriodSeconds (%s) must be above the drain timeout, drainTimeoutMs (%s ms), or Kubernetes kills smock before it has drained: raise it, or leave it empty for the drain timeout plus 10 s" (include "smock.string" .Values.terminationGracePeriodSeconds) (include "smock.string" .Values.drainTimeoutMs)) -}}
{{- end -}}
{{- end -}}
{{- /* The variables the chart sets itself, and the values that set them.
A variable added to the Deployment's env is added here too:
scripts/test-helm-chart.sh fails until it is. */ -}}
{{- $own := dict
  "SMOCK_DIR" "definitions.source"
  "SMOCK_BODY_FILE_DIR" "definitions.bodyFileDir"
  "SMOCK_PORT" "ports.plain"
  "SMOCK_TLS_PORT" "ports.tls"
  "SMOCK_ADMIN_PORT" "ports.admin"
  "SMOCK_ADMIN_AUTH" "adminAuth.enabled"
  "SMOCK_ADMIN_TOKEN" "adminAuth.tokenSecret"
  "SMOCK_ADMIN_TOKEN_FILE" "adminAuth.tokenSecret"
  "SMOCK_TLS_CERT_FILE" "tls.secretName"
  "SMOCK_TLS_KEY_FILE" "tls.secretName"
  "SMOCK_REPLICAS" "replicas"
  "SMOCK_DRAIN_TIMEOUT_MS" "drainTimeoutMs" -}}
{{- range $name, $_ := .Values.env -}}
{{- if not (regexMatch "^SMOCK_[A-Z0-9_]+$" $name) -}}
{{- fail (printf "env: %q is not a smock setting: its name must be SMOCK_ and the setting's name in upper case, such as SMOCK_IDLE_TIMEOUT_MS for --idle-timeout-ms" $name) -}}
{{- end -}}
{{- if hasKey $own $name -}}
{{- fail (printf "env: the chart sets %s itself: use the value %s instead" $name (get $own $name)) -}}
{{- end -}}
{{- end -}}
{{- $auth := .Values.adminAuth -}}
{{- if and $auth.enabled (not $auth.tokenSecret.name) -}}
{{- fail "adminAuth.tokenSecret.name is empty, but Admin API authentication is on (adminAuth.enabled), and smock refuses to start without a token: name a Secret that holds the token under the key adminAuth.tokenSecret.key, or, for local use only, set adminAuth.enabled=false" -}}
{{- end -}}
{{- if not (has $auth.tokenAs (list "file" "env")) -}}
{{- fail (printf "adminAuth.tokenAs must be \"file\" or \"env\", not %q" (toString $auth.tokenAs)) -}}
{{- end -}}
{{- $d := .Values.definitions -}}
{{- if not (has $d.source (list "configMap" "gitSync" "image")) -}}
{{- fail (printf "definitions.source must be \"configMap\", \"gitSync\" or \"image\", not %q" (toString $d.source)) -}}
{{- end -}}
{{- if and (eq $d.source "gitSync") (not $d.gitSync.repo) -}}
{{- fail "definitions.gitSync.repo is empty, but definitions.source is gitSync: give the URL of the Git repository that holds the Definition files" -}}
{{- end -}}
{{- if and (eq $d.source "image") (not $d.image.reference) -}}
{{- fail "definitions.image.reference is empty, but definitions.source is image: give the reference of the OCI image that holds the Definition files" -}}
{{- end -}}
{{- $cm := .Values.definitions.configMap -}}
{{- if and (ne $d.source "configMap") (or $cm.name $cm.items $cm.files $cm.bodyFiles) -}}
{{- fail (printf "definitions.configMap is set, but definitions.source is %s, which does not read a ConfigMap: set definitions.source=configMap, or leave definitions.configMap empty" $d.source) -}}
{{- end -}}
{{- if and $cm.name (or $cm.files $cm.bodyFiles) -}}
{{- fail "definitions.configMap.name names an existing ConfigMap, so definitions.configMap.files and definitions.configMap.bodyFiles must be empty: put the files in that ConfigMap, or leave the name empty for the chart to make one" -}}
{{- end -}}
{{- if and $cm.items (not $cm.name) -}}
{{- fail "definitions.configMap.items places the keys of an existing ConfigMap, so it needs definitions.configMap.name" -}}
{{- end -}}
{{- /* A ConfigMap key, at the top level, with an extension smock reads. */ -}}
{{- range $name, $_ := $cm.files -}}
{{- if not (regexMatch "^[-_a-zA-Z0-9][-._a-zA-Z0-9]*\\.(json|yaml|yml)$" $name) -}}
{{- fail (printf "definitions.configMap.files: %q is not the name of a Definition file: it must end in .json, .yaml or .yml, not start with \".\", and hold only letters, digits, \"-\", \"_\" and \".\"" $name) -}}
{{- end -}}
{{- end -}}
{{- /* Relative, with no empty, "." or ".." segment, and no segment that smock skips because it starts with ".". */ -}}
{{- $relative := "^[^/.][^/]*(/[^/.][^/]*)*$" -}}
{{- range $path, $_ := $cm.bodyFiles -}}
{{- if not (regexMatch $relative $path) -}}
{{- fail (printf "definitions.configMap.bodyFiles: %q is not a relative path inside the body-file subdirectory: it must not start with \"/\", and none of its parts may be empty or start with \".\"" $path) -}}
{{- end -}}
{{- end -}}
{{- if not (regexMatch $relative (toString .Values.definitions.bodyFileDir)) -}}
{{- fail (printf "definitions.bodyFileDir: %q is not a relative path inside the definitions directory: it must not be empty or start with \"/\", and none of its parts may be empty or start with \".\"" (toString .Values.definitions.bodyFileDir)) -}}
{{- end -}}
{{- end -}}
