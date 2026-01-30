# Observabilidade com OpenTelemetry no PlantSuite

Os serviços do PlantSuite são compatíveis com o padrão [OpenTelemetry](https://opentelemetry.io/), permitindo a coleta e exportação de logs, traces e métricas de forma padronizada. Isso facilita a integração com ferramentas de observabilidade modernas e o monitoramento centralizado do ambiente.

Este template não instala ferramentas de monitoramento do cluster Kubernetes, pois as necessidades podem variar de acordo com o ambiente. 

O objetivo é mostrar como integrar o PlantSuite com ferramentas compatíveis com OpenTeletry, o Aspire Dashboard é usado apenas como exemplo.

## Exemplo de envio para o Aspire Dashboard

O Aspire Dashboard pode receber logs, traces e métricas enviados via OpenTelemetry, permitindo visualização e análise em tempo real dos serviços do PlantSuite.

### Exemplo de configuração (appsettings.json)

Abaixo um exemplo de configuração do PlantSuite, enviando dados para o Aspire Dashboard via OpenTelemetry:

```json
{
  "Observability": {
    "OtlpEndpoint": "http://dashboard.aspire.svc.cluster.local:4317",
    "Metrics": {
      "Enabled": true
    },
    "Tracing": {
      "Enabled": true,
      "SamplerProbability": 0.01
    },
    "Logging": {
      "Enabled": true
    }
  }
}
```

- O campo `OtlpEndpoint` deve apontar para o serviço Aspire Dashboard (ajuste conforme o ambiente).
- Os blocos `Metrics`, `Tracing` e `Logging` ativam o envio de métricas, traces e logs, respectivamente.
- O parâmetro `SamplerProbability` define a fração de traces coletados (exemplo: 0.01 = 1%).

Consulte a documentação oficial do [OpenTelemetry](https://opentelemetry.io/docs/) e do [Aspire Dashboard](https://learn.microsoft.com/aspire/overview/dashboard/) para mais detalhes e opções avançadas.
