FROM agentic-sandbox:latest

USER root
RUN apt-get update && apt-get install -y \
    openjdk-21-jdk \
    maven \
    gradle \
    && rm -rf /var/lib/apt/lists/*
USER agent

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
