#!/bin/sh
# Unit tests for the hostupdater shell logic. Runs on any POSIX shell,
# including Git Bash on Windows. No root, dnsmasq or network required.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t hostupdater)
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

bad() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '       %s\n' "$2"
}

assert_eq() {
	if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi
}

assert_contains() {
	if grep -q "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "missing [$2] in $1"; fi
}

assert_not_contains() {
	if grep -q "$2" "$1" 2>/dev/null; then bad "$3" "unexpected [$2] in $1"; else ok "$3"; fi
}

mkdir -p "$TMP/mockbin" "$TMP/tmp" "$TMP/backup" "$TMP/cache"

cat > "$TMP/mockbin/uci" <<'EOF'
#!/bin/sh
exit 1
EOF

cat > "$TMP/mockbin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF

cat > "$TMP/mockbin/curl" <<'EOF'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--connect-timeout|--max-time|--retry|--retry-delay|--max-filesize) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
mode=$(cat "$MOCK_ROOT/mode" 2>/dev/null || echo ok)
[ "$mode" = "fail" ] && exit 22
[ "$mode" = "html" ] && { printf '<!DOCTYPE html><html><body>error</body></html>' > "$out"; exit 0; }
case "$url" in
	*good2*) printf '1.2.3.5\ttwo.example\r\n1.2.3.9\tdup.example\r\n' > "$out" ;;
	*good*)  printf '1.2.3.4\tone.example\r\n1.2.3.4\tdup.example\r\n' > "$out" ;;
	*extra*) printf '1.2.3.7\textra.example\r\n' > "$out" ;;
	*) : > "$out" ;;
esac
exit 0
EOF

chmod +x "$TMP/mockbin/"*

export MOCK_ROOT="$TMP"
export PATH="$TMP/mockbin:$PATH"

export HOSTUPDATER_LIB=1
export HOSTUPDATER_CONFIG="$TMP/config"
export HOSTUPDATER_SOURCES="$TMP/sources.conf"
export HOSTUPDATER_BACKUP="$TMP/backup"
export HOSTUPDATER_CACHE="$TMP/cache"
export HOSTUPDATER_ETC_HOSTS="$TMP/etc_hosts"
export HOSTUPDATER_TARGET="$TMP/target.hosts"
export HOSTUPDATER_DEFAULT_TARGET="$TMP/target.hosts"
export HOSTUPDATER_TMP="$TMP/tmp"
export HOSTUPDATER_LOG="$TMP/hostupdater.log"
export HOSTUPDATER_STATE="$TMP/tmp/state.json"
export HOSTUPDATER_PID="$TMP/hostupdater.pid"
export HOSTUPDATER_LOCK="$TMP/lock"
export HOSTUPDATER_NO_DNS=1

# shellcheck disable=SC1090
. "$ROOT/files/usr/bin/hostupdater"

printf 'parse_hosts\n'
cat > "$TMP/raw.hosts" <<'EOF'
# comment
1.2.3.4	good.example	# inline comment
1.2.3.4	a.example	b.example
999.1.1.1	bad.example
2001:db8::1	v6.example
1.2.3.4	-bad.example
not-an-ip	skip.example

1.2.3.4
EOF
parse_hosts "$TMP/raw.hosts" "$TMP/parsed.hosts"
assert_eq "$(wc -l < "$TMP/parsed.hosts" | tr -d ' ')" "3" "drops comments, inline comments, invalid IPs and bad hostnames"
assert_contains "$TMP/parsed.hosts" "good.example" "keeps hostname before inline comment"
assert_not_contains "$TMP/parsed.hosts" "# inline" "strips inline comment"
assert_contains "$TMP/parsed.hosts" "a.example	b.example" "keeps multiple hostnames"

printf 'sources.conf parsing (CRLF)\n'
printf 'one|http://example.test/good|1\r\n# note\ntwo|http://example.test/good2|0\r\n' > "$HOSTUPDATER_SOURCES"
assert_eq "$(get_sources)" "one|http://example.test/good|1" "enabled sources are trimmed and CRLF-safe"
assert_eq "$(get_all_sources | wc -l | tr -d ' ')" "2" "disabled sources are visible to status"

printf 'full update with two sources\n'
printf 'one|http://example.test/good|1\ntwo|http://example.test/good2|1\n' > "$HOSTUPDATER_SOURCES"
echo ok > "$MOCK_ROOT/mode"
if do_update >/dev/null 2>&1; then ok "update exits 0"; else bad "update exits 0"; fi
assert_contains "$HOSTUPDATER_TARGET" "one.example" "first source entries written"
assert_contains "$HOSTUPDATER_TARGET" "two.example" "second source entries written"
assert_contains "$HOSTUPDATER_TARGET" "1.2.3.4	dup.example" "first source wins duplicate hostname"
assert_not_contains "$HOSTUPDATER_TARGET" "1.2.3.9	dup.example" "later duplicate hostname dropped"
A_POS=$(awk '/BEGIN SOURCE: one/{print NR}' "$HOSTUPDATER_TARGET")
B_POS=$(awk '/BEGIN SOURCE: two/{print NR}' "$HOSTUPDATER_TARGET")
if [ -n "$A_POS" ] && [ -n "$B_POS" ] && [ "$A_POS" -lt "$B_POS" ]; then
	ok "source order preserved (one before two)"
