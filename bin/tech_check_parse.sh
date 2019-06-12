# TODO: error checking, check for existance of files
# TODO: if we don't have modules.json
# TODO: module warnings/errors don't appear with --render-as json
# TODO: what is "Orphaned PostgreSQL Versions" supposed to do?
_messages_parse() {
  if [[ -e $1/logs/messages.gz ]]; then
    _messages_gz="$1/logs/messages.gz"
  elif [[ -e $1/logs/syslog.gz ]]; then
    _messages_gz="$1/logs/syslog.gz"
  elif [[ -e $1/logs/messages ]]; then
    _messages="$1/logs/messages"
  elif [[ -e $1/logs/syslog ]]; then
    _messages="$1/logs/syslog"
  elif [[ -e $1/var/log/messages.gz ]]; then
    _messages_gz="$1/var/log/messages.gz"
  elif [[ -e $1/var/log/syslog.gz ]]; then
    _messages_gz="$1/logs/syslog.gz"
  elif [[ -e $1/var/log/messages ]]; then
    _messages="$1/var/log/messages"
  elif [[ -e $1/var/log/syslog ]]; then
    _messages="$1/var/log/syslog"
  fi

  # Would be nice if zcat didn't care if the file were compressed or not, like zgrep
  # Be more like zgrep, zcat
  if [[ $_messages_gz ]]; then
    zcat "$_messages_gz" | awk 'BEGIN{IGNORECASE=1} $5 ~ "puppet" { err = substr($0, index($0, $6)); if (err ~ /(error|failure|severe|exception)/) print err }'
  elif [[ $_messages ]]; then
    awk 'BEGIN{IGNORECASE=1} $5 ~ "puppet" { err = substr($0, index($0, $6)); if (err ~ /(error|fail|severe|exception)/) print err }' "$_messages"
  else
    echo "No messages log found"
  fi | awk '{ sub(/\[.*\]/,""); !seen[$0]++ } END { for (s in seen) print seen[s]":", s }' | sort -rn | jq -nR '{syslog_errors: [inputs]}'
}

_logs_parse() {
  find "$1" -type f -name "*log" -exec grep -hs 'WARN' {} \+ | \
    awk '{gsub(/^.*WARN[[:alnum:]]*[:]*[[:space:]]*/,""); gsub(/^\[.*\][[:space:]]*/, ""); !seen[$0]++ } END { for (s in seen) print seen[s]":", s }' | sort -rn | jq -nR '{log_warnings: [inputs]}'

  find "$1" -type f -name "*log" -exec grep -hs 'ERROR' {} \+ | \
    awk '{gsub(/^.*ERROR[[:alnum:]]*[:]*[[:space:]]*/,""); gsub(/^\[.*\][[:space:]]*/, ""); !seen[$0]++ } END { for (s in seen) print seen[s]":", s }' | sort -rn | jq -nR '{log_errors: [inputs]}'

}

_v1_largest_dirs() {
  gunzip -c "$1" | awk '$3 ~ /^-/ { m = match($11, /\/[^/]*$/); sizes[substr($11,0,m)]+=$7 } END { for (s in sizes) print sizes[s]," ", s }' | sort -n -r -k 1 | head | numfmt --to=si
}

_v3_largest_dirs() {
  awk -v RS= '{ split($0, dirs, "\n"); d = substr(dirs[1], 1, length(dirs[1]) -1); for (i=3; i<length(dirs); i++) { n = split(dirs[i], fields, " ");  if (fields[n] != "." && fields[n] != "..") sizes[d] += fields[5]} } END { for (s in sizes) print sizes[s], s}' "$1" | sort -rn | head | numfmt --to=si
}

_df_parse() {
  sed -n 1p "$1"; sort -nrk 5 <(sed 1d "$1" )
}

