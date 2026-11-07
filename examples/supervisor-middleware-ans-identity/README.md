<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Supervisor Middleware ANS Identity

> [!WARNING]
> Supervisor middleware is a research preview. Its policy and service contracts may change without compatibility guarantees. Use it only to prototype and evaluate middleware integrations.

This example attaches a verifiable agent identity to the HTTP requests a sandbox sends, without giving the sandbox the signing key. An external middleware service, the [ANS identity extension](https://github.com/agentnameservice/ans-openshell), signs each allowed request as a registered [Agent Name Service](https://github.com/agentnameservice/ans) (ANS) agent from the `PRE_CREDENTIALS` request hook. A reference receiving service verifies the signature and reports which agent called. The example runs against a real gateway, sandbox supervisor and sandbox on the Docker driver, and it changes no OpenShell runtime code.

The extension, its fixtures and its smoke test are maintained in the extension repository. This directory holds a launcher that runs them at a pinned release, the configuration fragments the example uses, and this walkthrough. Report problems with the example in that repository.

## Trust boundary

The sandboxed workload holds no signing key and no credential. The sandbox supervisor, which runs outside the sandbox, checks network policy and then calls the middleware with the allowed request. The middleware confirms that the operator approved this sandbox for the requested identity, signs the request with the agent's key, and attaches the agent's transparency-log receipt and status token. OpenShell applies those header mutations before the request leaves. The receiving service verifies the proof, the receipt and the status token with the published ANS root keys, so it learns which agent called without a shared secret and without calling the middleware.

Identity headers set by the workload are overwritten. A sandbox the operator has not approved is denied before the request leaves. If the middleware is unavailable, the policy's `on_error: fail_closed` blocks the request instead of sending it unsigned.

## Prerequisites

- Linux (x86_64 or arm64) or macOS on Apple silicon.
- Docker, reachable over the Unix socket of the current `docker context`, with access to `ghcr.io` and `nvcr.io` for the pinned OpenShell runtime images and the workload base image.
- `git`, `make`, Go, `curl`, `jq`, `tar`, and `sha256sum` or `shasum` on the host.
- A non-loopback IPv4 address of this machine that containers can reach. The smoke test detects one; set `ANS_SMOKE_HOST` to override it.

The example does not use an installed OpenShell. It downloads the pinned OpenShell CLI and gateway release assets, verifies their SHA-256 checksums, and keeps the gateway's database, TLS bundle and CLI registration in a temporary directory. On the Docker daemon its gateway runs under a `sandbox_label` of its own, so an existing OpenShell installation sharing the daemon is not touched.

## Run the smoke example

Run the launcher from the repository root:

```shell
./examples/supervisor-middleware-ans-identity/smoke.sh
```

The launcher clones the extension at the pinned release into a temporary directory and runs its smoke test. The test builds the middleware, the reference receiving service and a fixture generator from that checkout; mints a disposable transparency-log root key, one registered identity, the gateway's JWT signing key and a private CA for the middleware's gRPC listener; starts the receiving service, the middleware and an authenticated gateway with the middleware registered; creates a sandbox with the policy below; approves exactly that sandbox's gateway-issued ID for the identity; and runs the checks.

| Check | Expected observation |
| --- | --- |
| Authorized sandbox | A plain `POST /v1/tasks` from the workload reaches the receiving service signed. The service returns the operator-assigned ANS name and agent ID. |
| Forged identity headers | `DPoP`, `X-SCITT-Receipt` and `X-ANS-Status-Token` headers set by the workload are overwritten. The service still verifies the assigned identity. |
| Unsigned direct request | A request to the receiving service that bypasses OpenShell is rejected with `401`, and the service logs the rejection. This arms the sentinel the next two checks use. |
| Unapproved sandbox | A second sandbox whose ID is not approved gets `403 middleware_denied` with reason `ans_identity_unauthorized`. The receiving service's log does not grow, so it never saw the request. |
| Middleware unavailable | With the middleware stopped, the request gets `403 middleware_failed` under `on_error: fail_closed`. The receiving service's log does not grow. |

The test prints `ALL PASS 5 checks against OpenShell v0.1.7 (5d25211)` and removes its sandboxes, processes, containers, volumes and temporary material, including the minted keys. On failure it exits non-zero and keeps the logs, including each sandbox's supervisor container log. Replay and body tampering are covered by the verifier's own tests in the extension repository and are reported there, not here.

Leave the stack running after the checks pass to send requests yourself:

```shell
./examples/supervisor-middleware-ans-identity/smoke.sh --keep-running
```

The test prints the gateway endpoint, the sandbox name and a signed request command. Press Ctrl-C to clean up.

Print the complete gateway and middleware configuration the test renders, without starting anything:

```shell
./examples/supervisor-middleware-ans-identity/smoke.sh --print-config
```

## Configuration

[`gateway.toml`](gateway.toml) shows the middleware registration. The gateway authenticates the service by the CA that issued its serving certificate and calls it with gateway-issued JWTs, which the service verifies against the gateway's JWKS. `binding_policy = "allowlist"` with `bindings = ["http_request_pre_credentials"]` requires the request hook, so a service that stops advertising it is refused at startup instead of silently skipped.

[`policy.yaml`](policy.yaml) attaches the middleware to the receiving service's host and allows `curl` to `POST /v1/tasks` there. The middleware runs with `order: 100`, last in the request chain, so no later middleware can rewrite a signed request, and `on_error: fail_closed` blocks the request when the middleware cannot sign. The `config.identity` field names an identity from the middleware's configuration; the operator must also approve the sandbox's gateway-issued ID for that identity in the middleware's `sandbox_identities` map before any request is signed. Sandbox names and labels cannot grant identity access.

## Fixture trust and production trust

The test mints one transparency-log root key per run. It hands that key to the middleware and the receiving service and pins the identity's receipt and status token to files, so the middleware verifies them at startup and contacts no registry. In production the middleware is given the real transparency log's base URL and published root keys, fetches and refreshes the receipt and status token itself, and the receiving service pins the same published keys. Nothing else differs. The proof, the headers, the verifier and the sandbox authorization path are the extension's production code.

The gateway's TLS bundle and the CLI's client certificate come from `openshell-gateway generate-certs`. Only the gateway's JWT signing key is replaced, with the one the fixtures minted, so the middleware's JWKS matches.

## Validated versions

The launcher pins the extension at [v0.1.1](https://github.com/agentnameservice/ans-openshell/releases/tag/v0.1.1), which pins OpenShell v0.1.7: the CLI and gateway release assets by SHA-256, and the supervisor and sandbox runtime images by manifest digest. The extension's CI runs the test against that release on every push to its main branch on `ubuntu-latest`, and the test also passes on macOS (Apple silicon) with Rancher Desktop and with Docker Desktop. Set `ANS_OPENSHELL_REF` to run another tag or branch of the extension.

## Limitations

- The middleware reads its sandbox approvals at startup. Approving a sandbox means editing the map and restarting the service, and until the supervisor's channel to it reconnects, a few seconds, matching requests fail closed with `middleware_failed`. The test retries its first request through that window. A production operator sees the same window on every approval.
- The fixture status token lives one hour. A `--keep-running` stack stops signing when it lapses.
- The pinned OpenShell release has no Intel macOS gateway build, so the example runs on Linux and Apple silicon only.
- The middleware does not bind the proof to the destination's TLS certificate, because the request hook does not expose the peer certificate. Normal TLS verification still applies.

## Ownership

The launcher in this directory runs the extension's smoke test unchanged. The extension, the test, its OpenShell pin and its fixtures are maintained in the [extension repository](https://github.com/agentnameservice/ans-openshell) under its contribution process; file problems with them there. The proposal for this example is [NVIDIA/OpenShell#5011](https://github.com/NVIDIA/OpenShell/issues/5011).
