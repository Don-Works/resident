# Resident

macOS menu bar app for local AI workloads. Swift package, no dependencies.

The shape of the code and the rules that keep it trustworthy are in
[CONTRIBUTING.md](CONTRIBUTING.md). Read that first; it is short.

## Verifying

    task status              # one-shot report against whatever is loaded
    task run                 # menu bar app, replacing any running copy

The menu bar title and the menu can be read without clicking:

    osascript -e 'tell application "System Events" to tell process "Resident" \
      to get title of menu bar item 1 of menu bar 1'
    osascript -e 'tell application "System Events" to tell process "Resident" \
      to get title of every menu item of menu 1 of menu bar item 1 of menu bar 1'

Throughput needs a prediction to have completed since the app started, so drive one
through the runtime's API and read the title again.