v1_tech_check_parse() {
  tech_check_tmp="$(mktemp)"
  temp_files+=("$tech_check_tmp")

  exec 3>&1
  exec >"$tech_check_tmp"

  jq -n '{"Server Version": $server[].values.pe_server_version}' \
    --slurpfile server "$1/system/facter_output.json" || echo '{"pe_server_version": "error"}'
  jq -n '{"Infrastructure": [$infra[] | .[] | del(.status.metrics) | {display_name, server, state}]}' \
    --slurpfile infra "$1/enterprise/pe_infra_status.json" || echo '{"Infrastructure status": "error"}'
  jq -n '{"Active Nodes": $nodes[] | length}' \
    --slurpfile nodes "$1/enterprise/puppetdb_nodes.json" || echo '{"active_nodes": "error"}'
  jq -n '{"Modules": $modules[] | map(. + { "total_modules": .modules | length }) | map({name, total_modules})}' \
    --slurpfile modules "$1/enterprise/modules.json" || echo '{"module_count": "error"}'

  for f in "$1/enterprise/puppet_gems.txt" "$1/enterprise/puppetserver_gems.txt"; do
    if out="$(grep eyaml "$f")"; then
      echo "${f##*/}: $out"
    else
      echo "${f##*/}: missing eyaml gem"
    fi
  done | jq -nR '{"Heira Gems": [inputs]}'

  if zgrep -q '/opt/puppetlabs/puppet/cache/clientbucket' \
    "$1/enterprise/find/_opt_puppetlabs.txt.gz"; then
    echo '{"Filebucket": "yes"}'
  else echo '{"Filebucket": "no"}'
  fi | jq ''

  _v1_largest_dirs "$1/enterprise/find/_opt_puppetlabs.txt.gz" | jq -nR '{"Largest in /opt": [inputs]}'
  _v1_largest_dirs "$1/enterprise/find/_etc_puppetlabs.txt.gz" | jq -nR '{"Largest in /etc": [inputs]}'

  _df_parse "$1/resources/df_output.txt" | jq -nR '{"Disk Usage": [inputs]}'

  jq -nR '{"Memory Usage": [inputs]}' < "$1/resources/free_mem.txt"

  _logs_parse "$1/logs/"

  _messages_parse "$1"

  exec >&3
  jq -n '[inputs] | add' <"$tech_check_tmp"
}

# Pretty much the same thing...
v3_tech_check_parse() {

  tech_check_tmp="$(mktemp)"
  temp_files+=("$tech_check_tmp")

  exec 3>&1
  exec >"$tech_check_tmp"

  jq -n '{"Server Version": $server[].values.pe_server_version}' \
    --slurpfile server "$1/enterprise/puppet_facts.txt"
  jq -n '{"Infrastructure": [$infra[] | .[] | del(.status.metrics) | {display_name, server, state}]}' \
    --slurpfile infra "$1/enterprise/puppet_infra_status.json"
  jq -n '{"Active Nodes": $nodes[] | length}' \
    --slurpfile nodes "$1/enterprise/puppetdb_nodes.json"
  jq -n '{Modules: $modules[] | map(. + { "total_modules": .modules | length }) | map({name, total_modules})}' \
    --slurpfile modules "$1/enterprise/puppetserver_modules.json"

  for f in "$1/enterprise/puppet_gem_list.txt" "$1/enterprise/puppetserver_gem_list.txt"; do
    if out="$(grep eyaml "$f")"; then
      echo "${f##*/}: $out"
    else
      echo "${f##*/}: missing eyaml gem"
    fi
  done | jq -nR '{hiera_gems: [inputs]}'

  _v3_largest_dirs "$1/enterprise/list_opt_puppetlabs.txt" | jq -nR '{"Largest in /opt": [inputs]}'
  _v3_largest_dirs "$1/enterprise/list_etc_puppetlabs.txt" | jq -nR '{"Largest in /etc": [inputs]}'

  _df_parse "$1/resources/df_h_output.txt" | jq -nR '{"Disk Usage": [inputs]}'

  jq -nR '{"Memory Usage": [inputs]}' < "$1/resources/free_h.txt"

  _logs_parse "$1/var/log"

  _messages_parse "$1"

  exec >&3
  jq -n '[inputs] | add' <"$tech_check_tmp"
}