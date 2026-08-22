#!/usr/bin/env bash
# fm-escalation-lib.sh - own away-mode escalation buffering and keyed-decision revalidation.
#
# Decision rows retain task, key, and opening-transition identity privately;
# companion seen markers also retain status-file identity.
# Together they let delayed delivery discard resolved records and treat a later
# reopening as new work.
# Non-decision rows remain opaque display text.
set -u

_fm_escalation_hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d ' ' -f1; fi
}

decision_escalation_display() {  # <task> <key> <verb> <note>
  local task=$1 key=$2 verb=$3 note=$4 display
  display="$task.status: $verb [key=$key]: $note"
  printf '%s' "$display" | tr '\t\r\n' '   '
}

FM_DECISION_CURRENT_ORIGIN=
FM_DECISION_CURRENT_DISPLAY=
FM_DECISION_CURRENT_FILE_IDENT=
FM_DECISION_CURRENT_RECORDS=
decision_current_records() {  # <state> <task>
  local state=$1 task=$2 status before after
  status="$state/$task.status"
  FM_DECISION_CURRENT_FILE_IDENT=
  FM_DECISION_CURRENT_RECORDS=
  if [ ! -e "$status" ] && [ ! -L "$status" ]; then
    return 1
  fi
  before=$(_fm_open_decisions_file_ident "$status") || return 2
  FM_DECISION_CURRENT_RECORDS=$(status_open_decisions_with_origin "$status") || return 2
  after=$(_fm_open_decisions_file_ident "$status") || return 2
  [ "$before" = "$after" ] || return 2
  FM_DECISION_CURRENT_FILE_IDENT=$before
  return 0
}

decision_current_record() {  # <state> <task> <key>
  local state=$1 task=$2 wanted=$3 key verb note origin rc
  FM_DECISION_CURRENT_ORIGIN=
  FM_DECISION_CURRENT_DISPLAY=
  if decision_current_records "$state" "$task"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS=$(printf '\t') read -r key verb note origin; do
    [ "$key" = "$wanted" ] || continue
    FM_DECISION_CURRENT_ORIGIN=$origin
    FM_DECISION_CURRENT_DISPLAY=$(decision_escalation_display "$task" "$key" "$verb" "$note")
    return 0
  done <<EOF
$FM_DECISION_CURRENT_RECORDS
EOF
  return 1
}

decision_seen_path() {  # <state> <task> <key>
  local state=$1 task=$2 key=$3 digest
  digest=$(_fm_escalation_hash_text "$task"$'\t'"$key")
  printf '%s/.subsuper-seen-decision-%s' "$state" "$digest"
}

mark_decision_seen() {  # <state> <task> <key> <file-ident> <origin> <display>
  local state=$1 task=$2 key=$3 file_ident=$4 origin=$5 display=$6 seen
  seen=$(decision_seen_path "$state" "$task" "$key")
  printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$key" "$file_ident" "$origin" "$display" > "$seen"
}

decision_status_is_seen() {  # <state> <task> <status-line>
  local state=$1 task=$2 line=$3 key seen rc
  key=$(_fm_decision_key "$line") || return 1
  if decision_current_record "$state" "$task" "$key"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 2 ] && return 1
  [ "$rc" -eq 1 ] && return 0
  seen=$(decision_seen_path "$state" "$task" "$key")
  [ "$(cut -f3 "$seen" 2>/dev/null || true)" = "$FM_DECISION_CURRENT_FILE_IDENT" ] \
    && [ "$(cut -f4 "$seen" 2>/dev/null || true)" = "$FM_DECISION_CURRENT_ORIGIN" ] \
    && [ "$(cut -f5- "$seen" 2>/dev/null || true)" = "$FM_DECISION_CURRENT_DISPLAY" ]
}

