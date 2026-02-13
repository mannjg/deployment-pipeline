#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <repo-path>" >&2
    exit 1
fi

REPO_PATH="$1"

SETTINGS="$(mktemp --suffix=-maven-settings.xml)"
trap 'rm -f "$SETTINGS"' EXIT

cat > "$SETTINGS" <<SETTINGS_EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings>
  <servers>
    <server>
      <id>nexus</id>
      <username>${MAVEN_REPO_CREDENTIALS_USR}</username>
      <password>${MAVEN_REPO_CREDENTIALS_PSW}</password>
    </server>
  </servers>
</settings>
SETTINGS_EOF

mvn clean deploy -DskipTests \
    -s "$SETTINGS" \
    -DaltDeploymentRepository=nexus::default::${MAVEN_REPO_URL}/repository/${REPO_PATH}/

mvn package \
    -Dquarkus.container-image.build=true \
    -Dquarkus.container-image.push=true \
    -Dquarkus.container-image.registry=${CONTAINER_REGISTRY} \
    -Dquarkus.container-image.group=${APP_GROUP} \
    -Dquarkus.container-image.name=${APP_NAME} \
    -Dquarkus.container-image.tag=${IMAGE_TAG} \
    -Dquarkus.container-image.insecure=true \
    -Dquarkus.container-image.username=${CONTAINER_REGISTRY_CREDENTIALS_USR} \
    -Dquarkus.container-image.password=${CONTAINER_REGISTRY_CREDENTIALS_PSW} \
    -DsendCredentialsOverHttp=true
