# Resident

**A macOS menu bar gauge for the memory your local models actually live in.**

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)

Part of [Don Works](https://github.com/Don-Works), open source by Revitt. Sister to
[Handler](https://github.com/Don-Works/handler), which watches the resource ceilings that
take the whole machine down. Resident watches the ones that make local inference slow.

```
●  Paging weights — throughput is collapsing
        4 models resident, holding 35.79 GB of 107.52 GB the GPU may use
        Room for 22.12 GB more — free memory, not the GPU ceiling, is the binding limit
        GPU holds 44.92 GB — 9.13 GB beyond the weights, which is KV cache and overhead
        Qwen3.8 27B can decode at most 18 tok/s on this machine's bus
        Qwen3.8 27B is decoding at 15 tok/s — 83% of its bus ceiling; memory bandwidth
          is the limit, and only a smaller quantisation moves it
        ⚠︎ 48.56 GB of swap is in use while models are resident — weight pages are
          going to disk, which costs far more throughput than any quantisation choice
        ⚠︎ Qwen3.8 27B is loaded at 256K context — the KV cache that reserves grows
          with the window, whether or not you use it
```

---

## Contents

- [Why memory percent is the wrong number](#why-memory-percent-is-the-wrong-number)
- [Install](#install)
- [Using it](#using-it)
- [Live throughput](#live-throughput)
- [The decode ceiling](#the-decode-ceiling)
- [Why there is no bandwidth gauge](#why-there-is-no-bandwidth-gauge)
- [What it measures](#what-it-measures)
- [Supported runtimes](#supported-runtimes)
- [Remote boxes](#remote-boxes)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Licence](#licence)

---

## Why memory percent is the wrong number

Activity Monitor will tell you memory is 83% used. That number is true and useless. On a
unified-memory Mac running local models, three things decide whether inference is fast,
and none of them is a percentage of RAM:

- **Whether the weights are resident.** The moment macOS starts paging weight pages to
  disk, decode speed falls by an order of magnitude. Swap is normal on macOS and its
  *level* means nothing — it is never reclaimed eagerly. Swap being actively *written*
  while a model is loaded means the thing you are waiting for is coming off an SSD.
- **How much the GPU is allowed to hold.** Metal publishes a working-set limit that is
  not the same as installed RAM. On a 128 GB machine it is about 107 GB, and one model
  cannot exceed the maximum buffer length either way.
- **Memory bandwidth.** Generating a token means reading every active weight from DRAM
  once. A 27 GB model on a 546 GB/s bus cannot exceed about 18 tokens per second no
  matter what the GPU is doing. If you are near the bus limit, a faster chip does not
  help and a smaller quantisation does.

Resident computes all three and says which one is currently binding.

---

## Install

Needs a Swift toolchain (Xcode or `xcode-select --install`) and
[Task](https://taskfile.dev).

```sh
git clone https://github.com/Don-Works/resident
cd resident
task install       # app into /Applications, `resident` CLI onto PATH
task autostart     # optional: start at login
```

Or build and run without installing:

```sh
task run
```

---

## Using it

The menu bar item shows how much memory the loaded models are holding and whether the
GPU is actually working:

```
▣ 28G  gpu 44%
```

While a model is working it also shows which one, and the decode rate its runtime
reported, in five fixed fields — provider, model, quant, tok/s, gpu:

```
local · Qwen3.8 27B · Q4_K_M · 15 tok/s · gpu 91%
```

The name and rate stay for half a minute after the last prediction finishes, so an
agent issuing a request every few seconds reads as one continuous job rather than a
flicker. A field with no reading is left out. The icon appears only from warn upwards;
with room to spare the bar carries the title alone.

Open the menu for the verdict, the ceilings, and a row per model. Each model row is a
submenu carrying its quantisation, context window, idle timeout, last measured rate,
and a **Release** action that asks the owning runtime to unload it.

The same readings work over SSH:

```sh
resident status              # one-shot report
resident status --detail     # wait for exact per-model activity
resident watch 2             # refresh every 2 seconds
resident models --json       # machine-readable
resident unload --idle       # release everything that is not generating
```

### Releasing idle models

A model sitting idle with a ten-hour TTL is holding memory you cannot use. **Release
… of Idle Models** asks each runtime to unload every model that is not currently
generating. They reload on their next request — the cost is the load time, not the work.

Resident never unloads anything on its own, and never stops a process it does not manage.

---

## Live throughput

The `tok/s` figure next to a model is a measurement from the runtime's own statistics
for a prediction it completed. Resident does not time requests itself.

It is the *generation* rate: tokens produced over the time spent producing them. LM
Studio's headline `tokensPerSecond` divides by the whole request instead, prompt
processing included, and an agent working over an 85K-token conversation spends half a
minute on the prompt before the first token — which turns a 19 tok/s decode into a
reported 11. Resident uses the generation time, and shows the prompt size and
time-to-first-token in the model's submenu so the two costs stay separate.

A rate is per request, not per model. Two requests decoding at once share the GPU and
each reports roughly half; a single request gets the whole bus.

| Runtime | Source | What it means |
|---|---|---|
| LM Studio | `lms log stream --source model --stats` | generation rate of the last completed prediction on that model, prompt processing excluded |
| llama.cpp | `/metrics` → `llamacpp:tokens_predicted_total`, as a rate | average over the last sample interval |
| Ollama | — | not reported by Ollama's API |
| process scan | — | no API to ask |

Two things are worth knowing about the LM Studio path:

- **It is a child process.** `lms log stream` is the only channel LM Studio offers for
  prediction statistics, and the CLI takes seconds to connect, so Resident keeps one
  open rather than spawning it per sample. It is Node and holds around 60 MB. Only the
  menu bar app and `resident watch` run it; `resident status` and `resident models`
  read the cache it leaves behind. It is stopped when Resident quits, and a copy left
  behind by a crash is found by its pid file and stopped on the next launch.
- **It sees prompts.** The stream carries every prompt and completion in full. Resident
  keeps the model identifier and the statistics and discards the text; nothing is
  written to disk beyond a rate and a timestamp.

The stream reports at the *end* of each prediction, so the rate shown lags the
generation it describes by one request. During a long generation the row keeps its `▶`
and the previous rate; the new one lands when it finishes.

llama-server exposes its counters only when started with `--metrics`, and slot state
only with `--slots`. Without them Resident shows the model, and nothing it cannot
source.

---

## The decode ceiling

`resident status` prints a `CEILING` column beside each local model's rate. That is:

```
ceiling = memory bandwidth ÷ weight bytes
```

Autoregressive decoding reads the whole active weight set once per token, so this is a
hard upper bound on tokens per second, set by the memory bus alone. It is arithmetic,
not a measurement — real throughput lands below it.

Two honest caveats, both stated in the report:

- **Mixture-of-experts models beat it.** They read only their active experts per token,
  so a sparse 27B behaves like a much smaller dense model. The ceiling assumes dense
  weights and is pessimistic for MoE — which is why the menu does not show it: a sparse
  model beats it, and a bound the screen contradicts is worse than none.
- **Prompt processing is not decoding.** Prefill is compute-bound and runs far faster;
  this bound applies to generation.

It is the number that explains why the 8-bit copy of a model feels slow and the 4-bit
copy does not, before you spend an evening finding out.

---

## Why there is no bandwidth gauge

The counters exist and would be perfect. IOReport publishes a group called
`AMC Stats / Perf Counters` from the memory cache controller, carrying `DCS RD` and
`DCS WR` totals plus per-agent attribution — `GFX` for the GPU, `PCPU`/`ECPU` for the
cores, `ANE` for the neural engine. Exactly what a local-AI monitor wants.

They are not readable by anything you can write. Verified on macOS 26 / M4 Max:

- `IOReportCreateSubscription` on that group returns NULL as a normal user, **and as
  root** — `uid=0 euid=0` makes no difference.
- Subscribing to every channel instead does succeed, but the samples come back with all
  189 AMC channels silently removed (11,202 returned of 11,399). Again including as root.
- `powermetrics` is no help: its samplers are `cpu_power`, `gpu_power` and `ane_power`.
  There is no DRAM traffic sampler to shell out to and parse.

The gate is an entitlement, not a privilege, and Apple does not grant it. So Resident
shows the one bandwidth number that is exactly true — the decode ceiling above, which is
published peak bandwidth divided by weight bytes — and no gauge pretending to measure
traffic. `Sources/Resident/Bandwidth.swift` records the finding so the next person does
not spend an afternoon rediscovering it.

## What it measures

| Gauge | Source | Privileges |
|---|---|---|
| Model weights resident | runtime APIs, against `MTLDevice.recommendedMaxWorkingSetSize` | none |
| GPU memory allocated | `AGXAccelerator` → `Alloc system memory` | none |
| Memory in use | `host_statistics64` | none |
| GPU utilisation | `AGXAccelerator` → `Device Utilization %` | none |
| Swap being written | `vm_statistics64.swapouts`, as a rate | none |
| Swap allocated | `vm.swapusage` | none |
| Memory pressure | `kern.memorystatus_vm_pressure_level` | none |

Swap is reported as a **rate, not a level**. macOS never shrinks swap eagerly, so it sits
high for hours after the pressure that caused it has gone — a gauge that warns on the
level cries wolf every time. What matters is the cumulative `swapouts` counter climbing:
that means weight pages are going to disk *now*. Resident takes two readings to derive it,
and says "this is residue" when swap is allocated but flat.

Two fields on the accelerator look interchangeable and are not. `Alloc system memory` is
what the GPU driver currently holds — weights plus KV cache — and is the residency
figure. `In use system memory` collapses to a gigabyte or two between requests and climbs
during generation, so it measures activity, not residency. Resident uses the first.

Resident needs no privileges at all. There is no helper, no daemon, and nothing to
install with `sudo`.

Nothing here shells out to `lsof`, `powermetrics` or `ioreg` on the sampling path, and
nothing can block on a stalled network mount. A full sample costs about 0.3 seconds,
almost all of it waiting on model-runtime HTTP.

---

## Supported runtimes

| Runtime | Detection | Size | Activity | Throughput | Unload |
|---|---|---|---|---|---|
| LM Studio | `/api/v0/models` | on-disk model index | `lms log stream`, else `lms ps` cached | `lms log stream` | `lms unload` |
| Ollama | `/api/ps` | `size_vram` | — | — | `keep_alive: 0` |
| llama.cpp | `/props` on 8080/8000/8081 | GGUF file size | `/slots` | `/metrics` | no — stop the server |
| vLLM on a remote box | `remotes.json` → `/metrics` | not this machine's memory | `num_requests_running` | token counters, as a rate | no — stop the box |
| MLX, vLLM (local), others | process scan | resident process memory | — | — | no |

Anything found by process scan is marked with `~`, because resident process memory
includes the KV cache, the framework and the interpreter — not just weights.

LM Studio deserves a note: `lms ps --json` reports everything but takes three to eight
seconds, because it spawns Node to open a websocket. That cannot sit in a five-second
loop. So the loop uses the REST endpoint (about 8 ms) plus LM Studio's own on-disk model
index for exact sizes, and the slow call runs in the background into a cache that every
Resident process shares. Activity and throughput come from the log stream described
under [Live throughput](#live-throughput) when it is open, and from that cache otherwise.

---

## Remote boxes

The same menu can carry a model that is not on this machine at all — a GPU rented by
the hour, a box in the cupboard — as long as it is served by **vLLM**. Local and remote
sit in the same menu, marked apart: a remote row starts with `☁`, and the menu bar
title reads `vast.ai · qwen3.8-27b · fp8 · 71 tok/s · gpu 100%` while a remote is the
model doing the work.

```
Remote boxes
▶  ☁ vast.ai · H100 SXM    qwen3.8-27b   fp8    71 tok/s    2 req  kv 66%  gpu 100%
```

Nothing about a remote touches the memory arithmetic. Its weights are in someone else's
VRAM, so it is excluded from the weights gauge, the headroom and the paging verdict. It
gets its own line in the verdict instead.

### The connector

Resident reads `~/.config/resident/remotes.json`, a list of boxes. The smallest entry
is a name and the OpenAI-compatible base URL:

```json
[
  { "name": "lab", "base_url": "http://10.0.0.5:8000/v1", "provider": "homelab" }
]
```

The full shape, which is what a provisioner writes:

```json
[
  {
    "name": "vast-box",
    "base_url": "http://203.0.113.10:20066/v1",
    "ctl_url": "http://203.0.113.10:19983",
    "token": "…",
    "gpu": "H100 SXM",
    "quant": "fp8",
    "context": 262144,
    "ssh": "ssh2.vast.ai:11354"
  }
]
```

| Key | Used for |
|---|---|
| `base_url` | Where vLLM answers. `/metrics` is derived from it (`/v1` → `/metrics`) unless `metrics_url` says otherwise. |
| `ctl_url` + `token` | Optional sidecar that answers `GET /gpu` — see below. Without it there is no GPU utilisation, because vLLM does not export one. |
| `provider` | Who owns the metal. When absent it is **inferred**: the registrable domain of the first real hostname in the entry (`ssh2.vast.ai` → `vast.ai`). An IP address says nothing, and there is no vendor list in the code. |
| `gpu`, `quant`, `context` | Labels for the row. The sidecar's card name fills in `gpu` when the entry has none; vLLM does not report weight precision, so `quant` is the entry's to say. |

The file is read on every sample, so a provisioner can add a box when it comes up and
remove it when the box is destroyed. Everything shown for a remote is one of the box's
own readings:

| Figure | Source |
|---|---|
| tok/s | `vllm:generation_tokens_total`, as a rate between two samples |
| prefill | `vllm:prompt_tokens_total`, the same way |
| req | `vllm:num_requests_running` (+ `num_requests_waiting` when there is a queue) |
| kv | `vllm:kv_cache_usage_perc` |
| gpu | the sidecar's `utilization`, and VRAM used / total in the row's submenu |

vLLM serves `/metrics` without authentication even when the API needs a key, so the
token is only ever sent to the sidecar.

### The sidecar

Any HTTP endpoint that answers `GET <ctl_url>/gpu` with a bearer token and this JSON
turns on the GPU column:

```json
{ "name": "NVIDIA H100 80GB HBM3", "utilization": 100.0,
  "memory_used_mib": 74809, "memory_total_mib": 81559 }
```

That is one `nvidia-smi --query-gpu` call behind a 20-line HTTP server. The
[vast-box](https://github.com/Don-Works/mcplexer) lane controller does exactly this and
registers the box in `remotes.json` on `up` and removes it on `down`; any other
provisioner can do the same with a JSON write.

### The status item names its source

Whichever model is producing the most tokens takes the menu bar title, in five fixed
fields — provider, model, quant, tok/s, gpu: `local · Qwen3.8 27B · Q4_K_M · 14 tok/s ·
gpu 54%` for a local model, `vast.ai · qwen3.8-27b · fp8 · 39 tok/s ×2 · gpu 100%` for a
box, where the rate is each request's share of the box's total, `×2` is how many share
it, and `gpu` is the box's card, never this Mac's. A field with no reading is left out,
nothing is a glyph, and a thrashing box says so in a word. Idle, each machine is listed
with its own gpu figure. The tooltip spells out what every figure is and where it was
read.

### The thrash alert

A box whose in-flight contexts exceed its KV cache evicts a running request to serve
another and recomputes it later, and every turn then waits on a 100K-token prefill. vLLM
shows this as its preemption counter climbing while requests wait for capacity (or the
cache sits above 85 percent). Resident calls that thrashing: the verdict goes critical,
the status icon becomes a dark red filled triangle with "thrashing" in words beside it,
and one macOS notification fires per episode per box. The fix is in the warning line:
compact or close sessions, or switch to a lane with a bigger cache.

### Two things to know

- Sampling a remote costs one `/metrics` fetch (about 50 KB) and one `/gpu` fetch every
  five seconds, with a 2.5-second timeout so a box that has gone away costs no more.
- The app bundle carries an App Transport Security exception for cleartext HTTP, because
  rented boxes answer over plain `http://` on a public address. The CLI never needed it.

---

## Troubleshooting

**The menu bar item is not there.** macOS hides menu bar extras when the bar is full;
look behind the `‹` chevron. The item exists either way — check with:

```sh
osascript -e 'tell application "System Events" to tell process "Resident" \
  to get description of every menu bar item of menu bar 1'
```

**The rate looks low.** Check the submenu: a long prompt makes a request slow without
the decode being slow, and a second request in flight halves what each one gets. For a
dense model, `resident status` prints the bus ceiling beside the rate — at 80-100% of it
the model is running as fast as the memory bus allows, and only a smaller quantisation
changes that.

**A model shows no `tok/s`.** Nothing has completed a prediction on it since Resident
started, or the runtime does not report one — see [Live throughput](#live-throughput).
For LM Studio the `lms` CLI must be installed (LM Studio → Developer → Install CLI);
check with `pgrep -fl "lms log stream"` while the menu bar app is running.

**Sizes look wrong for a runtime found by process scan.** They are approximate by
construction — see the table above.

---

## Development

```sh
task build       # release binary
task status      # one-shot report
task run         # menu bar app, replacing any running copy
task clean
```

No package dependencies, by design. Contributions welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules that keep it trustworthy.

The menu can be read without clicking it, which is how it is tested:

```sh
osascript -e 'tell application "System Events" to tell process "Resident" \
  to get title of every menu item of menu 1 of menu bar item 1 of menu bar 1'
```

---

## Licence

[AGPL-3.0-or-later](LICENSE). Copyright © 2026 Don Works. See [NOTICE](NOTICE).
