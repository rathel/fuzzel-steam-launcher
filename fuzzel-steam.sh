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
force_refresh=0

usage() {
    cat <<'EOF'
Usage: fuzzel-steam.sh
       fuzzel-steam.sh --refresh

Options:
  --refresh      Force-refresh the owned games cache before opening fuzzel

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

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --refresh)
                force_refresh=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
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

    if [ "$force_refresh" -eq 1 ] || [ ! -f "$cache_file" ] || find "$cache_file" -mtime +7 | grep -q .; then
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

steam_library_paths() {
    local library_file="${HOME}/.steam/steam/steamapps/libraryfolders.vdf"

    printf '%s\n' "${HOME}/.steam/steam"

    if [ -f "$library_file" ]; then
        awk -F '"' '
            $2 == "path" { print $4 }
            $2 ~ /^[0-9]+$/ && $4 ~ /^\// { print $4 }
        ' "$library_file"
    fi
}

installed_appids() {
    local library manifest appid

    while IFS= read -r library; do
        for manifest in "${library}/steamapps"/appmanifest_*.acf; do
            [ -f "$manifest" ] || continue
            appid="${manifest##*/appmanifest_}"
            printf '%s\n' "${appid%.acf}"
        done
    done < <(steam_library_paths | sort -u)
}

build_game_list() {
    local installed
    installed="$(installed_appids | jq -Rn 'reduce inputs as $appid ({}; .[$appid] = true)')"

    jq --arg icons "$icons_dir" --argjson installed "$installed" -r '
        .response.games
        | sort_by(.name)
        | .[] as $game
        | "\(if $installed[$game.appid | tostring] then "[i] " else "" end)\($game.name) - \($game.appid)\u0000icon\u001f\($icons)/\($game.appid).png,steam"
    ' "$cache_file"
}

main() {
    choice="$(build_game_list | fuzzel --dmenu --prompt "Games: ")"

    [ -z "$choice" ] && exit 0

    choiceid="$(awk '{print $NF}' <<< "$choice")"
    steam -applaunch "$choiceid" >/dev/null 2>&1 &
}

parse_args "$@"
require_env
depchecks
update_cache
main