else
	bad "source order preserved (one before two)"
fi
assert_eq "$(grep -c 'BEGIN SOURCE' "$HOSTUPDATER_TARGET")" "2" "both source blocks present"
assert_contains "$HOSTUPDATER_STATE" '"running":false' "state reports not running"

FIRST_TARGET="$TMP/target.first"
cp "$HOSTUPDATER_TARGET" "$FIRST_TARGET"

printf 'failed download keeps last-known-good\n'
echo fail > "$MOCK_ROOT/mode"
if do_update >/dev/null 2>&1; then ok "update still succeeds with caches"; else bad "update still succeeds with caches"; fi
if cmp -s "$FIRST_TARGET" "$HOSTUPDATER_TARGET"; then ok "target unchanged on total download failure"; else bad "target unchanged on total download failure"; fi
assert_contains "$HOSTUPDATER_STATE" '"status":"stale"' "state marks cached sources as stale"
[ -f "$HOSTUPDATER_CACHE/one.hosts" ] && ok "cache retained" || bad "cache retained"

printf 'single source update preserves other sources\n'
echo ok > "$MOCK_ROOT/mode"
if do_update_source one >/dev/null 2>&1; then ok "update-source exits 0"; else bad "update-source exits 0"; fi
assert_contains "$HOSTUPDATER_TARGET" "two.example" "other source survives update-source"
assert_contains "$HOSTUPDATER_TARGET" "one.example" "requested source present"

printf 'single source failure leaves target untouched\n'
cp "$HOSTUPDATER_TARGET" "$TMP/target.before"
echo fail > "$MOCK_ROOT/mode"
if do_update_source two >/dev/null 2>&1; then bad "failed update-source returns non-zero"; else ok "failed update-source returns non-zero"; fi
if cmp -s "$TMP/target.before" "$HOSTUPDATER_TARGET"; then ok "target unchanged after failed update-source"; else bad "target unchanged after failed update-source"; fi

printf 'HTML error page rejected\n'
printf 'one|http://example.test/good|1\nthree|http://example.test/extra|1\n' > "$HOSTUPDATER_SOURCES"
echo html > "$MOCK_ROOT/mode"
if do_update >/dev/null 2>&1; then ok "update continues with cached sources"; else bad "update continues with cached sources"; fi
[ ! -f "$HOSTUPDATER_CACHE/three.hosts" ] && ok "HTML content is not cached" || bad "HTML content is not cached"
assert_contains "$HOSTUPDATER_STATE" '"name":"three","status":"fail"' "HTML source reported as failed"

printf 'no enabled sources\n'
printf 'one|http://example.test/good|0\n' > "$HOSTUPDATER_SOURCES"
if do_update >/dev/null 2>&1; then bad "no enabled sources returns non-zero"; else ok "no enabled sources returns non-zero"; fi

printf 'target path safety\n'
assert_eq "$(HOSTUPDATER_TARGET=/etc/hosts get_target)" "$HOSTUPDATER_DEFAULT_TARGET" "rejects /etc/hosts"
assert_eq "$(HOSTUPDATER_TARGET=relative/path get_target)" "$HOSTUPDATER_DEFAULT_TARGET" "rejects relative paths"
assert_eq "$(HOSTUPDATER_TARGET=/tmp/../etc/hosts get_target)" "$HOSTUPDATER_DEFAULT_TARGET" "rejects dot-dot components"
assert_eq "$(HOSTUPDATER_TARGET='/tmp/with space' get_target)" "$HOSTUPDATER_DEFAULT_TARGET" "rejects whitespace"
assert_eq "$(HOSTUPDATER_TARGET=/ get_target)" "$HOSTUPDATER_DEFAULT_TARGET" "rejects root path"
assert_eq "$(HOSTUPDATER_TARGET=/tmp/custom.hosts get_target)" "/tmp/custom.hosts" "accepts absolute safe path"

printf 'dnsmasq addnhosts management\n'
export DNSMASQ_SECTION="dhcp.@dnsmasq[0]"
DHCP_STATE="$TMP/dhcp.addnhosts"
uci() {
	while [ "$1" = "-q" ]; do shift; done
	case "$1" in
		get) return 0 ;;
		show) [ -f "$DHCP_STATE" ] && cat "$DHCP_STATE"; return 0 ;;
		delete) : > "$DHCP_STATE"; return 0 ;;
		add_list)
			val=${2#*=}
			printf "'%s' " "$val" >> "$DHCP_STATE"
			return 0
			;;
		commit) return 0 ;;
	esac
	return 1
}
printf "'/etc/hostupdater/hosts.old' '/srv/keep.hosts'\n" > "$DHCP_STATE"
ADDN_CHANGED=0
if ensure_addnhosts; then ok "addnhosts change detected"; else bad "addnhosts change detected"; fi
assert_contains "$DHCP_STATE" "$HOSTUPDATER_TARGET" "current target registered"
assert_contains "$DHCP_STATE" "/srv/keep.hosts" "unmanaged addnhosts entry preserved"
assert_not_contains "$DHCP_STATE" "hosts.old" "stale managed addnhosts entry removed"
ADDN_CHANGED=0
if ensure_addnhosts; then bad "second ensure is a no-op"; else ok "second ensure is a no-op"; fi
assert_eq "$ADDN_CHANGED" "0" "no-op ensure does not mark change"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
