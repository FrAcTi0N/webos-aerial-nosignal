# webos-aerial-nosignal

Show a screensaver (for example [Aerial](https://repo.webosbrew.org/apps/org.aabytt.webos.custom-screensaver-aerial/)) on a **rooted LG webOS TV** instead of the "No Signal" message when an HDMI source goes to sleep.

- Starts the system screensaver when the chosen HDMI input has had no signal for ~30 s.
- **Any remote key** closes it and returns to the HDMI input. **Power** closes it and turns the TV off.
- Optionally wakes the source (Kodi, via its JSON-RPC API) so one key press is enough.
- Optionally turns the TV off (or runs any command) after the screensaver has been up for N minutes.
- Starts automatically after a reboot (Homebrew Channel `init.d`).

> **Status:** written and tested on one TV (HDMI 1 with Kodi on a Raspberry Pi, Czech Republic). Signal names, input device and key codes can differ between models and webOS versions, so the install steps below show how to discover them. Use at your own risk.

## How it works

webOS shows "No Signal" itself and offers no setting to replace it, and a screensaver launched over `luna-send` does not receive remote keys the way the TV's own idle screensaver does. This script is a small watcher that fills those gaps:

| Problem | How the script handles it |
| --- | --- |
| Detect "no signal" | Polls `luna://com.webos.service.videooutput/getStatus` every 10 s. For the input's block, `"videoInfo"` is `null` without a signal and an object with a signal. |
| Show the screensaver | Launches `com.webos.app.screensaver`. A custom screensaver app (Aerial) replaces that system slot once applied. |
| Leave it with any key | Reads raw events from `/dev/input/eventN` (the remote). A key press closes the screensaver and relaunches the HDMI input. Pointer movement is ignored. |
| Power key | Recognised by its key code, so it closes the screensaver and powers the TV off instead of waking the source. |
| Wake the source | The key press is eaten by the screensaver, so the source never gets it over CEC. The script calls Kodi's JSON-RPC (`Input.ExecuteAction`). |

## Requirements

- A rooted LG webOS TV with the [Homebrew Channel](https://www.webosbrew.org/) and SSH access (see [rootmy.tv](https://rootmy.tv/)).
- A custom screensaver such as [Aerial Screensaver](https://repo.webosbrew.org/apps/org.aabytt.webos.custom-screensaver-aerial/), applied in its own settings. Without it you get LG's stock screensaver.
- `luna-send`, `curl`, `od` and `dd` on the TV (all present on the TV this was developed on).
- Optional: Kodi with *Settings > Services > Control > Allow remote control via HTTP* enabled.

## Install, step by step

All commands run on the TV over SSH (`ssh root@<tv-ip>`), unless stated otherwise.

### 1. Install and apply a screensaver

Install Aerial Screensaver from the Homebrew Channel, open it, choose the video source and apply it. Check that the system screensaver now plays it:

```sh
luna-send -n 1 -f luna://com.webos.applicationManager/launch '{"id":"com.webos.app.screensaver"}'
```

If your Aerial app has its own id, `luna-send -n 1 -f luna://com.webos.applicationManager/dev/listApps '{}' | grep -i aerial` lists it. Launching *that* id only opens the settings app, so the script uses the system slot above.

### 2. Copy the files to the TV

From your computer:

```sh
scp aerial-nosignal.sh root@<tv-ip>:/home/root/
ssh root@<tv-ip> 'chmod +x /home/root/aerial-nosignal.sh'
```

### 3. Find your HDMI input id

Switch the TV to the input you use, then:

```sh
luna-send -n 1 -f luna://com.webos.applicationManager/getForegroundAppInfo '{}'
```

The `appId` (for example `com.webos.app.hdmi1`) goes into `HDMI_APP` in the script.

### 4. Check that signal detection works for you

With the source awake and showing a picture:

```sh
luna-send -n 1 -f luna://com.webos.service.videooutput/getStatus '{"subscribe":false}' | sed -n '/"appId": *"com.webos.app.hdmi1"/,/"extraInfo"/p'
```

You should see `"videoInfo": {` followed by fields. Put the source to sleep so the TV says "No Signal" and run it again: `"videoInfo": null`. If both outputs look the same, take two full snapshots and `diff` them to find a field that changes, then adapt `has_signal()`.

### 5. Find the remote's input device and the Power key code

```sh
ls /dev/input/
for f in /dev/input/event*; do ( head -c 1 "$f" >/dev/null 2>&1 && echo "REACTED: $f" ) & done; sleep 10; kill $(jobs -p) 2>/dev/null
```

Press buttons on the remote during the 10 seconds. Note the `eventN` that reacted and set `KEY_DEV`.

To find the Power code (the TV will turn off when you press it):

```sh
head -c 96 /dev/input/event3 | od -An -tx1
```

Press OK, then Power. Each event is 16 bytes: 8 bytes time, 2 bytes type, 2 bytes code (little-endian), 4 bytes value. In the example `01 00 1c 00 01 00 00 00` is key `0x1c` (OK) pressed and `01 00 af 04 01 00 00 00` is key `0x04af` pressed. Write the code bytes as `KEY_POWER="af 04"`.

### 6. Optional: Kodi wake-up

Enable the web server in Kodi (*Settings > Services > Control*) and test from the TV, as **one line**:

```sh
curl -i -m 5 -u kodi:PASSWORD -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"JSONRPC.Ping"}' http://192.168.1.50:8080/jsonrpc
```

`{"result":"pong"}` means it works. Put the URL and credentials in `KODI_URL` and `KODI_AUTH`. `KODI_WAKE_ACTION="noop"` woke the display on the test setup. If it does not wake yours, try another action. Leave `KODI_URL` empty to disable this.

### 7. Configure

Edit the block at the top of `aerial-nosignal.sh`:

| Variable | Meaning |
| --- | --- |
| `HDMI_APP` | App id of the watched input |
| `KEY_DEV`, `KEY_POWER` | Remote device and Power key code (step 5) |
| `AERIAL_MAX_MIN` | Minutes of screensaver before the end action runs (`0` = never) |
| `AERIAL_END_URI`, `AERIAL_END_PARAMS` | Luna call used as the end action (default: TV power off) |
| `AERIAL_END_CMD` | Any shell command, overrides the two lines above when not empty |
| `KODI_URL`, `KODI_AUTH`, `KODI_WAKE_ACTION` | Optional Kodi wake-up |
| `POLL`, `NEED` | Seconds between checks and how many consecutive misses trigger the screensaver |

Putting a password in the script is a trade-off. It stays on your TV, which is rooted and only reachable on your LAN, but use a Kodi account that only has the web-server permission.

### 8. Try it by hand

```sh
/home/root/aerial-nosignal.sh
```

Switch to the input and let the source go to "No Signal". After about 30 seconds the screensaver should start. Press a key: it closes and the source wakes. Stop with `Ctrl+C`. Events are logged to `/tmp/aerial.log`.

### 9. Start at boot

```sh
scp init.d/50-aerial-nosignal root@<tv-ip>:/var/lib/webosbrew/init.d/
ssh root@<tv-ip> 'chmod +x /var/lib/webosbrew/init.d/50-aerial-nosignal'
```

The launcher waits 60 s so the webOS services are up, then starts the watcher in the background. Reboot (`reboot`) and check after two minutes. Note that `ps` on webOS shows only command names, so use `ps -eo pid,args | grep aerial`.

With *Quick Start+* the TV only suspends when you turn it off, so the script keeps running and `init.d` runs on real boots only (power loss, firmware update, `reboot`).

## Troubleshooting

- **Nothing starts:** run `sh -x /home/root/aerial-nosignal.sh` and check that the foreground app is `HDMI_APP` while "No Signal" is shown.
- **The screensaver never ends on a key press:** check `KEY_DEV` and see `/tmp/aerial.log` for a "key pressed" line.
- **Kodi does not wake:** repeat the step 6 test while Kodi is asleep; try another `KODI_WAKE_ACTION`.
- **Copy/paste of multi-line `curl` fails:** use one line, no trailing backslashes.
- **`timeout` not found:** it is not installed on webOS; the examples avoid it.
- **TV turns itself off after hours:** that is webOS's own auto power off (usually 4 h in the EU). `AERIAL_MAX_MIN` lets you act sooner.

## Limitations

- Only one HDMI input is watched.
- Turning the TV off with something other than the remote (a phone app) is not detected, so the screensaver can keep running in the background.
- Signal detection and key codes were verified on one model only.

## Credits

- [Aerial Screensaver for webOS](https://github.com/aabytt/custom-screensaver-aerial) and the [webOS Brew](https://www.webosbrew.org/) community.
- LG, webOS and Kodi are trademarks of their owners. This project is not affiliated with them.

## License

MIT, see [LICENSE](LICENSE).
