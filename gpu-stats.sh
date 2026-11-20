#!/bin/bash
# Read-only multi-GPU metrics collector for skyhonnor.performance.
# Outputs one TSV line per detected GPU:
#   vendor <TAB> busyPct <TAB> vramUsedMiB <TAB> vramTotalMiB <TAB> tempC <TAB> suspended
# Unknown numeric values are emitted as -1; suspended is 0 or 1.

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

active_nvidia=0
suspended_nvidia=0

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
    status="${status//[[:space:]]/}"
  fi

  case "$vendor" in
    0x1002)
      if [[ $status == "suspended" ]]; then
        printf 'AMD\t-1\t-1\t-1\t-1\t1\n'
        continue
      fi
      busy=-1
      vram_used=-1
      vram_total=-1
      temp_c=-1
      if val=$(read_int "$dev/gpu_busy_percent"); then busy="$val"; fi
      if val=$(read_int "$dev/mem_info_vram_used"); then vram_used=$(( val / 1048576 )); fi
      if val=$(read_int "$dev/mem_info_vram_total"); then vram_total=$(( val / 1048576 )); fi
      if val=$(read_hwmon_temp_c "$dev"); then temp_c="$val"; fi
      if (( busy >= 0 || vram_total > 0 || temp_c >= 0 )); then
        printf 'AMD\t%d\t%d\t%d\t%d\t0\n' "$busy" "$vram_used" "$vram_total" "$temp_c"
      fi
      ;;

    0x10de)
      if [[ $status == "suspended" ]]; then
        suspended_nvidia=$(( suspended_nvidia + 1 ))
      else
        active_nvidia=$(( active_nvidia + 1 ))
      fi
      ;;

    0x8086)
      if [[ $status == "suspended" ]]; then
        printf 'Intel\t-1\t-1\t-1\t-1\t1\n'
        continue
      fi
      busy=-1
      temp_c=-1
      if val=$(read_hwmon_temp_c "$dev"); then temp_c="$val"; fi
      if cur=$(read_int "$card/gt_cur_freq_mhz") && max=$(read_int "$card/gt_max_freq_mhz") && (( max > 0 )); then
        busy=$(( cur * 100 / max ))
        (( busy > 100 )) && busy=100
      elif cur=$(read_int "$card/gt/gt0/rps_cur_freq_mhz") && max=$(read_int "$card/gt/gt0/rps_max_freq_mhz") && (( max > 0 )); then
        busy=$(( cur * 100 / max ))
        (( busy > 100 )) && busy=100
      fi
      if (( busy >= 0 || temp_c >= 0 )); then
        printf 'Intel\t%d\t-1\t-1\t%d\t0\n' "$busy" "$temp_c"
      fi
      ;;
  esac
done

# Query NVIDIA GPUs via nvidia-smi only when at least one is awake (avoids waking D3cold dGPUs).
if (( active_nvidia > 0 )) && command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=, read -r util mem_used mem_total temp; do
    util="${util//[[:space:]]/}"
    mem_used="${mem_used//[[:space:]]/}"
    mem_total="${mem_total//[[:space:]]/}"
    temp="${temp//[[:space:]]/}"
    [[ $util =~ ^[0-9]+$ ]] || util=-1
    [[ $mem_used =~ ^[0-9]+$ ]] || mem_used=-1
    [[ $mem_total =~ ^[0-9]+$ ]] || mem_total=-1
    [[ $temp =~ ^-?[0-9]+$ ]] || temp=-1
    printf 'NVIDIA\t%s\t%s\t%s\t%s\t0\n' "$util" "$mem_used" "$mem_total" "$temp"
  done < <(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
else
  # Fallback: report sleeping NVIDIA dGPUs (or active ones via nouveau hwmon if no nvidia-smi)
  for (( i = 0; i < suspended_nvidia; i++ )); do
    printf 'NVIDIA\t-1\t-1\t-1\t-1\t1\n'
  done
  if (( active_nvidia > 0 )); then
    for card in /sys/class/drm/card[0-9]*; do
      name="${card##*/}"
      [[ $name =~ ^card[0-9]+$ ]] || continue
      dev="$card/device"
      [[ -r $dev/vendor ]] || continue
      v=$(<"$dev/vendor")
      [[ ${v,,} == "0x10de" ]] || continue
      temp_c=-1
      if val=$(read_hwmon_temp_c "$dev"); then temp_c="$val"; fi
      if (( temp_c >= 0 )); then
        printf 'NVIDIA\t-1\t-1\t-1\t%d\t0\n' "$temp_c"
      fi
    done
  fi
fi
