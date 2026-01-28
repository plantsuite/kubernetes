# Guia de Uso do Kustomize no PlantSuite

## Estrutura do Projeto

O repositório está organizado para facilitar o uso do [Kustomize](https://kustomize.io/) com diferentes ambientes e customizações:

`k8s/base/`: Contém os manifestos base, com configurações enxutas e orientadas a HA.
`k8s/overlays/`: Sobreposições para diferentes cenários:
  - `minimal/`: Para labs e demos, 1 réplica.
  - `base/`: HA enxuto, próximo de produção.
  - `production/`: Ponto de partida para produção, ajuste conforme necessidade.

Cada overlay pode customizar recursos, réplicas, variáveis de ambiente e outros parâmetros sem alterar os arquivos base.

## Como ajustar valores de resources

Para modificar valores como CPU, memória, réplicas ou outras configurações:

> 💡 **Dica:** Consulte os overlays existentes em `k8s/overlays/minimal/` e `k8s/overlays/production/` para exemplos práticos de como aplicar patches e customizações.

1. **Nunca altere diretamente os arquivos em `base/`**. Crie um overlay em `overlays/` (ou use um existente) para suas modificações.
2. No overlay desejado, adicione ou edite patches (YAML) para sobrescrever apenas os campos necessários. Exemplo baseado no overlay `minimal/istio-ingress`:

```yaml
# k8s/overlays/minimal/istio-ingress/patches/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: gateway
spec:
  minReplicas: 1
  maxReplicas: 1
```

E inclua esse patch no `kustomization.yaml` do overlay:

```yaml
patches:
  - path: patches/hpa.yaml
    target:
      kind: HorizontalPodAutoscaler
      name: gateway
```

### Exemplo de patch JSON6902 (`op: replace`)

Para ajustar, por exemplo, os recursos de um container, utilize um patch do tipo JSON6902 baseado no overlay `production/istio-ingress`:

```yaml
# k8s/overlays/production/istio-ingress/patches/deployment-ops.yaml
- op: replace
  path: /spec/template/spec/containers/0/resources
  value:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

No `kustomization.yaml` do overlay, adicione:

```yaml
patches:
  - target:
      kind: Deployment
      name: gateway
    path: patches/deployment-ops.yaml
```

> 💡 Ajuste o path e value conforme suas necessidades. Para remoções, use `op: remove` com o path específico.


## Quando ajustar recursos

Monitorar o comportamento dos pods e do cluster é essencial para otimizar o desempenho e evitar problemas. Os serviços no PlantSuite estão configurados com `requests = limits` para garantir uma alocação previsível de recursos, evitando sobrecargas que possam causar OOMKill (Out of Memory Kill) em nós inteiros do Kubernetes e melhorando a estabilidade geral.

### Sinais de que recursos precisam ser ajustados

- **Restarts frequentes de pods**: Verifique logs e eventos do Kubernetes para identificar OOMKills ou falhas por falta de CPU/memória.
- **Pods demorando para subir ou ficando não responsivos**: Pode indicar recursos insuficientes, causando lentidão na inicialização ou travamentos.
- **Pods em estado Pending**: Geralmente sinaliza falta de recursos no cluster (CPU, memória ou storage), impedindo o agendamento.

Use ferramentas como `kubectl describe pod` ou ferramentas de monitoramento (ex.: [Lens](https://lenshq.io)) para investigar. Ajuste `requests` e `limits` nos patches conforme observado, sempre testando em ambientes de staging antes de produção.

## Segurança de Senhas e Segredos

Senhas e outros dados sensíveis utilizados nos manifestos ficam armazenados em arquivos `.env.secret` dentro dos diretórios dos componentes.

> ⚠️ **Importante:** Mantenha todos os arquivos `.env.secret` em local seguro e nunca os compartilhe em repositórios públicos ou com pessoas não autorizadas. O vazamento desses dados pode comprometer a segurança do ambiente.

## Referências
- [Documentação oficial do Kustomize](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Kustomize no Kubernetes](https://kubernetes.io/pt-br/docs/tasks/manage-kubernetes-objects/kustomization/)