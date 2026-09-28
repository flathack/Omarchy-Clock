#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
runtime_dir="$data_home/omarchy-clock"
link="$HOME/.config/omarchy/plugins/steven.clock"

mkdir -p "$runtime_dir" "$(dirname "$link")"
python -m venv "$runtime_dir/venv"
"$runtime_dir/venv/bin/python" -m pip install -r "$plugin_dir/requirements.txt"
omarchy plugin validate "$plugin_dir"

if [[ -L "$link" ]]; then
  [[ "$(readlink -f "$link")" == "$plugin_dir" ]] || {
    echo "Another plugin is already linked at $link" >&2
    exit 1
  }
elif [[ -e "$link" ]]; then
  echo "A plugin already exists at $link; move it aside before installing." >&2
  exit 1
else
  ln -s "$plugin_dir" "$link"
fi

if [[ -f "$HOME/.config/omarchy/shell.json" ]]; then
  cp -a "$HOME/.config/omarchy/shell.json" \
    "$HOME/.config/omarchy/shell.json.bak.omarchy-clock.$(date +%Y%m%d-%H%M%S)"
fi
omarchy-shell shell rescanPlugins
omarchy plugin enable steven.clock
omarchy restart shell
