# Filename: Dockerfile
FROM google/cloud-sdk:slim

# Install kubectl, helm, and argo cli
RUN apt-get update && apt-get install -y jq gettext-base bash && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && \
    curl -sLO https://github.com/argoproj/argo-workflows/releases/latest/download/argo-linux-amd64.gz && \
    gunzip argo-linux-amd64.gz && chmod +x argo-linux-amd64 && mv argo-linux-amd64 /usr/local/bin/argo

COPY setup.sh /setup.sh
RUN chmod +x /setup.sh
ENTRYPOINT ["/setup.sh"]