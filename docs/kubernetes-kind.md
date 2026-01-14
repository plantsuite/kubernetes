# Kubernetes com Kind: Guia de Uso para Testes Locais

## O que é o Kind?

O [Kind (Kubernetes IN Docker)](https://kind.sigs.k8s.io/) é uma ferramenta open source que permite criar clusters Kubernetes localmente usando contêineres Docker ou Podman como nós do cluster. O principal objetivo do Kind é facilitar o desenvolvimento, testes e CI/CD de aplicações e configurações Kubernetes em ambientes controlados e descartáveis, sem a necessidade de infraestrutura em nuvem ou VMs pesadas.

### Vantagens do Kind
- **Rápido e leve**: Clusters são criados em minutos usando contêineres.
- **Ambiente isolado**: Ideal para testes, desenvolvimento e CI/CD.
- **Compatibilidade**: Funciona tanto com Docker quanto com Podman.
- **Fácil de descartar**: Clusters podem ser removidos rapidamente após o uso.

## Requisitos
- [Docker](https://docs.docker.com/get-docker/) **ou** [Podman](https://podman.io/getting-started/installation)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/)

## Criando um cluster de 1 nó (ideal para testes do overlay minimal)

```bash
kind create cluster --name minimal
```

Esse comando cria um cluster com apenas um nó (control-plane), suficiente para testes rápidos e validação do overlay `minimal`. Não é necessário passar um arquivo de configuração, pois este é o comportamento padrão do Kind.

## Criando um cluster com 3 nós (1 control-plane + 2 workers)

Ideal para testar cenários mais próximos de produção, como os overlays `base` e `production`.

```bash
kind create cluster --name multi-node --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
```

## Habilitando Load Balancer com cloud-provider-kind

Por padrão, o Kind não oferece suporte nativo a LoadBalancer Services. Para simular esse recurso em ambientes de desenvolvimento, utilize o [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind):

1. Siga as instruções do repositório oficial: [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind?tab=readme-ov-file#install)
2. Instale o provider no cluster Kind criado.
3. Após a instalação, será possível criar serviços do tipo `LoadBalancer` e obter IPs externos simulados.

---

## Problemas conhecidos

Em caso de problemas com o seu ambiente consulte o guia [Known Issues](https://kind.sigs.k8s.io/docs/user/known-issues/) do Kind.

## Referências
- [Kind - Site Oficial](https://kind.sigs.k8s.io/)
- [Kind - Documentação](https://kind.sigs.k8s.io/docs/)
- [cloud-provider-kind](https://github.com/aojea/cloud-provider-kind)
- [Docker](https://docs.docker.com/get-docker/)
- [Podman](https://podman.io/)
