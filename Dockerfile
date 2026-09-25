FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=Etc/UTC

# ports.ubuntu.com (the arm64 mirror) has outage spells; pass e.g.
#   --build-arg UBUNTU_MIRROR=https://mirror.kumi.systems/ubuntu-ports
# to build via an alternative mirror. Empty = keep the default.
ARG UBUNTU_MIRROR=""
RUN if [ -n "$UBUNTU_MIRROR" ]; then \
        sed -i "s|http://ports.ubuntu.com/ubuntu-ports|$UBUNTU_MIRROR|g" \
            /etc/apt/sources.list.d/ubuntu.sources; \
    fi

# Create non-root user (handle UID 1000 conflicts on Ubuntu base images)
ARG USERNAME=agent
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN apt-get update && apt-get install -y --no-install-recommends locales sudo \
    && locale-gen en_US.UTF-8 \
    && EXISTING_USER=$(getent passwd "$USER_UID" | cut -d: -f1) \
    && if [ -n "$EXISTING_USER" ]; then \
           if [ "$EXISTING_USER" != "$USERNAME" ]; then \
               usermod  -l "$USERNAME" "$EXISTING_USER"; \
               usermod  -d "/home/$USERNAME" -m "$USERNAME"; \
               groupmod -n "$USERNAME" "$EXISTING_USER"; \
           fi; \
       else \
           groupadd --gid "$USER_GID" "$USERNAME"; \
           useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$USERNAME"; \
       fi

# No general sudo in the image. Strict is the default: the agent has no root,
# so it cannot flush the egress firewall (`sudo iptables -F OUTPUT`). A sandbox
# created with --allow-sudo gets /etc/sudoers.d/$USERNAME written at boot by
# sandbox-privileged-boot.sh, and every other boot removes it again, so the mode
# is a per-boot decision rather than a one-way change to the container. The
# host can also grant it to a running sandbox until its next restart
# (`agent-sandbox sudo <container> on`). See docs/UPSTREAM-DOCKER-IMPROVEMENTS.md §1.

# Base system tools (includes iptables/ipset/aggregate for the egress firewall;
# adb is the client for driving an Android emulator on the host — see
# android-testing.md)
RUN apt-get update && apt-get install -y --no-install-recommends \
    adb \
    aggregate \
    bash \
    bash-completion \
    build-essential \
    ca-certificates \
    curl \
    diffutils \
    dnsutils \
    fd-find \
    file \
    fzf \
    gawk \
    gh \
    git \
    git-delta \
    gnupg2 \
    htop \
    iproute2 \
    iptables \
    ipset \
    jq \
    less \
    lsof \
    make \
    man-db \
    nano \
    postgresql-client \
    procps \
    ripgrep \
    rsync \
    sed \
    shellcheck \
    socat \
    tree \
    unzip \
    vim \
    wget \
    yamllint \
    zip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Python (system + pip)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install common global npm tools
RUN npm install -g typescript ts-node pnpm yarn

# Playwright + chromium with system deps.
# `playwright install --with-deps` handles Ubuntu 24.04's renamed packages
# (libcups2t64, etc.) that direct apt-get installs would miss.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN pip install playwright \
    && mkdir -p /opt/playwright-browsers \
    && playwright install --with-deps chromium \
    && chmod -R a+rX /opt/playwright-browsers \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Environment
ENV TZ="$TZ"
ENV DEVCONTAINER=true
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV CLAUDE_CONFIG_DIR="/home/$USERNAME/.claude"
# Claude Code's own copy-on-select needs a clipboard the container doesn't have,
# so give mouse drag back to the host terminal. Wheel scrolling still works.
ENV CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1

# Runtime `npm install -g` targets an agent-writable prefix instead of /usr,
# so installing an agent at boot needs no root. That is what lets the default
# strict sandbox run without the agent ever having general root. Build-time
# globals above were installed as root into /usr and stay there.
ENV NPM_CONFIG_PREFIX="/home/$USERNAME/.npm-global"

# Create workspace and config directories
RUN mkdir -p /workspaces /home/$USERNAME/.claude/skills /home/$USERNAME/.config/gh /home/$USERNAME/.copilot /home/$USERNAME/.vibe /home/$USERNAME/.npm-global/bin
RUN echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' | tee -a /home/$USERNAME/.bashrc /home/$USERNAME/.profile \
    && echo 'alias claude="claude --dangerously-skip-permissions"' | tee -a /home/$USERNAME/.bashrc /home/$USERNAME/.profile
RUN chown -R $USERNAME:$USERNAME /workspaces /home/$USERNAME/.claude /home/$USERNAME/.config /home/$USERNAME/.copilot /home/$USERNAME/.vibe /home/$USERNAME/.npm-global

WORKDIR /tmp
USER $USERNAME

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ENV PATH="/home/$USERNAME/.local/bin:/home/$USERNAME/.npm-global/bin:${PATH}"

SHELL ["/bin/bash", "-c"]

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh
COPY --chmod=755 sandbox-privileged-boot.sh /usr/local/bin/sandbox-privileged-boot.sh

# The agent's single sudo entry: the privileged-boot wrapper, which takes no
# instructions from its caller (it reads its config from PID 1's environment).
# This is what the entrypoint uses to set up the firewall, publish
# /etc/sandbox-info and apply the sudo policy, so it must stay available even
# in strict sandboxes (the default), where /etc/sudoers.d/agent does not exist.
#
# Note there is deliberately no entry for init-firewall.sh itself: authorising
# it directly would need `sudo env VAR=...` to pass the broker/adb host:port
# config through, and authorising `env` is equivalent to full root.
USER root
RUN echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/sandbox-privileged-boot.sh" \
        > /etc/sudoers.d/$USERNAME-boot \
    && chmod 0440 /etc/sudoers.d/$USERNAME-boot
USER $USERNAME

WORKDIR /workspaces

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
