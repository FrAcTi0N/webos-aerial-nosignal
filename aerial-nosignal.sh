#!/bin/sh
# aerial-nosignal.sh - start the LG webOS screensaver (e.g. Aerial) when an HDMI input has no signal,
# close it with any remote key, turn the TV off with the Power key, optionally wake Kodi.
# Runs on a rooted LG webOS TV (BusyBox sh, luna-send available). See README.md.

# ---- CONFIG: fill these in after the discovery steps ----
AERIAL_APP="com.webos.app.screensaver"                    # system screensaver slot (aerial replaces it once applied in its settings)
HDMI_APP="com.webos.app.hdmi1"                            # input you normally use
HDMI_EIM_ID="HDMI_1"                                      # id of that input in getAllInputStatus
KEY_DEV="/dev/input/event3"                               # input device that reacts to the remote
KEY_GRACE=3                                               # seconds after launch to ignore key events
KEY_POWER="af 04"                                         # key code of the Power button (little-endian hex bytes, from /dev/input/event3)
KEYFLAG="/tmp/aerial.key"
AERIAL_MAX_MIN=60                                         # minutes of aerial before AERIAL_END_* runs (0 = never)
# What to do when the time is up: a luna service URI + JSON parameters ...
AERIAL_END_URI="luna://com.webos.service.tvpower/power/powerOff"
AERIAL_END_PARAMS='{"reason":"localKey"}'
# ... or any shell command instead (overrides the two lines above when not empty), e.g.
# AERIAL_END_CMD='luna-send -n 1 -f luna://com.webos.service.tvpower/power/turnOffScreen "{}"'
AERIAL_END_CMD=""
KODI_URL=""                                               # e.g. http://192.168.1.50:8080/jsonrpc (empty = do not wake Kodi)
KODI_AUTH="kodi:PASSWORD"                                  # user:password of the Kodi web server
KODI_WAKE_ACTION="noop"                                   # Kodi action used to wake the display
POLL=10                                                   # seconds between checks
NEED=3                                                    # consecutive no-signal polls before launching
# ----------------------------------------------------------

lsend() { luna-send -n 1 -f "$1" "$2" 2>/dev/null; }

fg_app() {
  lsend luna://com.webos.applicationManager/getForegroundAppInfo '{}' \
    | sed -n 's/.*"appId"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -n1
}

# Returns 0 if the input has a live source. ADJUST after testing (see notes).
has_signal() {
  # eim "activate"/"hdmiPlugIn" are unreliable. In videooutput, the block of the input has
  # "videoInfo": null (and width/frameRate 0) without a signal, and an object with a signal.
  lsend luna://com.webos.service.videooutput/getStatus '{"subscribe":false}' \
    | sed -n "/\"appId\": *\"$HDMI_APP\"/,/\"extraInfo\"/p" \
    | grep -q '"videoInfo": *{'
}

launch() { lsend luna://com.webos.applicationManager/launch "{\"id\":\"$1\"}" >/dev/null; }
close_app() { lsend luna://com.webos.applicationManager/closeByAppId "{\"id\":\"$1\"}" >/dev/null; }
log() { echo "$(date +%T) $*" >> /tmp/aerial.log; }

aerial_end() {
  if [ -n "$AERIAL_END_CMD" ]; then eval "$AERIAL_END_CMD" >/dev/null 2>&1
  else lsend "$AERIAL_END_URI" "$AERIAL_END_PARAMS" >/dev/null; fi
}
screen_on()  { lsend luna://com.webos.service.tvpower/power/turnOnScreen '{}' >/dev/null; }

# Wake Kodi (the key press was consumed by the screensaver, so Kodi never saw it via CEC).
wake_kodi() {
  [ -n "$KODI_URL" ] || return 0
  curl -s -m 3 -u "$KODI_AUTH" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Input.ExecuteAction\",\"params\":{\"action\":\"$KODI_WAKE_ACTION\"}}" \
    "$KODI_URL" >/dev/null 2>&1
}

tv_off() { lsend luna://com.webos.service.tvpower/power/powerOff '{"reason":"localKey"}' >/dev/null; }

# Args: the 16 hex bytes of one input_event (time 8, type 2, code 2, value 4).
# Prints "power" or "key" for a key press (type 1, value 1), "none" for anything else.
classify_event() {
  if [ "$#" -lt 16 ] || [ "$9" != "01" ] || [ "${10}" != "00" ] || [ "${13}" != "01" ]; then
    echo none; return
  fi
  if [ "${11} ${12}" = "$KEY_POWER" ]; then echo power; else echo key; fi
}

# Blocks until a key press; prints "power" or "key". Fails if the device cannot be read.
wait_key() {
  while true; do
    ev=$(dd if="$KEY_DEV" bs=16 count=1 2>/dev/null | od -An -tx1)
    [ -n "$ev" ] || return 1
    k=$(classify_event $ev)
    [ "$k" != none ] && { echo "$k"; return 0; }
  done
}

# Wait for a key press: Power turns the TV off, any other key closes the screensaver.
start_keywatch() {
  rm -f "$KEYFLAG"
  (
    sleep "$KEY_GRACE"
    k=$(wait_key) || exit 0
    if [ "$k" = power ]; then
      log "power key, closing screensaver and turning TV off"
      close_app "$AERIAL_APP"; tv_off
    else
      log "key pressed, closing screensaver"
      screen_on
      close_app "$AERIAL_APP"; sleep 1; launch "$HDMI_APP"
      wake_kodi
    fi
    touch "$KEYFLAG"
  ) &
  KW_PID=$!
}
stop_keywatch() {
  [ -n "$KW_PID" ] && kill "$KW_PID" 2>/dev/null
  pkill -f "dd if=$KEY_DEV" 2>/dev/null
  KW_PID=""
}

miss=0
aerial_on=0
while true; do
  fg=$(fg_app)
  if [ "$aerial_on" = 0 ]; then
    if [ "$fg" = "$HDMI_APP" ]; then
      if has_signal; then miss=0; else miss=$((miss+1)); fi
      if [ "$miss" -ge "$NEED" ]; then
        launch "$AERIAL_APP"; aerial_on=1; miss=0; start_keywatch
        aerial_start=$(date +%s); screen_off_done=0
      fi
    else
      miss=0
    fi
  else
    # aerial running (the screensaver is not reported as foreground app, so only watch the signal)
    if [ -f "$KEYFLAG" ]; then
      rm -f "$KEYFLAG"; aerial_on=0; miss=-3   # re-arm after ~1 minute without signal
      sleep "$POLL"; continue
    fi
    if [ "$AERIAL_MAX_MIN" -gt 0 ] && [ "$screen_off_done" = 0 ] \
       && [ $(( $(date +%s) - aerial_start )) -ge $(( AERIAL_MAX_MIN * 60 )) ]; then
      log "aerial ran $AERIAL_MAX_MIN min, running end action"
      aerial_end; screen_off_done=1
    fi
    case "$fg" in
      com.webos.app.home|com.webos.app.screensaver|"$HDMI_APP")
        if has_signal; then
          log "signal back (fg=$fg), closing screensaver and switching to $HDMI_APP"
          stop_keywatch
          screen_on
          close_app "$AERIAL_APP"; sleep 1; launch "$HDMI_APP"; aerial_on=0
        fi ;;
      *)
        log "aerial_on but fg=$fg, giving up control"
        stop_keywatch
        aerial_on=0 ;;   # user opened some other app, stop interfering
    esac
  fi
  sleep "$POLL"
done
