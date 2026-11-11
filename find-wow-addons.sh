#!/bin/sh
# Print the WoW: Forever AddOns folder (…/World of Warcraft/_forever_/Interface/AddOns), or nothing
# if none is found. Used by the Makefile; run it by hand to see what it finds.
#
# Looks in: macOS /Applications; Linux Steam/Proton prefixes (native, Flatpak, SD cards and other
# mounted drives), Faugus, Lutris, Heroic, Bottles and plain Wine prefixes. If several installs
# exist the first one (sorted) is printed and the rest are listed on stderr; pass WOW_ADDONS= to
# the Makefile to pick one.
set -u

suffix="World of Warcraft/_forever_/Interface/AddOns"

if [ -d "/Applications/$suffix" ]; then
	echo "/Applications/$suffix"
	exit 0
fi

roots=""
add() {
	[ -d "$1" ] && roots="$roots
$1"
	return 0
}

add "$HOME/.local/share/Steam/steamapps/compatdata"
add "$HOME/.steam/steam/steamapps/compatdata"
add "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata"
for d in /run/media/*/*/steamapps/compatdata /run/media/*/steamapps/compatdata \
	/media/*/*/steamapps/compatdata /mnt/*/steamapps/compatdata /mnt/*/*/steamapps/compatdata; do
	add "$d"
done
add "$HOME/Faugus"
add "$HOME/.var/app/io.github.Faugus.faugus-launcher"
add "$HOME/Games"
add "$HOME/.local/share/lutris"
add "$HOME/.var/app/net.lutris.Lutris/data/lutris"
add "$HOME/.local/share/bottles"
add "$HOME/.var/app/com.usebottles.bottles/data/bottles"
add "$HOME/.wine"

found=""
old_ifs=$IFS
IFS='
'
for root in $roots; do
	[ -n "$root" ] || continue
	# Skip the Windows system folders inside each prefix; the game never lives there and they are large.
	hits=$(find "$root" -maxdepth 10 \
		\( -name windows -o -name users -o -name ProgramData -o -name Common -o -name 'Common Files' \) -prune \
		-o -type d -path "*/$suffix" -print 2>/dev/null)
	for hit in $hits; do
		real=$(cd "$hit" 2>/dev/null && pwd -P) || continue
		found="$found
$real"
	done
done
IFS=$old_ifs

found=$(printf '%s\n' "$found" | sed '/^$/d' | sort -u)
[ -n "$found" ] || exit 1

first=$(printf '%s\n' "$found" | head -n 1)
count=$(printf '%s\n' "$found" | wc -l)
if [ "$count" -gt 1 ]; then
	echo "find-wow-addons.sh: several installs found, using the first; pass WOW_ADDONS= to choose:" >&2
	printf '%s\n' "$found" | sed 's/^/  /' >&2
fi
echo "$first"
