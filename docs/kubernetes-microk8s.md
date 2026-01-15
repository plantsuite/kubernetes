# Kubernetes com MicroK8s

Esse guia é baseado nos exemplos do [Getting started](https://canonical.com/microk8s/docs/getting-started) e outros tópicos da documentação oficial do [MicroK8s](https://canonical.com/microk8s/docs).

## Instalar microk8s

O MicroK8s instala uma versão mínima e leve do Kubernetes que você pode executar em praticamente qualquer máquina. Pode ser instalado via snap:

```
sudo snap install microk8s --classic --channel=1.35
```

Para verificar os canais disponíveis, use `snap info microk8s`.
Para mais informações sobre a escolha do `--channel`, consulte https://canonical.com/microk8s/docs/setting-snap-channel.

## Entre no grupo microk8s

O MicroK8s cria um grupo para permitir o uso de comandos que requerem privilégios de administrador. Para adicionar seu usuário atual ao grupo e obter acesso ao diretório de cache `.kube`, execute os três comandos a seguir:

```
sudo usermod -a -G microk8s $USER
mkdir -p ~/.kube
chmod 0700 ~/.kube
```

**Reinicie o computador** para garantir que qualquer nova instância do terminal e do MicroK8s carregue as permissões atualizadas.

## Verifique o estado

O MicroK8s tem um comando embutido para exibir seu estado. Durante a instalação, você pode usar a flag `--wait-ready` para aguardar a inicialização dos serviços do Kubernetes:

```
microk8s status --wait-ready
```

## Instalando add-ons

O MicroK8s usa o mínimo de componentes para manter o Kubernetes leve. No entanto, muitos recursos extras estão disponíveis por meio de “add-ons” — componentes empacotados que fornecem capacidades adicionais ao seu Kubernetes.

Para começar, é recomendado habilitar o gerenciamento de DNS para facilitar a comunicação entre serviços. Para aplicações que precisam de armazenamento, o add-on `hostpath-storage` fornece espaço em um diretório no host. O `helm3` é necessário para o kustomize funcionar com o helm, que é usado pelas ferramentas na pasta **tools** deste repositório. Esses recursos são fáceis de configurar:

```
microk8s enable dns hostpath-storage helm3
```

Para **clusters com mais de um nó**, é recomendado usar o [rook-ceph](https://canonical.com/microk8s/docs/how-to-ceph) para um serviço de armazenamento mais avançado.

### Load Balancer

Se necessário, você pode usar o [MetalLB LoadBalancer](https://canonical.com/microk8s/docs/addon-metallb).

O MetalLB é uma implementação de balanceador de carga de rede que busca “simplesmente funcionar” em clusters bare-metal.

Ao habilitar este add-on, você será solicitado a informar um pool de endereços IP que o MetalLB distribuirá:

```
microk8s enable metallb
```

Alternativamente, você pode fornecer o pool de endereços IP no próprio comando de habilitação:

```
microk8s enable metallb:10.64.140.43-10.64.140.49
```

Vários intervalos separados por vírgula, assim como a notação CIDR (por exemplo `metallb:10.64.140.43-10.64.140.49,10.64.141.53-10.64.141.59,10.12.13.0/24`), são suportados a partir da versão 1.19.

## Usando `kubectl` e `helm`

O MicroK8s traz sua própria versão do `kubectl` para acessar o Kubernetes. Use-a para executar comandos que monitoram e controlam o seu cluster. Por exemplo, para ver seus nós:

```
microk8s kubectl get nodes
```

O MicroK8s usa um comando `kubectl` com nome próprio para evitar conflitos com instalações existentes do `kubectl`. Se você não tem uma instalação separada, é mais simples criar um alias.

No Ubuntu, o MicroK8s é instalado via Snap; a forma mais simples é criar aliases:


```bash
sudo snap alias microk8s.kubectl kubectl
sudo snap alias microk8s.helm3 helm
```

Verifique os aliases e a versão do cliente:

```bash
snap aliases
kubectl version
helm version
```

Agora você pode chamar o `kubectl` diretamente:

```
kubectl get nodes
```

## Extraindo config (opcional)

Para extrair o arquivo de configuração (config) do cluster MicroK8s, digite:

```
microk8s config
```

Ou, se preferir, extraia-o para a pasta `~/.kube`, que é o local padrão e onde muitas ferramentas tentam obter a configuração automaticamente, como por exemplo o [Lens](https://lenshq.io) ou o [FreeLens](https://freelensapp.github.io).

```
microk8s config > ~/.kube/config
```

## Clusters com múltiplos nós

Consulte a documentação oficial em https://canonical.com/microk8s/docs/clustering.