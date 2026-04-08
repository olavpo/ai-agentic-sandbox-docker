FROM agentic-sandbox:latest

USER root
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && chown -R agent:agent /home/agent/.rustup /home/agent/.cargo
USER agent

ENV PATH="/home/agent/.cargo/bin:${PATH}"
