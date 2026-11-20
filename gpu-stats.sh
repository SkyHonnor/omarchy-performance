#!/bin/bash
# Read-only multi-GPU metrics collector for skyhonnor.performance.
# Outputs one TSV line per detected GPU:
#   vendor <TAB> busyPct <TAB> vramUsedMiB <TAB> vramTotalMiB <TAB> tempC <TAB> suspended <TAB> curFreqMHz <TAB> maxFreqMHz
# Unavailable numeric values are emitted as NA; suspended is 0 or 1.

shopt -s nullglob

read_int() {
  local val
  [[ -r $1 ]] || return 1
  val=$(<"$1") || return 1
  val="${val//[[:space:]]/}"
  [[ $val =~ ^-?[0-9]+$ ]] || return 1
  printf '%s' "$val"
}

read_hwmon_temp_c() {
  local dev="$1"
  local h t
  for h in "$dev"/hwmon/hwmon*; do
    if t=$(read_int "$h/temp1_input"); then
      printf '%d' $(( (t + 500) / 1000 ))
      return 0
    fi
  done
  return 1
}

declare -a awake_nvidia_pci=()
declare -a suspended_nvidia_pci=()

for card in /sys/class/drm/card[0-9]*; do
  name="${card##*/}"
  [[ $name =~ ^card[0-9]+$ ]] || continue
  dev="$card/device"
  [[ -d $dev && -r $dev/vendor ]] || continue

  vendor=$(<"$dev/vendor")
  vendor="${vendor,,}"
  vendor="${vendor//[[:space:]]/}"

  status="active"
  if [[ -r $dev/power/runtime_status ]]; then
    status=$(<"$dev/power/runtime_status")
    status="${status,,}"
    status="${status//[[:space:]]/}"
  fi

  case "$vendor" in
    0x1002)
      if [[ $status == "suspended" ]]; then
        printf 'AMD\tNA\tNA\tNA\tNA\t1\tNA\tNA\n'
        continue
      fi
      busy="NA"
      vram_used="NA"
      vram_total="NA"
      temp_c="NA"
      if val=$(read_int "$dev/gpu_busy_percent"); then busy="$val"; fi
      if val=$(read_int "$dev/mem_info_vram_used"); then vram_used=$(( val / 1048576 )); fi
      if val=$(read_int "$dev/mem_info_vram_total"); then vram_total=$(( val / 1048576 )); fi
      if val=$(read_hwmon_temp_c "$dev"); then temp_c="$val"; fi
      if [[ $busy != "NA" || $vram_total != "NA" || $temp_c != "NA" ]]; then
        printf 'AMD\t%s\t%s\t%s\t%s\t0\tNA\tNA\n' "$busy" "$vram_used" "$vram_total" "$temp_c"
      fi
      ;;

    0x10de)
      canonical_dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
      pci_id="${canonical_dev##*/}"
      if [[ $status == "suspended" ]]; then
        suspended_nvidia_pci+=("$pci_id")
      else
        awake_nvidia_pci+=("$pci_id")
      fi
      ;;

    0x8086)
      if [[ $status == "suspended" ]]; then
        printf 'Intel\tNA\tNA\tNA\tNA\t1\tNA\tNA\n'
        continue
      fi
      temp_c="NA"
      cur_freq="NA"
      max_freq="NA"
      if val=$(read_hwmon_temp_c "$dev"); then temp_c="$val"; fi
      if cur=$(read_int "$card/gt_cur_freq_mhz"); then cur_freq="$cur"; fi
      if max=$(read_int "$card/gt_max_freq_mhz"); then max_freq="$max"; fi
      if [[ $cur_freq == "NA" ]] && cur=$(read_int "$card/gt/gt0/rps_cur_freq_mhz"); then cur_freq="$cur"; fi
      if [[ $max_freq == "NA" ]] && max=$(read_int "$card/gt/gt0/rps_max_freq_mhz"); then max_freq="$max"; fi

      if [[ $cur_freq != "NA" || $temp_c != "NA" ]]; then
        printf 'Intel\tNA\tNA\tNA\t%s\t0\t%s\t%s\n' "$temp_c" "$cur_freq" "$max_freq"
      fi
      ;;
  esac
done

# Query only confirmed-awake NVIDIA GPUs by PCI bus ID (-i) so suspended dGPUs stay asleep.
if (( ${#awake_nvidia_pci[@]} > 0 )) && command -v nvidia-smi >/dev/null 2>&1; then
  for pci_id in "${awake_nvidia_pci[@]}"; do
    query_out="$(nvidia-smi -i "$pci_id" --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -n $query_out ]]; then
      while IFS=, read -r util mem_used mem_total temp; do
        util="${util//[[:space:]]/}"
        mem_used="${mem_used//[[:space:]]/}"
        mem_total="${mem_total//[[:space:]]/}"
        temp="${temp//[[:space:]]/}"
        [[ $util =~ ^[0-9]+$ ]] || util="NA"
        [[ $mem_used =~ ^[0-9]+$ ]] || mem_used="NA"
        [[ $mem_total =~ ^[0-9]+$ ]] || mem_total="NA"
        [[ $temp =~ ^[0-9]+$ ]] || temp="NA"
        printf 'NVIDIA\t%s\t%s\t%s\t%s\t0\tNA\tNA\n' "$util" "$mem_used" "$mem_total" "$temp"
      done <<< "$query_out"
    fi
  done
elif (( ${#awake_nvidia_pci[@]} > 0 )); then
  # Fallback for open nouveau driver when nvidia-smi is not installed
  for card in /sys/class/drm/card[0-9]*; do
    name="${card##*/}"
    [[ $name =~ ^card[0-9]+$ ]] || continue
    dev="$card/device"
    [[ -r $dev/vendor ]] || continue
    v=$(<"$dev/vendor")
    [[ ${v,,} == "0x10de" ]] || continue
    status="active"
    if [[ -r $dev/power/runtime_status ]]; then
      status=$(<"$dev/power/runtime_status")
      status="${status,,}"
      status="${status//[[:space:]]/}"
    fi
    [[ $status == "suspended" ]] && continue
    temp_c="NA"
    if val=$(read_hwmon_temp_c "$dev"); then temp_c="$val"; fi
    if [[ $temp_c != "NA" ]]; then
      printf 'NVIDIA\tNA\tNA\tNA\t%s\t0\tNA\tNA\n' "$temp_c"
    fi
  done
fi

for pci_id in "${suspended_nvidia_pci[@]}"; do
  printf 'NVIDIA\tNA\tNA\tNA\tNA\t1\tNA\tNA\n'
done
