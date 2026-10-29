# Faintprint scan for GitHub Actions

Runs [Faintprint](#about-faintprint) in a GitHub workflow. It installs
Faintprint with your deploy token, scans the MCP servers you name, keeps
the reports as an artefact, and passes or fails the job by the result.

This repository holds only the wrapper. Faintprint itself is distributed
privately: you need the deploy token (a name and a secret) that came with
your licence.

## Use

Store the deploy token as two repository or organisation secrets,
`FAINTPRINT_USER` and `FAINTPRINT_TOKEN` (Settings → Secrets and variables
→ Actions). Then:

```yaml
name: faintprint
on: [push, pull_request]
permissions:
  contents: read
jobs:
  scan:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: faintprint/scan-action@v1
        with:
          scan: |
            .vscode/mcp.json
            servers/notes-tools.json
          deploy-user: ${{ secrets.FAINTPRINT_USER }}
          deploy-token: ${{ secrets.FAINTPRINT_TOKEN }}
```

For a build check that changes only when you decide, pin the step to a
commit instead of `v1`: `faintprint/scan-action@<full commit> # v1.1.0`.
Dependabot can propose new pins.

## Inputs

| input | what it does | default |
|---|---|---|
| `scan` | what to scan, one per line: a saved tool list, a web address, or an MCP client config file in the repository | required |
| `tools` | saved tool lists for local servers named in a config file, one `NAME=FILE` per line (local servers are never started) | none |
| `fail-on` | the "Signs of an attack" level that fails the job: `minor`, `suspicious`, `likely-attack` or `never` | `suspicious` |
| `review` | run the AI review of borderline passages, on your own Anthropic key | `false` |
| `max-cost` | the most one run's AI review may cost, in US dollars; a review estimated above it does not start | `1.00` |
| `allow-unfinished` | let a "not finished" result pass, with a warning | `false` |
| `version` | the Faintprint version to install | `0.3.0` |
| `reports` | the report folder, and the name of the artefact it is kept as | `faintprint-reports` |
| `upload-sarif` | upload the findings to GitHub code scanning, the Security tab (see below) | `false` |
| `sarif-category` | the code scanning category of the upload; two Faintprint steps in one job, or a matrix, need one each | `faintprint-<job id>` |
| `deploy-user` | your deploy token's name: pass `${{ secrets.FAINTPRINT_USER }}` | required |
| `deploy-token` | your deploy token's secret: pass `${{ secrets.FAINTPRINT_TOKEN }}` | required |
| `anthropic-api-key` | your Anthropic API key, used only when `review` is `true` | none |

Outputs: `exit-code` (Faintprint's exit code) and `reports` (the folder).

## The result

The job ends with Faintprint's own exit code, and one line that says why:

| code | job | meaning |
|---|---|---|
| 0 | passes | every server checked, none at or above `fail-on` |
| 1 | fails | at least one server shows signs of an attack at or above `fail-on` |
| 2 | fails | could not run: a wrong input, an unreadable file, or nothing to scan |
| 3 | fails | not finished: an AI review not run, a server not reachable, or a local server without its saved tool list |

A borderline passage is only settled by the AI review, so without it a
server that has one ends "not finished". Turn on `review`, or set
`allow-unfinished: true` to let such a run pass with a warning.

The reports (one page and one JSON file per server, `index.html`,
`summary.json` and `faintprint.sarif`) are kept as an artefact on the run's
summary page, also when the job fails. **On a public repository anyone can
download them.**

## GitHub's Security tab

With `upload-sarif: true` the step uploads `faintprint.sarif` to GitHub
code scanning, and each finding becomes an alert in the repository's
Security tab:

- each sign of an attack, at GitHub's critical (Likely attack), high
  (Suspicious) or medium (Minor) severity;
- a note for each borderline passage the AI review did not read, or read
  and could not decide on.

Each alert points at the line that holds the passage, in a saved tool list
in the repository, or at the server's entry in a config file. The same
finding stays the same alert from run to run, until it is fixed.

The upload needs the workflow permission `security-events: write`, which a
step cannot give itself:

```yaml
permissions:
  contents: read
  actions: read            # private repositories only
  security-events: write
```

Code scanning is free on public repositories. On a private repository it
needs GitHub Code Security on your organisation; without it the upload is
refused and the job fails with one plain line. The upload runs also when the
scan failed, which is when the alerts matter. `faintprint.sarif` is in the
reports either way, for any other tool that reads SARIF.

## The AI review

The review sends the borderline passages it reads, which are the servers'
own text, to Anthropic under your key; nothing from your config files. In a
pipeline it runs without asking, and only when its estimated price is
within `max-cost`:

```yaml
      - uses: faintprint/scan-action@v1
        with:
          scan: .vscode/mcp.json
          review: true
          max-cost: "0.50"
          deploy-user: ${{ secrets.FAINTPRINT_USER }}
          deploy-token: ${{ secrets.FAINTPRINT_TOKEN }}
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

## How it handles your secrets

- The deploy token goes to the install command only, in the password part
  of the index address, which pip prints as `****`; GitHub also blanks any
  secret value it sees in a log.
- The Anthropic key goes to the scan only, and only when `review` is on.
- Inputs reach the step's script through environment variables, never as
  text pasted into a command.
- A pull request from a fork gets no secrets, so the step stops there with
  one plain line. Do not work round this with the `pull_request_target`
  trigger: it would run a stranger's changes with your secrets.

## What it installs

Faintprint at the `version` you choose, from the private index, into its
own environment under the runner's temporary folder, with Python 3.13. At
the default version it installs the exact library versions Faintprint was
tested on (`constraints.txt`), so a new release of a library cannot change
your result overnight. It changes nothing else in your job: your own Python
setup is left as it was, and nothing is cached.

Linux and macOS runners. Not Windows.

## Versions

`v1` moves with every 1.x release; `v1.0.0` and each commit never move. A
new Faintprint release comes with a new 1.x release of this step that makes
it the default. A change that breaks an input would be `v2`.

`v1.1.0` writes `faintprint.sarif` with Faintprint 0.3.0 and later, and adds
`upload-sarif` and `sarif-category`. With an older `version` it scans as
before, without the SARIF file.

## About Faintprint

Faintprint scans the tool lists of Model Context Protocol servers for
signs of a supply-chain attack: hidden instructions to the AI, hidden or
encoded text, look-alike names, and what each server can do.

## Licence

The wrapper in this repository is under the MIT licence (`LICENSE`).
Faintprint itself is not; its terms come with your licence.
