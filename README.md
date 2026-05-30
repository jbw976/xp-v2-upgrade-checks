# Crossplane v2 Upgrade Check Test Fixtures

Test fixtures that intentionally exercise Crossplane v1 features, APIs, and
patterns that are removed or changed in Crossplane v2. Apply them to a v1
cluster, then run `crossplane beta upgrade check` to verify the pre-flight
checker catches each one.

This is a **test repo only** — it is not an example of production usage and
does not demonstrate any best practices.

## What's exercised

Each fixture targets one of the v2 upgrade checks:

| File                                      | Check                          |
| ----------------------------------------- | ------------------------------ |
| `01-native-patch-and-transform.yaml`      | native-patch-and-transform     |
| `02-controller-config.yaml`               | controller-config              |
| `03-external-secret-stores.yaml`          | external-secret-stores         |
| `04-composite-connection-details.yaml`    | composite-connection-details   |
| `05-unqualified-package-sources.yaml`     | unqualified-package-source     |
| `06-patch-feature-flags.sh`               | external-secret-stores (Deployment flag) |

## Pre-reqs

- `kind`
- `kubectl`
- `helm`
- `crossplane` CLI (for the upgrade-check command)

## Setup

Spin up a kind cluster, install Crossplane v1.20.7, apply all fixtures, and
enable the removed alpha feature flag:

```shell
./setup.sh
```

The script is idempotent — safe to rerun. Override defaults via env vars:

```shell
CLUSTER_NAME=my-cluster CROSSPLANE_VERSION=1.20.7 ./setup.sh
```

## Run the upgrade check

```shell
crossplane beta upgrade check
```

You should see findings for all five checks listed above. The external-secret-stores
check produces findings from two fixtures: `03` (StoreConfig, Composition, and MR
usage) and `06` (the `--enable-external-secret-stores` Deployment flag).

## Teardown

```shell
kind delete cluster --name crossplane-upgrade-check
```
