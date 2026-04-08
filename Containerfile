#
# Copyright (C) 2026 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
FROM registry.access.redhat.com/ubi10/ubi-minimal:10.1

USER root

RUN microdnf install -y \
    git \
    curl \
    tar \
    gzip \
    diffutils \
    patch \
    findutils \
    which \
    jq \
    make \
    openssh-clients \
    procps-ng \
    python3 \
    python3-pip \
    && microdnf clean all

RUN useradd -m -d /home/opencode -s /bin/bash opencode

RUN python3 -m venv /opt/venv && chown -R opencode:opencode /opt/venv

USER opencode

RUN mkdir -p /home/opencode/workspace && \
    git -C /home/opencode/workspace init

WORKDIR /home/opencode/workspace

ENV PATH="/opt/venv/bin:/home/opencode/.opencode/bin:$PATH" \
    HOME="/home/opencode"

RUN curl -fsSL https://opencode.ai/install | bash && \
    chmod -R g=u /home/opencode/.opencode

ENTRYPOINT [ "opencode" ]
