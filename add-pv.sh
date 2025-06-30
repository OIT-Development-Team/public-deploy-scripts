#!/bin/sh
# Add PV claims to deploy-plan.json
set -e

# ------- selectable PVs ----------------------------------------------------
pvs=(actimages argos-nfs software-download-nfs software-engineering-download-nfs)

echo
echo "Select the persistent volumes to mount (comma-separated list):"
echo
for i in "${!pvs[@]}"; do
  printf "  %d. %s\n" $((i+1)) "${pvs[$i]}"
done
echo
read -rp "Your selection: " raw
raw=${raw//[[:space:]]/}
IFS=',' read -ra tokens <<< "$raw"

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
new_claims=()

base_path_used=$(grep -cq '"mountPath"[[:space:]]*:[[:space:]]*"/var/www/html/storage/app"' "$tmp" && echo 1 || echo 0)

for t in "${tokens[@]}"; do
  if [[ $t =~ ^[0-9]+$ ]]; then
    idx=$((t-1))
    [[ $idx -ge 0 && $idx -lt ${#pvs[@]} ]] || { echo "Index $t is out of range"; exit 1; }
    claim="${pvs[$idx]}"
  else
    claim="$t"
  fi

  # skip if already added or already present
  if printf '%s\n' "${new_claims[@]}" | grep -qx "$claim"; then continue; fi
  if printf '%s\n' $existing_claims | grep -qx "$claim"; then continue; fi

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

  new_claims+=("$claim|$mount_path")
done

[ "${#new_claims[@]}" -eq 0 ] && { echo "ℹ️  No new volumes to add."; rm "$tmp"; exit 0; }

# ------- inject volumes ----------------------------------------------------
awk -v new_claims="$(printf '%s\n' "${new_claims[@]}")" '
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
