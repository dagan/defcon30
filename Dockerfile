FROM kindest/node:v1.21.12
RUN apt-get update && apt-get install -y \
    open-iscsi \
    && rm -rf /var/lib/apt/lists/*