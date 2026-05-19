#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${script_dir}/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "${script_dir}/.env"
    set +a
fi

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/fuzzel-steam-launcher"
icons_dir="${cache_dir}/icons"
api_key="${STEAM_API_KEY:-}"
steamid="${STEAM_ID64:-}"
cache_file="${cache_dir}/owned-games.json"

usage() {
    cat <<'EOF'
Usage: fuzzel-steam.sh

Required configuration, provided either by environment variables or a .env file
next to this script:
  STEAM_API_KEY  Your Steam Web API key
  STEAM_ID64     Your SteamID64

Example .env:
  STEAM_API_KEY="your_api_key"
  STEAM_ID64="00000008000000000"

Example one-off run:
  STEAM_API_KEY="your_api_key" STEAM_ID64="00000008000000000" ./fuzzel-steam.sh

You can get a Steam Web API key from:
  https://steamcommunity.com/dev/apikey
EOF
}

require_env() {
    if [ -z "$api_key" ] || [ -z "$steamid" ]; then
        usage >&2
        exit 1
    fi
}

depchecks() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Please install jq." >&2
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Please install curl." >&2
        exit 1
    fi

    if ! command -v fuzzel >/dev/null 2>&1; then
        echo "Please install fuzzel." >&2
        exit 1
    fi

    if ! command -v steam >/dev/null 2>&1; then
        echo "Please install Steam." >&2
        exit 1
    fi

    if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
        echo "Please install ImageMagick (magick or convert)." >&2
        exit 1
    fi
}

sync_icons() {
    mkdir -p "$icons_dir"

    (
        flock -n 9 || exit 0

        local cmd="magick"
        if ! command -v magick >/dev/null 2>&1; then
            if command -v convert >/dev/null 2>&1; then
                cmd="convert"
            else
                exit 0
            fi
        fi

        jq -r '.response.games[] | "\(.appid) \(.img_icon_url)"' "$cache_file" | while read -r appid icon_hash; do
            png_file="${icons_dir}/${appid}.png"
            if [ ! -f "$png_file" ]; then
                jpg_file="${HOME}/.steam/steam/appcache/librarycache/${appid}/${icon_hash}.jpg"
                if [ -f "$jpg_file" ]; then
                    "$cmd" "$jpg_file" "$png_file"
                fi
            fi
        done
    ) 9>"${cache_dir}/icons.lock" &
}

update_cache() {
    mkdir -p "$cache_dir"

    if [ ! -f "$cache_file" ] || find "$cache_file" -mtime +7 | grep -q .; then
        curl -fsSL \
            --get \
            --data-urlencode "key=${api_key}" \
            --data-urlencode "steamid=${steamid}" \
            --data-urlencode "include_appinfo=1" \
            --data-urlencode "include_played_free_games=1" \
            --data-urlencode "format=json" \
            "https://api.steampowered.com/IPlayerService/GetOwnedGames/v0001/" \
            -o "$cache_file"
    fi

    sync_icons
}

build_game_list() {
    jq --arg icons "$icons_dir" -r '
        .response.games
        | sort_by(.name)
        | .[]
        | "\(.name) - \(.appid)\u0000icon\u001f\($icons)/\(.appid).png,steam"
    ' "$cache_file"
}

main() {
    choice="$(build_game_list | fuzzel --dmenu --prompt "Games: ")"

    [ -z "$choice" ] && exit 0

    choiceid="$(awk '{print $NF}' <<< "$choice")"
    steam -applaunch "$choiceid" >/dev/null 2>&1 &
}

require_env
depchecks
update_cache
main
