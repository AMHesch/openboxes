#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
region=us-east-1
expected_account=077510937834
java_home="$HOME/.local/jdks/jdk8u504-b01"
war="$repo_root/build/docker/openboxes.war"

if [[ ! -f "$war" ]]; then
  JAVA_HOME="$java_home" \
    PATH="$java_home/bin:$PATH" \
    GRADLE_OPTS='-Xmx3g -XX:MaxMetaspaceSize=768m' \
    "$repo_root/gradlew" prepareDocker -Dgrails.env=prod --no-daemon
fi

if [[ ! -f "$war" ]]; then
  printf 'WAR build completed without creating %s\n' "$war" >&2
  exit 1
fi

account="$(aws sts get-caller-identity --region "$region" --query Account --output text)"
if [[ "$account" != "$expected_account" ]]; then
  printf 'Refusing image push in account %s; expected %s\n' "$account" "$expected_account" >&2
  exit 1
fi

repository_uri="$(aws cloudformation describe-stacks \
  --stack-name openboxes-demo-data \
  --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='EcrRepositoryUri'].OutputValue | [0]" \
  --output text)"
if [[ -z "$repository_uri" || "$repository_uri" == None ]]; then
  echo 'The data stack has no ECR repository URI output.' >&2
  exit 1
fi

git_sha="$(git -C "$repo_root" rev-parse --short HEAD)"
image_tag="${git_sha}-$(date +%s)"
base_image="openboxes-demo-base:$image_tag"
derived_image="$repository_uri:$image_tag"

docker build \
  --file "$repo_root/build/docker/Dockerfile" \
  --tag "$base_image" \
  "$repo_root/build/docker" >&2
docker build \
  --build-arg "BASE_IMAGE=$base_image" \
  --file "$script_dir/image/Dockerfile" \
  --tag "$derived_image" \
  "$script_dir/image" >&2

registry="${repository_uri%%/*}"
aws ecr get-login-password --region "$region" |
  docker login --username AWS --password-stdin "$registry" >&2
docker push "$derived_image" >&2

digest="$(aws ecr describe-images \
  --repository-name openboxes-demo \
  --image-ids "imageTag=$image_tag" \
  --region "$region" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"
if [[ -z "$digest" || "$digest" == None ]]; then
  echo 'ECR did not return an image digest after push.' >&2
  exit 1
fi

printf '%s@%s\n' "$repository_uri" "$digest"
