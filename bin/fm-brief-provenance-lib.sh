#!/usr/bin/env bash

FM_BRIEF_PROVENANCE_SCHEMA=fm-brief-provenance.v1

fm_brief_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fm_brief_contract_sha256() {
  local brief=$1 normalized status
  normalized="${TMPDIR:-/tmp}/fm-brief-contract.$$"
  awk '
    /^<!-- fm-brief-editable:start:(task|charter|routing-scope) -->$/ {
      print
      print "<firstmate-editable-section>"
      editable=1
      next
    }
    editable && /^<!-- fm-brief-editable:end -->$/ {
      editable=0
      print
      next
    }
    editable { next }
    { print }
  ' "$brief" > "$normalized" || { rm -f -- "$normalized"; return 1; }
  [ "$(grep -c '^<!-- fm-brief-editable:start:' "$brief" 2>/dev/null || true)" -gt 0 ] \
    || { rm -f -- "$normalized"; return 1; }
  [ "$(grep -c '^<!-- fm-brief-editable:start:' "$brief" 2>/dev/null || true)" \
    -eq "$(grep -c '^<!-- fm-brief-editable:end -->$' "$brief" 2>/dev/null || true)" ] \
    || { rm -f -- "$normalized"; return 1; }
  fm_brief_sha256 "$normalized"
  status=$?
  rm -f -- "$normalized"
  return "$status"
}

fm_brief_provenance_create() {
  local brief=$1 provenance=$2 protocol=$3 generated contract tmp
  generated=$(fm_brief_sha256 "$brief") || return 1
  contract=$(fm_brief_contract_sha256 "$brief") || return 1
  tmp="$provenance.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_BRIEF_PROVENANCE_SCHEMA"
    printf 'status_writer_protocol=%s\n' "$protocol"
    printf 'generated_sha256=%s\n' "$generated"
    printf 'contract_sha256=%s\n' "$contract"
    printf 'delivered_sha256=-\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$provenance"
}

fm_brief_provenance_verify() {
  local brief=$1 provenance=$2 expected_protocol=$3
  local schema protocol generated contract delivered current current_contract tmp
  [ -f "$provenance" ] && [ ! -L "$provenance" ] || return 1
  [ "$(wc -l < "$provenance" | tr -d ' ')" -eq 5 ] || return 1
  schema=$(awk -F= '$1 == "schema" { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1) print value; else exit 1 }' "$provenance") || return 1
  protocol=$(awk -F= '$1 == "status_writer_protocol" { count++; value=substr($0, index($0, "=") + 1) } END { if (count == 1) print value; else exit 1 }' "$provenance") || return 1
  generated=$(awk -F= '$1 == "generated_sha256" { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$provenance") || return 1
  contract=$(awk -F= '$1 == "contract_sha256" { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$provenance") || return 1
  delivered=$(awk -F= '$1 == "delivered_sha256" { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$provenance") || return 1
  [ "$schema" = "$FM_BRIEF_PROVENANCE_SCHEMA" ] || return 1
  [ "$protocol" = "$expected_protocol" ] || return 1
  case "$generated" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$contract" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$delivered" in -) ;; ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#generated}" -eq 64 ] && [ "${#contract}" -eq 64 ] || return 1
  [ "$delivered" = - ] || [ "${#delivered}" -eq 64 ] || return 1
  current=$(fm_brief_sha256 "$brief") || return 1
  if [ "$delivered" != - ]; then
    [ "$current" = "$delivered" ]
    return
  fi
  if [ "$current" != "$generated" ]; then
    current_contract=$(fm_brief_contract_sha256 "$brief") || return 1
    [ "$current_contract" = "$contract" ] || return 1
  fi
  tmp="$provenance.tmp.$$"
  awk -v digest="$current" '
    /^delivered_sha256=/ { print "delivered_sha256=" digest; next }
    { print }
  ' "$provenance" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$provenance"
}
