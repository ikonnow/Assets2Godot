<div align="center">
  <h1 align="center">Assets2Godot</h1>
  <p>
    A community asset workspace for the Godot editor — browse, organize and
    import assets from <strong>BlendKit</strong>, <strong>Polyhaven</strong>
    and your own drives, without leaving the editor.
  </p>
  <p>
    <a href="https://github.com/ikonnow/Assets2Godot/releases/latest">
      <img src="https://img.shields.io/github/v/release/ikonnow/Assets2Godot?color=green" alt="Release">
    </a>
    <a href="LICENSE">
      <img src="https://img.shields.io/github/license/ikonnow/Assets2Godot?color=orange" alt="GPLv2">
    </a>
  </p>
  <p>
    <img src="img/Assets2Godot_ambientCG.png" width="844"
      alt="Assets2Godot ambientCG tab — provider tabs, filter row and CC0 asset cards in the Godot editor">
  </p>
</div>

---

## What it is

**Assets2Godot** is a Godot editor plugin that turns the editor into an asset
browser and staging ground for multiple sources at once:

- **Assets2Godot tab** — a local index over your own asset folders (plus
  project files and open-scene resources). Files stay where they are; nothing
  is copied into `res://` until you explicitly import an asset, which stages
  it into `res://imported_assets/<asset_name>/`.
- **BlendKit tab** — the full upstream Blendkit for Godot experience:
  search, filters, plans/login, downloads into `Assets2Godot/bk_assets/`.
- **Polyhaven tab** — the public CC0 catalog (models, textures, HDRIs,
  fonts) via Poly Haven's API, implemented in pure GDScript — no account,
  no helper daemon needed.
- **ambientCG tab** — Ambient CG's CC0 library (materials, 3D models,
  HDRIs, brushes/decals, atlases) as complete ZIP sets, likewise pure
  GDScript.

