#!/usr/bin/env bash
# Copia o kubeconfig do host para dentro do container e substitui
# localhost/127.0.0.1 por host.docker.internal, para que clusters Kind/minikube
# acessíveis no host também sejam acessíveis dentro do container.
#
# Executado a cada start do container via postStartCommand.

STAGING="/usr/local/share/kube-localhost/config"

if [[ ! -f "$STAGING" ]]; then
    return 0 2>/dev/null || exit 0
fi

mkdir -p "$HOME/.kube"
cp "$STAGING" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
sed -i -e "s/localhost/host.docker.internal/g" \
       -e "s/127\.0\.0\.1/host.docker.internal/g" \
       "$HOME/.kube/config"
