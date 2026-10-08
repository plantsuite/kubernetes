#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }
warning() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-adapter.sh"

MOCK_CERTS=""
MOCK_CERTS_RC=0
MOCK_PRESENT=""

kubectl() {
  if [[ "${1:-}" == "get" && "${2:-}" == "certificate" ]]; then
    printf '%s' "$MOCK_CERTS"
    return "$MOCK_CERTS_RC"
  fi
  if [[ "${1:-}" == "get" && ( "${2:-}" == "clusterissuer" || "${2:-}" == "issuer" ) ]]; then
    local key="$2/${3:-}"
    case " $MOCK_PRESENT " in
      *" $key "*) return 0 ;;
    esac
    return 1
  fi
  return 1
}

MOCK_CERTS=""
real_assert_istio_ingress_certificate_issuers

MOCK_CERTS=$'plantsuite-wildcard|ClusterIssuer|selfsigned\n'
MOCK_PRESENT="clusterissuer/selfsigned"
real_assert_istio_ingress_certificate_issuers

MOCK_CERTS=$'plantsuite-mqtt|Issuer|local-ca\n'
MOCK_PRESENT="issuer/local-ca"
real_assert_istio_ingress_certificate_issuers

MOCK_CERTS=$'plantsuite-wildcard|ClusterIssuer|selfsigned\n'
MOCK_PRESENT=""
if real_assert_istio_ingress_certificate_issuers; then
  error 'expected missing ClusterIssuer to fail closed'
fi
[[ "$REAL_LAST_ERROR" == "Certificate plantsuite-wildcard pede ClusterIssuer/selfsigned; emissor não encontrado" ]]

MOCK_CERTS=$'plantsuite-mqtt|Issuer|local-ca\n'
MOCK_PRESENT=""
if real_assert_istio_ingress_certificate_issuers; then
  error 'expected missing Issuer to fail closed'
fi
[[ "$REAL_LAST_ERROR" == "Certificate plantsuite-mqtt pede Issuer/local-ca; emissor não encontrado" ]]

MOCK_CERTS=$'plantsuite-wildcard||selfsigned\n'
MOCK_PRESENT=""
if real_assert_istio_ingress_certificate_issuers; then
  error 'expected default Issuer miss to fail closed'
fi
[[ "$REAL_LAST_ERROR" == "Certificate plantsuite-wildcard pede Issuer/selfsigned; emissor não encontrado" ]]

MOCK_CERTS=$'plantsuite-wildcard|ClusterIssuer|selfsigned\nplantsuite-mqtt|ClusterIssuer|missing-issuer\n'
MOCK_PRESENT="clusterissuer/selfsigned"
if real_assert_istio_ingress_certificate_issuers; then
  error 'expected second missing issuer to fail closed'
fi
[[ "$REAL_LAST_ERROR" == "Certificate plantsuite-mqtt pede ClusterIssuer/missing-issuer; emissor não encontrado" ]]

MOCK_CERTS_RC=1
MOCK_CERTS=""
if real_assert_istio_ingress_certificate_issuers; then
  error 'expected certificate list failure to fail closed'
fi
[[ "$REAL_LAST_ERROR" == "Não foi possível listar Certificates em istio-ingress" ]]

printf 'certificate issuer check tests passed\n'