reconcile_decision_seen_markers() {  # <state>
  local state=$1 seen task key file_ident origin display extra rc
  for seen in "$state"/.subsuper-seen-decision-*; do
    [ -e "$seen" ] || continue
    IFS=$(printf '\t') read -r task key file_ident origin display extra < "$seen" || true
    if [ -z "$task" ] || [ -z "$key" ] || [ -z "$file_ident" ] \
      || [ -z "$origin" ] || [ -n "$extra" ]; then
      rm -f "$seen"
      continue
    fi
    if decision_current_record "$state" "$task" "$key"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 1 ] \
      || { [ "$rc" -eq 0 ] && { [ "$FM_DECISION_CURRENT_FILE_IDENT" != "$file_ident" ] \
        || [ "$FM_DECISION_CURRENT_ORIGIN" != "$origin" ] \
        || [ "$FM_DECISION_CURRENT_DISPLAY" != "$display" ]; }; }; then
      rm -f "$seen"
    fi
  done
}

escalate_add_decision() {  # <state> <task> <key> <verb> <note> <origin> <file-ident>
  local state=$1 task=$2 key=$3 verb=$4 note=$5 origin=$6 file_ident=$7 display seen buf
  display=$(decision_escalation_display "$task" "$key" "$verb" "$note")
  seen=$(decision_seen_path "$state" "$task" "$key")
  if [ "$(cut -f3 "$seen" 2>/dev/null || true)" = "$file_ident" ] \
    && [ "$(cut -f4 "$seen" 2>/dev/null || true)" = "$origin" ] \
    && [ "$(cut -f5- "$seen" 2>/dev/null || true)" = "$display" ]; then
    return 0
  fi
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || date +%s > "${buf}.since"
  printf 'decision\t%s\t%s\t%s\t%s\n' "$task" "$key" "$origin" "$display" >> "$buf"
  mark_decision_seen "$state" "$task" "$key" "$file_ident" "$origin" "$display"
}

buffer_open_decisions_for_task() {  # <state> <task>
  local state=$1 task=$2 key verb note origin rc found=1
  if decision_current_records "$state" "$task"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS=$(printf '\t') read -r key verb note origin; do
    [ -n "$key" ] && [ -n "$origin" ] || continue
    escalate_add_decision "$state" "$task" "$key" "$verb" "$note" "$origin" \
      "$FM_DECISION_CURRENT_FILE_IDENT"
    found=0
  done <<EOF
$FM_DECISION_CURRENT_RECORDS
EOF
  return "$found"
}

decision_current_displays() {  # <state>
  local state=$1 status task key verb note origin rc
  for status in "$state"/*.status; do
    if [ ! -e "$status" ] && [ ! -L "$status" ]; then continue; fi
    [ -f "$status" ] && [ ! -L "$status" ] || return 2
    task=${status##*/}
    task=${task%.status}
    case "$task" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
    if decision_current_records "$state" "$task"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 0 ] || return "$rc"
    while IFS=$(printf '\t') read -r key verb note origin; do
      [ -n "$key" ] && [ -n "$origin" ] || continue
      decision_escalation_display "$task" "$key" "$verb" "$note"
      printf '\n'
    done <<EOF
$FM_DECISION_CURRENT_RECORDS
EOF
  done
}

legacy_buffered_decision() {  # <state> <plain-buffer-row>
  local state=$1 row=$2 task line verb key rc
  FM_BUFFERED_DECISION_TASK=
  FM_BUFFERED_DECISION_KEY=
  FM_BUFFERED_DECISION_ORIGIN=
  FM_BUFFERED_DECISION_DISPLAY=
  case "$row" in *" | "*) return 1 ;; esac
  task=${row%%.status:*}
  [ "$task" != "$row" ] || return 1
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  line=${row#*.status: }
  line=${line% (catch-all scan)}
  verb=$(status_line_verb "$line")
  case "$verb" in needs-decision|blocked) ;; *) return 1 ;; esac
  key=$(_fm_decision_key "$line") || return 1
  if decision_current_record "$state" "$task" "$key"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 2 ] || return 2
  FM_BUFFERED_DECISION_TASK=$task
  FM_BUFFERED_DECISION_KEY=$key
  FM_BUFFERED_DECISION_ORIGIN=$FM_DECISION_CURRENT_ORIGIN
  FM_BUFFERED_DECISION_DISPLAY=$FM_DECISION_CURRENT_DISPLAY
  return 0
}

