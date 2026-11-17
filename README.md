# DDEV Manager

> Forked from [sanjayatony/omarchy-ddev-projects](https://github.com/sanjayatony/omarchy-ddev-projects) by Tony S.

A Herd-style bar widget for managing local [DDEV](https://ddev.com/) projects from the Omarchy bar — start/stop projects, open a database admin tool, open the project folder, and check sent email, without leaving the bar.

## Requirements

- [DDEV](https://ddev.com/) at `/usr/bin/ddev` (e.g. the `ddev-bin` AUR package) with a running Docker daemon
- `git` (for the uncommitted-changes badge)
- `notify-send` (completion/failure notifications) and `wl-copy` (copy URL)

## Install

```sh
omarchy plugin add https://github.com/edwinkrisnha/omarchy-ddev-projects.git --enable
```

Choose a bar section when prompted (right is the default).

## Usage

Click the server-rack icon in the bar to open the panel. It lists every project `ddev list` knows about, refreshing automatically every 10 seconds while open.

The header has **Stop all** (`ddev poweroff`) and **Refresh** buttons.

Each project row shows:

- A status dot (accent = running, muted = stopped), the project name and type, and an uncommitted-changes warning badge when a running project's git repo is dirty.
- **Open in browser** — opens the project's primary URL. Right-click copies the URL instead.
- **WordPress admin** — WordPress projects only; opens `/wp-admin/`.
- **Open in editor** — opens the project in your Omarchy default editor.
- **Open terminal** — opens a terminal in the project's root.
- **Open folder** — opens the project's root directory in your file manager.
- **Mailpit** — opens the project's Mailpit inbox (sent emails), no extra setup required.
- **DB Admin** — opens [Adminer](https://www.adminer.org/) for the project's database. On first use per project this installs the `ddev/ddev-adminer` add-on and restarts that project's containers; subsequent clicks just open the browser.
- **Start / Stop** — runs `ddev start` / `ddev stop` for that project. You get a desktop notification when it finishes or fails, so you can close the panel while it runs.

## Configuration

No configuration file — the panel always reflects live `ddev list` output. There's nothing to set in `shell.json` beyond the widget's placement (`omarchy bar move edwin.ddev-projects --section <left|center|right>`).

## Notes

- Every `ddev`/`docker` action the panel runs is wrapped in a `timeout`, with a background watchdog as a second safety net, so a hung command can't permanently disable the panel's buttons.
- If DDEV or Docker stops responding while the panel is open, the panel says so and dims the cards, which then show the last known state.
- DB Admin invokes `ddev`/Docker directly and can restart the project's containers — expected DDEV behavior, not a bug.

## Removal

```sh
omarchy plugin remove edwin.ddev-projects
```

This only removes the plugin — it does not touch any DDEV projects, containers, or data.
