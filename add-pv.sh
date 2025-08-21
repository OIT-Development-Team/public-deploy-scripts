#!/bin/sh
# Add PV claims to deploy-plan.json
set -e

echo
# ------- selectable PVs ----------------------------------------------------
pvs="actimages argos-nfs software-download-nfs software-engineering-download-nfs"


echo "Select the persistent volumes to mount (comma-separated list):"
echo
i=1
for pv in $pvs; do
  printf "  %d. %s\n" "$i" "$pv"
  eval "pv_$i=\"$pv\""
  i=$((i+1))
done
echo
printf "Your selection: "
read raw

# Remove all whitespace
raw=$(echo "$raw" | tr -d '[:space:]')

# Split input by comma into positional parameters
IFS=','; set -- $raw
# ------- ensure .server.volumes exists -------------------------------------
tmp=$(mktemp)
cp deploy-plan.json "$tmp"

if ! grep -q '"volumes"[[:space:]]*:' "$tmp"; then
  awk '
    BEGIN{done=0}
    /"server"[[:space:]]*:[[:space:]]*\{/ && !done{
      print; print "        \"volumes\": ["; print "        ],"; done=1; next}
    {print}' "$tmp" > "${tmp}.fixed" && mv "${tmp}.fixed" "$tmp"
fi

# ------- detect existing claims & preserve order ---------------------------
existing_claims=$(grep -o '"claim"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp" | sed -E 's/.*"([^"]+)"/\1/')
new_claims=""

base_path_used=$(grep -cq '"mountPath"[[:space:]]*:[[:space:]]*"/var/www/html/storage/app"' "$tmp" && echo 1 || echo 0)


for t; do
  if [ -z "$t" ]; then continue; fi
  case "$t" in
    *[!0-9]* ) claim="$t" ;; # non-numeric, treat as direct claim
    * )
      idx=$((t))
      if [ "$idx" -ge 1 ] && [ "$idx" -le 4 ]; then
        eval "claim=\$pv_$idx"
      else
        echo "Index $t is out of range"; exit 1
      fi
      ;;
  esac

  # skip if already added or already present
  found=0
  echo "$new_claims" | grep -q "^$claim|" && found=1
  echo "$existing_claims" | grep -qx "$claim" && found=1
  [ "$found" -eq 1 ] && continue

  if [ "$base_path_used" -eq 0 ]; then
    default_path="/var/www/html/storage/app"
  else
    default_path="/var/www/html/storage/$claim"
  fi

  echo
  echo "Enter mountPath for '$claim' (leave blank for default: $default_path)"
  echo -n ": "
  read mount_path
  if [ -z "$mount_path" ]; then
    mount_path="$default_path"
  fi

  [ "$mount_path" = "/var/www/html/storage/app" ] && base_path_used=1

  if [ -n "$new_claims" ]; then
    new_claims="$new_claims\n$claim|$mount_path"
  else
    new_claims="$claim|$mount_path"
  fi
done

[ "${#new_claims[@]}" -eq 0 ] && { echo "ℹ️  No new volumes to add."; rm "$tmp"; exit 0; }

# ------- inject volumes ----------------------------------------------------
awk -v new_claims="$(printf '%s' "$new_claims" | grep -v '^$')" '
  BEGIN {
    split(new_claims, add, "\n")
    inside=0
    inserted=0
    buf=""
  }

  /"volumes"[[:space:]]*:[[:space:]]*\[\s*\],?/ {
    print "        \"volumes\": ["
    for(i=1;i<=length(add);i++) {
      split(add[i], parts, "|")
      claim = parts[1]
      path = parts[2]
      printf "            {\"claim\": \"%s\", \"mountPath\": \"%s\"}", claim, path
      if(i < length(add)) print ","; else print ""
    }
    print "        ],"
    inserted=1
    next
  }

  /"volumes"[[:space:]]*:[[:space:]]*\[/ {
    inside = 1
    print
    next
  }

  inside {
    if ($0 ~ /\]/) {
      if (buf != "") {
        if (buf !~ /},[[:space:]]*$/) sub(/[[:space:]]*$/, ",", buf)
        print buf
      }
      for(i=1;i<=length(add);i++) {
        split(add[i], parts, "|")
        claim = parts[1]
        path = parts[2]
        printf "            {\"claim\": \"%s\", \"mountPath\": \"%s\"}", claim, path
        if(i < length(add)) print ","; else print ""
      }
      print $0
      inside = 0
      inserted = 1
      next
    }
    if (buf != "") print buf
    buf = $0
    next
  }

  {print}
' "$tmp" > deploy-plan.json

rm "$tmp"
echo "✅ Updated deploy-plan.json with new volume(s)."
