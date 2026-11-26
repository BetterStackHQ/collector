# [Better Stack](https://betterstack.com/logs) Collector

[![Better Stack dashboard](https://github.com/user-attachments/assets/e84ed542-a9b9-4a7b-9442-3c145593406a)](https://betterstack.com/tracing)

[![Apache 2.0 License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

Better Stack collector is the easiest and recommended way of integrating Better Stack into your environment. 

**Leverage eBPF to instrument your Kubernetes or Docker clusters** to gather logs, metrics, and OpenTelemetry traces **without code changes**. Ingest everything at a fraction of the cost. [Learn more ⇗](https://betterstack.com/tracing)

## Documentation

[Getting started ⇗](https://betterstack.com/docs/logs/collector/)

## Resource requirements

| Deployment | Soft memory reservation | Hard caps | Host/node guideline |
| --- | --- | --- | --- |
| Collector only | 512 MiB | 1.2 vCPU, 1 GiB memory | 2 vCPU, 2 GiB memory |
| Full tracing (collector + eBPF) | 2 GiB | 2.2 vCPU, 3 GiB memory | 4 vCPU, 4 GiB memory |

The collector-only guideline was validated with eBPF stopped. `mem_reservation` is a soft memory target; `mem_limit` and `cpus` are hard caps, and Docker does not reserve CPU. Host/node guidelines are planning targets: the reservation and enough headroom up to the caps must remain available after the OS and other applications consume their share.

### Changing the container sizes

The hard caps above are defaults. To change them on a host, put the sizes you want in `/var/lib/better-stack/sizing.env` and run the install script again:

```
EBPF_CPUS=2
EBPF_MEM_LIMIT=4096m
```

| Key | Default | Applies to |
| --- | --- | --- |
| `COLLECTOR_CPUS` | `1.2` | CPU limit of `better-stack-collector` |
| `COLLECTOR_MEM_LIMIT` | `1024m` | Memory limit of `better-stack-collector` |
| `COLLECTOR_MEM_RESERVATION` | half of the limit | Soft memory target of `better-stack-collector` |
| `EBPF_CPUS` | `1.0` | CPU limit of `better-stack-collector-host` |
| `EBPF_MEM_LIMIT` | `2048m` | Memory limit of `better-stack-collector-host` |
| `EBPF_MEM_RESERVATION` | 75% of the limit | Soft memory target of `better-stack-collector-host` |
| `EBPF_GOMEMLIMIT` | 68% of the limit | Size at which the Go programs in `better-stack-collector-host` collect garbage harder |
| `EBPF_OBI_RESTART_MIB` | 71% of the limit | Memory of the tracing process, in MiB, above which the health check fails |

- A key you leave out keeps its default. The three values that follow a memory limit move with it, so `EBPF_MEM_LIMIT=4096m` alone is enough.
- Memory limits take `m` or `g`, `EBPF_GOMEMLIMIT` takes `MiB` or `GiB`.
- You can also pass a key as an environment variable to `install.sh`. The script saves it to the file, so later runs keep it.
- The file stays in place across upgrades and uninstalls.
- On a host with less memory than a default limit, `install.sh` lowers that limit to the host's memory. A CPU limit above the host's CPU count is lowered to that count. A memory limit you set yourself is used as written.
- On Docker Swarm, each node reads its own file for `better-stack-collector-host`. Apply a change with `ACTION=ebpf_only`, which needs no `COLLECTOR_SECRET`. The collector is one Swarm service, so the `COLLECTOR_*` keys do nothing there.
- If you run `docker compose` on the compose files yourself, the same keys work as environment variables, but nothing follows the memory limit: set all the memory values of a container together.

## Need help?
Please let us know at [hello@betterstack.com](mailto:hello@betterstack.com). We're happy to help!

## Thank you, open source contributors!
Better Stack collector wouldn't be possible without the open source community. We are grateful to all the contributors of OpenTelemetry, Cilium, Vector, OBI, Coroot among others who enabled us to build upon their work. Thank you!

[Apache 2.0 License](LICENSE.md)
