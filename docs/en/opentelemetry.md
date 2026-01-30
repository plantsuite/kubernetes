# Observability with OpenTelemetry in PlantSuite

PlantSuite services are compatible with the [OpenTelemetry](https://opentelemetry.io/) standard, allowing standardized collection and export of logs, traces, and metrics. This facilitates integration with modern observability tools and centralized environment monitoring.

This template does not install monitoring tools for the Kubernetes cluster, as needs may vary by environment.

The goal is to show how to integrate PlantSuite with OpenTelemetry-compatible tools; Aspire Dashboard is used as an example only.

## Example: Sending to Aspire Dashboard

Aspire Dashboard can receive logs, traces, and metrics sent via OpenTelemetry, enabling real-time visualization and analysis of PlantSuite services.

### Example configuration (appsettings.json)

Below is an example PlantSuite configuration, sending data to Aspire Dashboard via OpenTelemetry:

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

- The `OtlpEndpoint` field should point to the Aspire Dashboard service (adjust as needed).
- The `Metrics`, `Tracing`, and `Logging` blocks enable sending metrics, traces, and logs, respectively.
- The `SamplerProbability` parameter defines the fraction of traces collected (e.g., 0.01 = 1%).

See the official [OpenTelemetry documentation](https://opentelemetry.io/docs/) and [Aspire Dashboard documentation](https://learn.microsoft.com/aspire/overview/dashboard/) for more details and advanced options.
