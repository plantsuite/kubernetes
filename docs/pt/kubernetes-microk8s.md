# Kubernetes com MicroK8s

O [MicroK8s](https://canonical.com/microk8s) é uma distribuição de Kubernetes de fácil operação, com foco em simplicidade e baixo consumo de recursos. Ele é um sistema open source para automatizar a implantação, o escalonamento e o gerenciamento de aplicações conteinerizadas. O MicroK8s oferece as funcionalidades essenciais do Kubernetes em uma instalação compacta, podendo ser utilizado tanto em um único nó quanto em clusters de alta disponibilidade para produção.

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
