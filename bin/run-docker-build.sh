#!/usr/bin/env bash

set -e
set -o pipefail

echo "> Starting 'run-docker-build.sh' ($(date))"

echo "> Working directory: $(pwd)"

if [[ -x build-tools/bin/suite-runner ]]; then
    export DOCKER_NORMAL_BUILD='true'
    export DOCKER_BUILDKIT=1
    export RUN_TEST_SUITE=none
    export DOCKER_BUILD_OPTIONS='--skip-from'

    echo "> Starting suite-runner"
    build-tools/bin/suite-runner

else
    echo "The script does not exist or did not have execute permissions: build-tools/bin/suite-runner"
    stat build-tools/bin/suite-runner || true
fi

echo "> Finished 'run-docker-build.sh' ($(date))"
