# Release and version provenance

The TeamCity version this stack pins, where that pin came from, and how to move it forward.

## Pinned version

| Field | Value |
|---|---|
| Display version | `2026.1.3` |
| Build number | `222742` |
| Build date | 2026-07-20 |
| Server protocol version | `17.2.0.0` |
| Project config version | `2025.3` |
| Bundled JRE | Amazon Corretto 21.0.10.7.1 |
| Base image OS | Ubuntu 24.04 |

`TC_VERSION` in `stack/.env` holds the pin. It maps directly to the Docker tags
`jetbrains/teamcity-server:2026.1.3` and `jetbrains/teamcity-agent:2026.1.3`, both of which publish
a native `arm64` image alongside `amd64`.

## Where the pin came from

This repository began as an unpacked TeamCity `.tar.gz` distribution in `src/` — the server plus
its bundled build agent. That tree was removed once the stack moved to the official Docker images,
because it duplicated 1.6 GB of what the images already contain and required a host-installed JRE
to run.

The values in the table above were read out of that tree before it was deleted, from
`buildAgent/lib/build-version.jar!serverVersion.properties.xml`:

```xml
<entry key="Server_Version">17.2.0.0</entry>
<entry key="Display_Version">2026.1.3</entry>
<entry key="Build_Number">222742</entry>
<entry key="Build_Date">20/07/2026</entry>
<entry key="Project_Config_Version">2025.3</entry>
```

The distribution was pristine when removed — never started, no data directory, no configuration
edits — so nothing but the download itself was lost, and the pin above reproduces it exactly.

## Project config version

`Project_Config_Version` (`2025.3`) is the schema version of the XML files TeamCity writes into
`<datadir>/config`. It matters on restore: a data directory written by a newer schema will not load
on an older server. The console records the running version in every backup manifest and refuses a
restore whose recorded version is newer than the target stack.

## Moving the pin

Use `Upgrade` in the console rather than editing `TC_VERSION` by hand. It refuses downgrades below
the version that last wrote the data directory, forces a backup first, and surfaces the one-time
maintenance token TeamCity prints when it needs confirmation to upgrade the data directory.

See [upgrade](tools/upgrade.md) for the full flow.

---

[← Docs index](../README.md#documentation)
