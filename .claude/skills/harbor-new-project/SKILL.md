---
name: harbor-new-project
description: Create a brand-new (greenfield) PHP project in Harbor — scaffold a framework, provision its stack, wire config, and serve at https://<name>.test. Use when someone says "create/start a new <framework> project", "spin up a fresh Laravel/Symfony/CodeIgniter/Magento app in Harbor", or wants a new local site from scratch. For adopting an app that already has code/data, use harbor-migrate-project instead.
---

# Create a new project in Harbor

Assumes `harbor` is on PATH and `harbor setup` has run. `<name>` = URL slug
(lowercase, digits, hyphens) → `https://<name>.test`. Full reference:
`README.md` → "How-to → A".

## One-shot
```bash
harbor new <name> <framework>     # framework: laravel | symfony | codeigniter | magento | plain
```
`new` runs: scaffold → init → up → wire → install → link → open. Done.

Notes:
- **Magento** needs your Marketplace keys in `~/.composer/auth.json` for the
  scaffold (`composer create-project` from repo.magento.com).
- Pin a non-default PHP by adding `harbor php <ver>` first (sets the default for
  new sites) or editing the manifest after init (see below).

## Manual equivalent (each step runnable alone)
Use this when you want control, or `new` failed partway:
```bash
harbor init <name> <framework>                     # allocate ports, write manifest + compose
harbor up <name>                                   # start MySQL (+ OpenSearch/RabbitMQ for Magento)
harbor composer <name> create-project laravel/laravel .   # or symfony/skeleton, codeigniter4/appstarter, magento/project-community-edition
harbor wire <name>                                 # inject DB/Redis/mail into the app config
harbor install <name>                              # framework installer (key:generate+migrate / setup:install / …)
harbor link <name>                                 # https://<name>.test
harbor open <name>
```

## After creation
- **Verify:** `harbor ps` (framework/php/up/linked), load `https://<name>.test`.
- **Seed data:** `harbor seed <name>`.
- **Run framework commands:** `harbor artisan|console|spark|magento <name> …`,
  `harbor composer <name> …`, `harbor node|npm <name> …` (all use the project's pinned PHP/nvm).
- **Debug:** `harbor xdebug on` (trigger-based, port 9003).
- **Consoles:** `harbor mysql|redis|shell <name>`.

## Rules to respect (see CLAUDE.md)
- The manifest `projects/<name>/.harbor/harbor.yml` is the source of truth — edit it
  (framework, php, node, services, docroot, domains, tools, php_ini…) and re-run the
  relevant command; don't hand-edit generated files.
- Containerize CLI tools via manifest `tools:` (e.g. `wkhtmltopdf`) — never
  `brew install` an app's binary dependency.
- Everything binds `127.0.0.1`; TLS is automatic at `link`.
