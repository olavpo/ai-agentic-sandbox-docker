FROM agentic-sandbox:latest

USER root
RUN wget -q https://go.dev/dl/go1.23.4.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz \
    && rm go1.23.4.linux-amd64.tar.gz
USER agent

ENV PATH="/usr/local/go/bin:/home/agent/go/bin:${PATH}"
