FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=Etc/UTC

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

# Allow passwordless sudo
RUN echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Base system tools (includes iptables/ipset/aggregate for the egress firewall;
# adb is the client for driving an Android emulator on the host — see
# android-testing.md)
RUN apt-get install -y --no-install-recommends \
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

# Create workspace and config directories
RUN mkdir -p /workspaces /home/$USERNAME/.claude/skills /home/$USERNAME/.config/gh /home/$USERNAME/.copilot /home/$USERNAME/.vibe
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' | tee -a /home/$USERNAME/.bashrc /home/$USERNAME/.profile \
    && echo 'alias claude="claude --dangerously-skip-permissions"' | tee -a /home/$USERNAME/.bashrc /home/$USERNAME/.profile
RUN chown -R $USERNAME:$USERNAME /workspaces /home/$USERNAME/.claude /home/$USERNAME/.config /home/$USERNAME/.copilot /home/$USERNAME/.vibe

WORKDIR /tmp
USER $USERNAME

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ENV PATH="/home/$USERNAME/.local/bin:${PATH}"

SHELL ["/bin/bash", "-c"]

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh

# Allow agent to run only the firewall script via sudo without a password.
# (General passwordless sudo is granted earlier; this targeted entry keeps the
# explicit intent clear and provides a deny-other-root path if the broader
# rule is later tightened.)
USER root
RUN echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
        > /etc/sudoers.d/$USERNAME-firewall \
    && chmod 0440 /etc/sudoers.d/$USERNAME-firewall
USER $USERNAME

WORKDIR /workspaces

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
