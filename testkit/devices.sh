#!/usr/bin/env bash
# Device registry for the Hop cross-system test harness.
# Each device: id | platform | handle (adb serial / devicectl udid) | transport | display name
#
# transport: "ble" = BLE-only (Wi-Fi OFF, set by the operator) ; "full" = BLE + LAN + Wi-Fi Direct.
# The operator keeps PIXEL and XR off Wi-Fi (BLE-only); the rest have full connectivity.
#
# Addresses are NOT here — they are discovered live into testkit/addrs.env by refresh-addrs.sh
# (Android: logcat "HOPAUTO self=" ; iOS: automation.json .self). Identity is device-seed-derived
# and STABLE across reinstalls/data-wipes, so the map is durable.

BUNDLE=net.waldrip.hop.demo

# id        platform  handle                                  transport  displayname
# The 4-device unattended fleet: BushidoPhone + Decklan's iPad left the network.
DEVICES=(
  "pixel   android   34241FDH2004KR                          ble        Pixel 7"
  "tab     android   R95YA01J6QZ                             full       Galaxy Tab A9+"
  "xr      ios       802500FE-27D7-502F-9D2C-9486D5CA74B2     ble        Test iPhone (XR)"
  "jpad    ios       DE7FC4B6-0573-5836-9D0F-73F597502C5C     full       Jillian's iPad"
)
# Devices that left the network (re-add for larger-mesh runs):
#   "bush   ios       0280AC9F-551E-55DA-A969-62D4242A003C     full       BushidoPhone"
#   "ipad   ios       FCFFD6B3-49D0-58E5-BF6B-D46EA444145A     full       Decklan's iPad"

# --- accessors: field <id> <col 2=platform 3=handle 4=transport 5=name> ---
dev_field() {
  local want="$1" col="$2" row
  for row in "${DEVICES[@]}"; do
    set -- $row
    if [ "$1" = "$want" ]; then
      case "$col" in
        platform) echo "$2";;
        handle)   echo "$3";;
        transport) echo "$4";;
        name)     shift 4; echo "$*";;
      esac
      return 0
    fi
  done
  return 1
}
dev_platform() { dev_field "$1" platform; }
dev_handle()   { dev_field "$1" handle; }
dev_transport(){ dev_field "$1" transport; }
dev_name()     { dev_field "$1" name; }
dev_ids()      { local row; for row in "${DEVICES[@]}"; do set -- $row; echo "$1"; done; }
