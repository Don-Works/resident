# Contributing to Resident

Thanks for looking. Resident is small on purpose — it reads a handful of kernel and
runtime counters and says what they mean. Contributions that keep it that way are very
welcome.

## Building

```sh
git clone https://github.com/Don-Works/resident && cd resident
task build          # or: swift build -c release
task status         # one-shot report against whatever is loaded
task run            # menu bar app, replacing any running copy
```

Requires macOS 13+ and a Swift toolchain (Xcode, or `xcode-select --install`).
There are no package dependencies and there never should be without a good reason.

`task --list-all` shows everything.

## Shape

- `Sources/Resident/` — one concern per file, under 300 lines each.
- Reading layer: `Sysctl`, `Hardware`, `GPU` — kernel and IO registry only. `Bandwidth`
  is documentation, not code: it records why DRAM counters are unreadable.
- Runtime layer: `LMStudio` (+ `LMStudioStream`), `Ollama`, `LlamaServer`, `RemoteVLLM` (+ `Remotes`),
  `UnmanagedRuntime`, all `ModelRuntime`.
- Judgement layer: `Sampler` builds a `Sample`, `Verdict` decides what it means.
- Presentation: `MenuBar` + `MenuBuilder` for the GUI, `CLI` + `CLIActions` for the terminal.

## Ground rules

These are the constraints that make the tool trustworthy. Please don't relax them casually.

**Never show a number you cannot source.** Every gauge is a real reading or is marked
`informational` with a note. When memory bandwidth turned out to be unreadable even as
root, the gauge was deleted rather than estimated — see `Bandwidth.swift`. The decode
ceiling is arithmetic (bus ÷ weight bytes), not a measurement; it appears only in the
`resident status` table, labelled as such, and not in the menu, because a
mixture-of-experts model beats it and a bound the screen contradicts is worse than
none. Throughput is the runtime's own figure for a prediction it completed, and is
labelled as that.

**No privileges, ever.** There is no helper and no daemon. If a feature needs root, it
does not ship.

**Nothing slow on the sampling path.** `lms ps --json` takes 3-8 seconds; it runs in the
background and writes a shared cache. The LM Studio log stream is one long-lived child
process, not a spawn per sample. The sample loop must stay in milliseconds.

**Nothing at all on the main thread.** Sampling talks HTTP to model runtimes.

**Warn on rates, not levels, wherever the level is not reclaimed.** Swap sits high for
hours after the pressure that caused it, so `swapUsed` warns on nothing; the climbing
`vm_statistics64.swapouts` counter is the signal. The same trap exists for the vnode
cache and the compressor. Ask whether the number goes down on its own before gauging it.

**Severity is never carried by colour alone, and never by orange.** The menu bar draws
over the user's wallpaper and flips its own text between black and white to stay
legible; a status item that paints a fixed colour opts out of that and becomes
unreadable. So the status item is `.labelColor` text — provider · model · quant · tok/s
· gpu, no glyphs — with a template image only from warn upwards (the one exception is
the dark red thrash triangle, which carries the word "thrashing" beside it so colour is
never the only signal), and level is otherwise carried by font weight. In the dropdown, warn is bold
label text and only critical takes a colour. `tertiaryLabelColor` is banned outright —
at 10-11pt it is barely legible.

**Resident never unloads anything on its own** and never stops a process it does not
manage. Every release goes through a confirmation.

## Style

- Swift API Design Guidelines; match the surrounding code.
- Comments explain *why*, not *what*. Most of the existing ones justify a non-obvious
  constraint — that is the bar.
- Keep files under ~300 lines and functions under ~50. Split rather than sprawl.

## Pull requests

1. Open an issue first for anything beyond a bug fix, so we can agree the shape.
2. One logical change per PR.
3. Run `task status` and `task run` before pushing, with a model loaded.
4. Say what you tested and on which runtime. Much of this is runtime and kernel
   behaviour that only shows up under real load.

If you are reporting a bad reading, `resident status --detail`, `resident models --json`
and your macOS version and chip are the useful attachments.

## Licence

Resident is AGPL-3.0-or-later. By contributing you agree your work ships under that licence.