escalate_reconcile_decisions() {  # <state>
  local state=$1 buf tmp dedup row type task key origin display extra seen rc
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  tmp="$buf.reconcile.$$"
  dedup="$tmp.dedup"
  : > "$tmp" || return 1
  while IFS= read -r row || [ -n "$row" ]; do
    IFS=$(printf '\t') read -r type task key origin display extra <<EOF
$row
EOF
    if [ "$type" = decision ] && [ -n "$task" ] && [ -n "$key" ] \
      && [ -n "$origin" ] && [ -z "$extra" ]; then
      if decision_current_record "$state" "$task" "$key"; then rc=0; else rc=$?; fi
      [ "$rc" -ne 2 ] || { rm -f "$tmp" "$dedup"; return 1; }
      if [ "$rc" -eq 0 ]; then
        printf 'decision\t%s\t%s\t%s\t%s\n' \
          "$task" "$key" "$FM_DECISION_CURRENT_ORIGIN" "$FM_DECISION_CURRENT_DISPLAY" >> "$tmp"
        mark_decision_seen "$state" "$task" "$key" \
          "$FM_DECISION_CURRENT_FILE_IDENT" "$FM_DECISION_CURRENT_ORIGIN" \
          "$FM_DECISION_CURRENT_DISPLAY"
      else
        seen=$(decision_seen_path "$state" "$task" "$key")
        rm -f "$seen"
      fi
      continue
    fi
    if legacy_buffered_decision "$state" "$row"; then rc=0; else rc=$?; fi
    [ "$rc" -ne 2 ] || { rm -f "$tmp" "$dedup"; return 1; }
    if [ "$rc" -eq 0 ]; then
      if [ -n "$FM_BUFFERED_DECISION_DISPLAY" ]; then
        printf 'decision\t%s\t%s\t%s\t%s\n' \
          "$FM_BUFFERED_DECISION_TASK" "$FM_BUFFERED_DECISION_KEY" \
          "$FM_BUFFERED_DECISION_ORIGIN" "$FM_BUFFERED_DECISION_DISPLAY" >> "$tmp"
        mark_decision_seen "$state" "$FM_BUFFERED_DECISION_TASK" \
          "$FM_BUFFERED_DECISION_KEY" "$FM_DECISION_CURRENT_FILE_IDENT" \
          "$FM_BUFFERED_DECISION_ORIGIN" "$FM_BUFFERED_DECISION_DISPLAY"
      fi
      continue
    fi
    printf '%s\n' "$row" >> "$tmp"
  done < "$buf"
  awk '!seen[$0]++' "$tmp" > "$dedup" || { rm -f "$tmp" "$dedup"; return 1; }
  mv -f "$dedup" "$buf" || { rm -f "$tmp" "$dedup"; return 1; }
  rm -f "$tmp"
  [ -s "$buf" ] || rm -f "${buf}.since"
}

escalate_render() {  # <state>
  awk -F '\t' '
    NR > 1 { printf " | " }
    $1 == "decision" && NF == 5 { printf "%s", $5; next }
    { printf "%s", $0 }
    END { if (NR > 0) print "" }
  ' "$1/.subsuper-escalations"
}

escalate_render_nondecisions() {  # <state>
  awk -F '\t' '
    $1 == "decision" && NF == 5 { next }
    shown > 0 { printf " | " }
    { printf "%s", $0; shown++ }
    END { if (shown > 0) print "" }
  ' "$1/.subsuper-escalations"
}