All provider downloads land under `res://Assets2Godot/<provider>/` —
one shared parent next to your project files, gitignored — with
BlendKit's own root living there too as `Assets2Godot/bk_assets/`.
- **A2G button** — an organization surface over the provider tabs:
  collections, favorites, batch operations (planned, see
  [Roadmap](#roadmap)).

It is built on top of [Blendkit for Godot](https://github.com/BlenderKit/bk_godot)
(GPLv2) and pairs with a fork of the
[Blendkit Client](https://github.com/ikonnow/bk_client) daemon that adds
provider/index endpoints the upstream client doesn't have.

## Status

**Experimental (alpha).** The core surfaces work and are tested, but the
project is under active development — expect rough edges.

| Area | State |
|------|-------|
| Local index browser, thumbnails, staging import | Working |
| BlendKit tab (search/download/login/plans) | Working — upstream feature set |
| Polyhaven provider (catalog, details, downloads) | Working — new in 0.8.0 |
| Quick-download tile on asset cards | Working — new in 0.8.0 |
| Organization overlay (collections, batch ops) | Planned — see `docs/plans/` |
| Additional providers | Planned — see `docs/specs/remote-providers.md` |

## Providers

| Provider | Catalog | Auth | Asset license |
|----------|---------|------|---------------|
| BlendKit | blendkit.com via the `bk_client` daemon | Optional login; free assets need none, Full Plan assets need an account | Per-asset, see blendkit.com |
| Polyhaven | polyhaven.com public API, in-plugin HTTP | None | CC0 |
| Local drives / project | `local_dir` provider in the daemon, indexed in place | None | Yours |

## Requirements

- **Godot Engine 4** (4.4+; CI tests 4.4.1 and 4.7.x)
- **OS:** Windows, Linux, macOS — architectures x86_64 and arm64
- **Recommended:** [Blender](https://www.blender.org/download/) for `.blend`
  assets and HDR/material conversion (same as upstream)
- The **BlendKit tab needs the `bk_client` helper daemon**. Prebuilt binaries
  ship inside each release archive; the Polyhaven tab and the local index
  work without it.

## Installation

The plugin is installed per Godot project.

### From a release ZIP

Download `assets2godot_vX.Y.Z.zip` from
[Releases](https://github.com/ikonnow/Assets2Godot/releases) (or
[build](#building) your own):

1. Extract the ZIP into your project root (where `project.godot` lives).
   - **Do not** copy `addons/` from this repo without building the Client
     binaries first — the BlendKit tab won't start without them.
2. **Project → Project Settings… → Plugins** → enable **Assets2Godot**.

### Upgrading

Always clean-install: delete `addons/assets2godot/`, then install the new
version.

## Usage

Open the **Assets2Godot** workspace in the editor's top bar (next to
**Asset Store**). It hosts three tabs plus the **A2G** button:

### Assets2Godot tab — your own assets, indexed in place

- The left **Sources** tree lists external asset roots, project files and
  the open scene. The right pane browses the index: grid/list views,
  FileSystem-style split modes, search, filters, sort, cached thumbnails.
- Assets are **not copied** into your project automatically. Select files
  and use the context menu to **stage** them into
  `res://imported_assets/<asset_name>/`, where Godot's own importer (FBX,
  glTF, `.blend` via Blender) takes over.
- Works on disconnected drives and missing folders gracefully — index what
  exists, re-scan when a drive comes back.

### BlendKit tab

The upstream Blendkit experience: search blendkit.com inside the editor,
filter by type/category/polygons/license, log in optionally (free assets
need no account), download into `Assets2Godot/bk_assets/` organized by type and asset.
Settings cover download directory, **Model Format** (`.blend` vs glTF),
resolution, UUID naming, Client port and log level — see the in-plugin
**User Guide** link for the full reference.

### Polyhaven tab

Browse the CC0 catalog with provider-native filters (type, categories,
tags), sort options and a resolution hint. Asset cards open a details
popup (metadata, files, preview renders) and offer one-click downloads of
the chosen file variant. Downloads stage through `.part` files and land
in your configured download directory — same staging rules as the local
index.

Right-click any provider card for the **quick-download tile**: a compact
format picker + download action that works the same on BlendKit and
Polyhaven cards.

### A2G button

Opens the organization surface over the provider tabs (collections,
favorites, multi-select and batch import are being built — see
[Roadmap](#roadmap)).

## Architecture

```text
┌──────────────────────────────┐         ┌──────────────────────────┐
│   Assets2Godot plugin        │         │   bk_client daemon (Go)  │
│   (GDScript, this repo)      │         │   (fork: providers,      │
│                              │         │    sqlite index, scan)   │
│  ┌──────────┐ ┌───────────┐ │  HTTP   └───────────┬──────────────┘
│  │ Assets2G │ │ BlendKit  │ │◄────────────────────┤ providers:
│  │   tab    │ │   tab     │ │                     │ blenderkit,
│  └──────────┘ └───────────┘ │                     │ fab_vault, local_dir
│  ┌──────────┐               │                     └───────┬──────────┘
│  │ Polyhaven│── pure GDScript HTTP ──► polyhaven.com      │
│  │   tab    │               │                             │ HTTPS
│  └──────────┘               │                             ▼
└──────────────────────────┬───┘                     blendkit.com
                           │ optional login (browser)
                           ▼
                     Web browser
```

Design notes live in [`docs/specs/architecture.md`](docs/specs/architecture.md)
and [`docs/specs/remote-providers.md`](docs/specs/remote-providers.md).

## Building

Requires **Python 3**; `git` for client sources; **Go** only for
`--from-source`.

```sh
git clone https://github.com/ikonnow/Assets2Godot.git
cd Assets2Godot
python dev.py build
```

By default this downloads the newest stable `bk_client` release from
[ikonnow/bk_client](https://github.com/ikonnow/bk_client) (version pinned
by `CLIENT_API_VERSION` in `client_binary.gd`), verifies manifest sizes and
SHA-256 hashes, stages the binaries and assembles
`out/assets2godot_vX.Y.Z.zip`.

```sh
python dev.py build --tag vX.Y.Z            # pin an exact client release
python dev.py build --from-source           # compile the client from source
python dev.py build --client-dir ../bk_client
python dev.py build --client-bundle bk_client.zip
```

`--from-source` clones the `bk_client` fork, builds an unsigned
host-platform bundle and produces a `_local-<os>-<arch>.zip` development
archive. Fork releases are currently **unsigned** — macOS/Windows binaries
trigger Gatekeeper/SmartScreen warnings; that's expected until signing
secrets are configured in the fork's CI.

## Development

This repository is itself a Godot project — open it in the editor for
development and testing.

```sh
python dev.py build     # client binaries + plugin archive
python dev.py           # all commands
```

| Command | Description |
|---------|-------------|
| `build` | Full build: client release/source + plugin + archive |
| `get-client-release` | Download a published client release |
| `get-client-src` | Clone the `bk_client` fork |
| `build-client` | Build only the Go client |
| `build-plugin` | Install client binaries into the plugin |
| `build-archive` | Create the distributable ZIP |
| `test` | Run the pytest suite (headless Godot) |
| `test-e2e` | Live end-to-end tests (needs network) |

## Testing

```sh
pip install -r requirements-dev.txt
python dev.py build
python dev.py test          # pytest, parallel with pytest-xdist
```

Godot 4 must be on `PATH` as `godot`/`godot4` or via `GODOT`/`GODOT4`.
E2E tests hit the live Blendkit site and need `BLENDERKIT_API_KEY` only
for gated assets; `python dev.py test-e2e` runs them (Playwright Chromium
required for the browser test).

The `tests/test_*.gd` suites are MCP-driven and run inside a live editor
with the godot-ai addon — they're dev tooling, not part of CI.

## Roadmap

- **Organization overlay** — collections, favorites, multi-select and
  batch import across providers (design:
  [`docs/plans/2026-11-07-a2g-org-overlay.md`](docs/plans/2026-11-07-a2g-org-overlay.md)).
- **More providers** — the provider contract is documented in
  [`docs/specs/remote-providers.md`](docs/specs/remote-providers.md); a
  step-by-step skill for adding one lives in
  [`.devin/skills/add-asset-provider/`](.devin/skills/add-asset-provider/SKILL.md).
- **Client signing** — publish signed `bk_client` binaries once
  certificate secrets are configured in the fork.
- **Godot Asset Store** listing once the release line stabilizes.

## Credits & License

Assets2Godot is Free and Open Source Software under **GPLv2**.

It is based on [Blendkit for Godot](https://github.com/BlenderKit/bk_godot)
by **Jakub Ruzicka** and **Andreas Gajdosik** (BlenderKit s.r.o.) — upstream
history, license and notices are preserved. The `bk_client` helper is a
fork of [BlenderKit/bk_client](https://github.com/BlenderKit/bk_client).

The Polyhaven tab uses the Poly Haven logo under the permission stated in
their [API terms](https://polyhaven.com/our-api); see
[`addons/assets2godot/logo/LICENSE`](addons/assets2godot/logo/LICENSE) for
the full attribution notes.

## Support

Assets2Godot is maintained in my spare time. If it saves you time, you can
support the work voluntarily via
[**ingmar.konnow.de/support**](https://ingmar.konnow.de/#/portal/support)
(Stripe, any amount — donations are appreciated, not required, and don't
entitle you to support or priority).

For bugs and feature requests, please use
[GitHub Issues](https://github.com/ikonnow/Assets2Godot/issues) — the
better the description, the easier the fix. For professional collaboration
(migrations, pipeline work, Unreal→Godot tooling), reach out via
[ingmar.konnow.de](https://ingmar.konnow.de) or `ingmar@konnow.de`.

Related project: **UE2Godot** — an Unreal Engine 5 → Godot 4 exporter
that keeps levels playable (lights, collision, volumes, audio arrive as
working Godot nodes, not a flat mesh dump).

## Contributing

Contributions are welcome — see [Issues](https://github.com/ikonnow/Assets2Godot/issues)
and the provider spec for where new work fits. Please keep changes
merge-safe with upstream where practical (see `AGENTS.md`).
