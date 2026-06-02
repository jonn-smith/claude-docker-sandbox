#!/usr/bin/env bash
# palette_preview.sh — render candidate fzf palettes with real ANSI 256-color
# escapes so the user can pick visually. No dependencies beyond a 256-color
# capable terminal (any modern xterm/tmux/iTerm/Konsole/Windows Terminal).
#
# Usage: bash palette_preview.sh
#
# Each block shows: header line, three mock list rows (middle one is the
# "selected" row), the highlight/match color on a sample word, and the raw
# swatches that map to fzf roles (border, header, prompt, sel-bg, sel-fg, hl).

set -u

fg() { printf '\033[38;5;%sm' "$1"; }
bg() { printf '\033[48;5;%sm' "$1"; }
rst() { printf '\033[0m'; }
bold() { printf '\033[1m'; }

# Palette = name | border | header | prompt | sel_bg | sel_fg | hl
PALETTES=(
    "1. Sage Green        |108|108|108| 65|230|144"
    "2. Slate Blue        | 67|110| 67| 60|252|117"
    "3. Sand Tan          |179|180|179|137|232|222"
    "4. Mono + Cyan       |244|250| 80|238|230| 80"
    "5. Solarized Dark    |136|136| 37|235|254| 64"
    "6. Dracula Purple    |141|117|117| 60|230|141"
    "7. Forest Deep Green | 65|108| 71| 22|230|108"
    "8. Nord Frost        |109|152|109|240|254|110"
)

render_palette() {
    local spec=$1
    local name border header prompt sel_bg sel_fg hl
    IFS='|' read -r name border header prompt sel_bg sel_fg hl <<<"$spec"

    # Top border with name inset
    printf '%s╭─ %s%s%s ' "$(fg "$border")" "$(bold)" "$name" "$(rst)$(fg "$border")"
    local fill=$((60 - ${#name} - 4))
    [ "$fill" -lt 0 ] && fill=0
    printf '%*s' "$fill" '' | tr ' ' '─'
    printf '╮%s\n' "$(rst)"

    # Header line (info row)
    printf '%s│%s ' "$(fg "$border")" "$(rst)"
    printf '%s%s%s' "$(fg "$header")" "claude-sandbox · area-A · ENTER select · ESC back" "$(rst)"
    printf '%s%*s│%s\n' "$(fg "$border")" 11 '' "$(rst)"

    # Separator
    printf '%s├' "$(fg "$border")"
    printf '%*s' 62 '' | tr ' ' '─'
    printf '┤%s\n' "$(rst)"

    # Three list rows. Middle one is "selected": sel_bg + sel_fg, with pointer.
    # Row 1 — unselected
    printf '%s│%s   area-B   /workspace          ✦flags     1h ago' "$(fg "$border")" "$(rst)"
    printf '%s%*s│%s\n' "$(fg "$border")" 6 '' "$(rst)"

    # Row 2 — SELECTED
    printf '%s│%s' "$(fg "$border")" "$(rst)"
    printf '%s%s' "$(bg "$sel_bg")" "$(fg "$sel_fg")"
    printf ' ▶ area-A   /workspace          ✦flags     5m ago    '
    printf '%s' "$(rst)"
    printf '%s│%s\n' "$(fg "$border")" "$(rst)"

    # Row 3 — unselected, with one highlighted match (hl color)
    printf '%s│%s   area-' "$(fg "$border")" "$(rst)"
    printf '%s%sC%s' "$(bold)" "$(fg "$hl")" "$(rst)"
    printf '   /workspace          ✦flags     (none)'
    printf '%s%*s│%s\n' "$(fg "$border")" 6 '' "$(rst)"

    # Swatch row — raw colors as blocks
    printf '%s│%s ' "$(fg "$border")" "$(rst)"
    printf 'roles:  '
    for pair in "border:$border" "header:$header" "prompt:$prompt" "sel-bg:$sel_bg" "sel-fg:$sel_fg" "hl:$hl"; do
        local label=${pair%:*} idx=${pair#*:}
        printf '%s   %s%s%s ' "$(bg "$idx")" "$(rst)" "$(fg "$idx")" "$label"
        printf '%s' "$(rst)"
    done
    printf '%s│%s\n' "$(fg "$border")" "$(rst)"

    # Bottom border
    printf '%s╰' "$(fg "$border")"
    printf '%*s' 62 '' | tr ' ' '─'
    printf '╯%s\n' "$(rst)"
    printf '\n'
}

printf '\n'
printf '  Pick the number that looks best. Tell me e.g. "use 3".\n'
printf '  Each block is a mock of the launcher menu in that palette.\n'
printf '\n'

for p in "${PALETTES[@]}"; do
    render_palette "$p"
done

printf '  Current palette (orange/red) is what you said felt too red.\n'
printf '\n'
