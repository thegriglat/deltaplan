#!/usr/bin/env bash
# Тексты «некоммерческий / non-commercial / NC / только для личного» в игре, README, сайте (SA-1). Из корня копии.
cd "$(dirname "$0")/../../.."
grep -rIn -i -E 'некоммерч|non-?commercial|не коммерч|personal use|личного использован|⚠ ?NC|CC-?BY-?NC|для себя' \
  README.md LICENSE CLAUDE.md REQUIREMENTS.md TODO.md ASSETS.md CHANGELOG.md locale configs scripts scenes site/content site/hugo.toml site/layouts site/i18n .github \
  2>/dev/null | grep -v 'site/themes' | cut -c1-260
