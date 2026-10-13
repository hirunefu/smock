{{/*
The name of the chart's objects: the release name, with the chart name
appended unless the release name already contains it.
*/}}
{{- define "smock.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* The name of the admin Service. */}}
{{- define "smock.adminServiceName" -}}
{{- printf "%s-admin" (include "smock.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The labels that select the Pods of this release. */}}
{{- define "smock.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* The labels of every object. */}}
{{- define "smock.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "smock.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* The name of the ConfigMap the Definition files come from. */}}
{{- define "smock.definitionsConfigMap" -}}
{{- .Values.definitions.configMap.name | default (printf "%s-definitions" (include "smock.fullname" .) | trunc 63 | trimSuffix "-") -}}
{{- end -}}

{{/*
The ConfigMap key of a body file, given its path relative to the body-file
subdirectory. Keys cannot hold "/", so the key is made from a hash of the
path, and the volume's items put it back at its path.
*/}}
{{- define "smock.bodyFileKey" -}}
{{- printf "body-%s" (sha256sum . | trunc 20) -}}
{{- end -}}

{{/*
The items of the definitions volume, as a YAML list, or nothing when the
whole ConfigMap is mounted as it is. The ConfigMap the chart makes needs
items only for body files, which go under the body-file subdirectory; once
there are items, every Definition file needs one too. The items are part of
the Pod template, so with them a file added, removed or renamed restarts
the Pods; new content for the same files still reaches smock by reload.
*/}}
{{- define "smock.definitionsItems" -}}
{{- $cm := .Values.definitions.configMap -}}
{{- if $cm.name -}}
{{- with $cm.items }}{{ toYaml . }}{{ end -}}
{{- else if $cm.bodyFiles -}}
{{- range $name, $_ := $cm.files }}
- key: {{ $name | quote }}
  path: {{ $name | quote }}
{{- end }}
{{- range $path, $_ := $cm.bodyFiles }}
- key: {{ include "smock.bodyFileKey" $path }}
  path: {{ printf "%s/%s" $.Values.definitions.bodyFileDir $path | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
The security context of a container, for the Restricted Pod Security
Standard: a numeric non-root UID (the argument), a read-only root
filesystem, no privilege escalation, no capabilities and the runtime
default seccomp profile.
*/}}
{{- define "smock.containerSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ . }}
runAsGroup: {{ . }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Where smock's container mounts the definitions volume, and the definitions
directory smock reads, for each delivery mode. git-sync publishes each
commit it syncs by swapping the symlink "current" under its root and then
removing the worktree it replaced, which leads smock's file reload to the
new one (e2e/reload_test.mbt has a test of that).
*/}}
{{- define "smock.definitionsMountPath" -}}
{{- if eq .Values.definitions.source "gitSync" -}}/git{{- else -}}/definitions{{- end -}}
{{- end -}}

{{- define "smock.definitionsDir" -}}
{{- $d := .Values.definitions -}}
{{- if eq $d.source "gitSync" -}}
{{- list "/git/current" ($d.gitSync.path | trimAll "/") | compact | join "/" -}}
{{- else if eq $d.source "image" -}}
{{- list "/definitions" ($d.image.path | trimAll "/") | compact | join "/" -}}
{{- else -}}
/definitions
{{- end -}}
{{- end -}}

{{/*
A git-sync container that syncs the repository into the definitions volume:
the init container, which syncs once so that smock starts with its files
(oneTime), or the sidecar, which keeps syncing.
*/}}
{{- define "smock.gitSyncContainer" -}}
{{- $g := .root.Values.definitions.gitSync -}}
- name: {{ ternary "git-sync-init" "git-sync" .oneTime }}
  image: {{ printf "%s:%s" $g.image.repository $g.image.tag }}{{ with $g.image.digest }}@{{ . }}{{ end }}
  imagePullPolicy: {{ $g.image.pullPolicy }}
  args:
    - {{ printf "--repo=%s" $g.repo | quote }}
    - {{ printf "--ref=%s" $g.ref | quote }}
    - --root=/git
    - --link=current
    - {{ printf "--depth=%v" $g.depth | quote }}
    {{- if .oneTime }}
    - --one-time
    {{- else }}
    - {{ printf "--period=%s" $g.period | quote }}
    {{- end }}
    {{- range $g.extraArgs }}
    - {{ . | quote }}
    {{- end }}
  {{- with $g.env }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $g.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- include "smock.containerSecurityContext" $g.uid | nindent 4 }}
  volumeMounts:
    - name: definitions
      mountPath: /git
    {{- /* git-sync's HOME, for its Git configuration. */}}
    - name: git-sync-home
      mountPath: /tmp
{{- end -}}

{{/*
The volume of the Secret with a Mock's own certificate, and the directory
where the smock container mounts it, given the Mock's name. Both are named
after a hash of it, since a Mock name may hold any character.
*/}}
{{- define "smock.tlsMockVolume" -}}
{{- printf "tls-mock-%s" (sha256sum . | trunc 20) -}}
{{- end -}}

{{- define "smock.tlsMockDir" -}}
{{- printf "/etc/smock/tls-mocks/%s" (sha256sum . | trunc 20) -}}
{{- end -}}

{{/*
smock's --tls-mock-certs: the tls.crt and tls.key of each Mock's Secret, as
the JSON object smock reads.
*/}}
{{- define "smock.tlsMockCerts" -}}
{{- $certs := dict -}}
{{- range $mock, $secret := .Values.tls.mockSecrets -}}
{{- $dir := include "smock.tlsMockDir" $mock -}}
{{- $_ := set $certs $mock (dict "certFile" (printf "%s/tls.crt" $dir) "keyFile" (printf "%s/tls.key" $dir)) -}}
{{- end -}}
{{- toJson $certs -}}
{{- end -}}

{{/*
A value as the text of an environment variable. Numbers from values files
reach templates as floating point, which Go would write as 1.048576e+07;
whole ones are written out in full.
*/}}
{{- define "smock.string" -}}
{{- if and (kindIs "float64" .) (eq (float64 (int64 .)) .) -}}
{{- int64 . -}}
{{- else -}}
{{- toString . -}}
{{- end -}}
{{- end -}}

{{/*
How long Kubernetes waits after SIGTERM before it kills the Pod: the value,
or else the drain timeout rounded up to a second, plus 10 s. It is always
above the drain timeout (smock.validate), so that smock can drain.
*/}}
{{- define "smock.terminationGracePeriodSeconds" -}}
{{- if kindIs "invalid" .Values.terminationGracePeriodSeconds -}}
{{- add (div (add (int64 .Values.drainTimeoutMs) 999) 1000) 10 -}}
{{- else -}}
{{- int64 .Values.terminationGracePeriodSeconds -}}
{{- end -}}
{{- end -}}

{{/* The smock image's own user, nonroot of its distroless base. */}}
{{- define "smock.uid" -}}65532{{- end -}}

{{/* The smock image: the tag defaults to the chart's appVersion. */}}
{{- define "smock.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
