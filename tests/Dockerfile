# Image for running lint and unit tests locally: make docker-test [UBUNTU=24.04]
ARG UBUNTU=26.04
FROM ubuntu:${UBUNTU}
RUN apt-get update && apt-get install -y --no-install-recommends bats shellcheck procps util-linux tzdata make \
    && rm -rf /var/lib/apt/lists/* && useradd -m tester
ENV LANG=C.UTF-8
USER tester
WORKDIR /src
