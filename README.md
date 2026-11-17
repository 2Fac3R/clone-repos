# clone-repos

Clone every repository of a GitHub user or organization, automatically organized by programming language and, when one is detected, by framework.

```
<dest>/
├── Python/
│   ├── Django/
│   │   └── my-site
│   └── my-script
├── JavaScript/
│   └── React/
│       └── my-app
└── Other/
    └── notes
```

- **Language** comes from the GitHub API (the repo's primary language). Repos with no detected language go to `Other/`.
- **Framework** is detected by cloning each repo and reading its manifest files. Repos with no recognized framework are placed directly under their language folder.

## Requirements

- `bash` 4.3 or newer (macOS ships 3.2: `brew install bash`)
- `git`
- `curl`
- `jq`

## Installation

```bash
chmod +x clone-repos.sh
```

## Usage

```bash
./clone-repos.sh -n NAME [options]
```

### Options

| Option | Description |
|---|---|
| `-n, --name NAME` | GitHub user or organization name (**required**) |
| `-c, --context TYPE` | `users` (default) or `orgs` |
| `-d, --dest DIR` | Destination directory (default: current directory) |
| `-t, --token TOKEN` | GitHub token (see [Private repositories](#private-repositories)) |
| `-e, --env-file FILE` | Read the token from this `.env` file |
| `-j, --jobs N` | Number of parallel clones (default: 4) |
| `-s, --ssh` | Clone over SSH instead of HTTPS |
| `-f, --forks` | Include forked repos (skipped by default) |
| `-a, --archived` | Include archived repos (skipped by default) |
| `-F, --no-framework` | Organize by language only, skip framework detection |
| `--shallow` | Use `git clone --depth 1` |
| `-N, --dry-run` | Show what would be done without cloning anything |
| `-h, --help` | Show help |

### Examples

```bash
# All public repos of a user, into the current folder
./clone-repos.sh -n 2Fac3R

# An organization, into ~/code, 8 parallel clones, shallow
./clone-repos.sh -n anthropics -c orgs -d ~/code -j 8 --shallow

# Preview the result first
./clone-repos.sh -n 2Fac3R -N

# Everything, including forks and archived repos, over SSH
./clone-repos.sh -n 2Fac3R -s -f -a
```

## Private repositories

Private repos require a GitHub token.

1. Create a token:
   - **Classic token:** select the `repo` scope.
   - **Fine-grained token:** grant read access to *Contents* and *Metadata* on the repos you want.
2. Provide it in one of these ways (highest precedence first):

   | Method | Example |
   |---|---|
   | `-t` flag | `./clone-repos.sh -n me -t ghp_xxx` |
   | Environment variable | `export GITHUB_TOKEN=ghp_xxx` |
   | `.env` file | `GITHUB_TOKEN=ghp_xxx` in `./.env`, in the script's folder, or at the path given with `-e` |

   The variable must be named `GITHUB_TOKEN` or `GH_TOKEN`. The `.env` file is read as plain text and never executed.

   Prefer the environment variable or `.env` over `-t`, since command-line arguments can appear in shell history and process lists. Add `.env` to your `.gitignore`.

### How private repos are listed

- **Your own account** (`-c users`, token belongs to `NAME`): all your repos, public and private, are listed.
- **Someone else's account:** a token cannot list another user's private repos, so only public ones are returned (a warning is shown).
- **Organizations** (`-c orgs`): every repo the token can access. For orgs using SAML SSO, authorize the token for the org in GitHub's token settings.

## HTTPS vs SSH

- **HTTPS (default):** the token, if any, is sent to git as an auth header and never stored in the clone URL or in `.git/config`.
- **SSH (`-s`):** cloning uses your SSH key, which must have access to the repos. The token is only used to list them.

## Framework detection

Frameworks are detected from dependency declarations in manifest files at the repo root or up to three levels deep (excluding `node_modules`, `vendor` and `.git`).

| Ecosystem | Manifest files | Detected frameworks |
|---|---|---|
| JavaScript / TypeScript | `package.json` | Next.js, Nuxt, Gatsby, Remix, Astro, SvelteKit, Angular, React Native, Expo, NestJS, Electron, React, Vue, Svelte, SolidJS, Express, Fastify, Koa, Hapi |
| Python | `requirements.txt`, `pyproject.toml`, `Pipfile`, `setup.py`, `setup.cfg` | Django, FastAPI, Flask, Pyramid, Tornado, Streamlit, Scrapy |
| PHP | `composer.json` | Laravel, Symfony, CakePHP, CodeIgniter, Slim |
| Ruby | `Gemfile` | Rails, Sinatra, Hanami |
| Java / Kotlin | `pom.xml`, `build.gradle(.kts)` | Spring, Quarkus, Micronaut, Android |
| Go | `go.mod` | Gin, Echo, Fiber, Chi, Gorilla |
| Rust | `Cargo.toml` | Actix, Axum, Rocket, Tauri, Bevy |
| Dart | `pubspec.yaml` | Flutter |
| C# | `*.csproj` | ASP.NET, Blazor |
| Elixir | `mix.exs` | Phoenix |
| Swift | `Package.swift` | Vapor |

To add a framework, add an entry to the matching section of `detect_framework()` in the script.

## Behavior notes

- Repos already cloned under the destination are skipped, so the script can be re-run safely to pick up new repos.
- Forks and archived repos are skipped unless `-f` / `-a` are given.
- Each repo is cloned into a temporary folder first, then moved to its final location once the framework is known. The temporary folder is removed on exit.
- Pagination is followed until the last page, so accounts with more than 100 repos are fully covered.
- API errors (bad credentials, rate limit, unknown user) stop the script with a clear message.

## Limitations

- Detection is based on keywords in dependency files, so a repo that merely mentions a framework name there may be misfiled.
- Repos without a manifest file are filed under their language only.
- Monorepos are classified by the first framework found.
- Unauthenticated GitHub API requests are rate limited (60 per hour). Use a token for larger accounts.
