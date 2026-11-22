# OX Link

LUNA only lets add-ons connect to your own computer, not to devices on your network, so the
[OX Tone Recall](https://github.com/shawnist/ox-tone-recall) panel can't reach an OX Amp Top Box
by itself. OX Link runs on your Mac, finds your OX on the network by its name (for example
`OX001234`), and passes the panel's messages to it. It sits in the menu bar and starts at login,
so you don't need to think about it.

## Install

OX Link comes with the [OX Tone Recall](https://github.com/shawnist/ox-tone-recall) add-on: install
the add-on in LUNA and you have it.
When the panel says OX Link isn't running, press **Start OX Link**, and LUNA opens it from the
add-on's folder. When macOS asks whether OX Link may find devices on your local network, click
**Allow**.

OX Link appears in the menu bar. Its menu shows the OX it found, and lets you turn **Start at
Login** on or off or quit. The OX Tone Recall panel in LUNA connects by itself once OX Link is
running. Removing the add-on removes OX Link with it.

OX Link also runs from anywhere else, such as Applications: build it (below) and open
`dist/OX-Link-<version>.dmg`. A copy that arrives as a browser download is blocked the first
time, because OX Link isn't signed with a paid Apple Developer ID. Open **System Settings ›
Privacy & Security**, scroll down to the message about OX Link, click **Open Anyway**, and
confirm.

## Privacy and safety

- OX Link only listens on your own Mac (`127.0.0.1`, port 47474). Other computers can't reach it.
- It only connects to OX Amp Top Boxes it found on your network, and only on the OX's two ports
  (4740 and 4718). It checks each device really is an OX before using it.
- It only accepts the OX Tone Recall add-on, pages you serve on your own Mac while developing, and
  non-browser tools on your Mac. A website open in your browser can't use it to reach your OX.
- It sends nothing to the internet and collects nothing. What it does is logged to
  `~/Library/Logs/OX Link.log` (menu: **Show Log**).
- OX Link passes messages through unchanged. What gets read from or written to the OX is up to
  the OX Tone Recall add-on, which only ever writes tone settings, and only when you press
  **Recall**.

## How it works

The panel opens `ws://127.0.0.1:47474` and sends one JSON message first:

| Request | Answer |
|---|---|
| `{"op":"list"}` | `{"app":"OX Link","version":"…","state":"…","devices":[{"name":"OX001234","host":"OX001234.local","address":"192.168.1.40"}]}` |
| `{"op":"connect","host":"OX001234","port":4740}` | `{"ok":true}`, then every message in either direction is passed through unchanged |

A refused request answers `{"ok":false,"error":"…"}` and closes. `host` may be the OX's name,
network name or address, but must be an OX that OX Link found.

OX Link finds OXes through Bonjour (`_uadevice._tcp`) and confirms each one with a single
read-only request to the OX's audio engine.

## Build

Needs macOS 13 or later and Apple's command line tools (`xcode-select --install`).

The copy inside OX Tone Recall is this build, put there by that project's
`scripts/bundle-ox-link.sh`.

```sh
./build.sh                  # dist/OX-Link-<version>.dmg, .zip and SHA256SUMS.txt
VERSION=0.2.0 ./build.sh
```

Without signing settings the app is signed ad hoc. With a Developer ID it is signed and
notarized instead, and macOS no longer blocks the first launch:

```sh
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=ox-link ./build.sh
```

`NOTARY_PROFILE` is a keychain profile made once with `xcrun notarytool store-credentials`.

## Releases

Pushing a tag like `v0.1.0` runs the **Release** workflow on GitHub: it builds OX Link from that
tag on GitHub's own macOS machine and publishes the disk image, zip and checksums as a release.

## License

MIT. See [LICENSE](LICENSE).
