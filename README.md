<img width="500" height="500" alt="Screenshot 2026-09-16 at 22 30 34" src="https://github.com/user-attachments/assets/128918f6-b151-4a65-a923-3c5f34eae5cb" />

# Faraday

Turn the network completely off for one iOS Simulator while your Mac stays online.

Network Link Conditioner can only simulate 100 % packet loss, and it slows down your whole Mac. Faraday instead:

- blocks every connection of the simulator you mark offline, and only that simulator;
- can make `NWPathMonitor`, `nw_path_monitor` and `SCNetworkReachability` report "no network" and name lookups fail, like a real offline device;
- leaves your Mac's own traffic alone.

It's a menu bar app with a command-line tool, meant to sit next to Xcode's Device Hub.

## How it works

A simulator processes are ordinary Mac processes that share the Mac's network stack. Faraday therefore works on individual connections rather than packets.

| Part | What it does |
|---|---|
| **Filter** (system extension, `NEFilterDataProvider`) | Works out which simulator each new connection belongs to (from the process path, its `SIMULATOR_UDID`, or its `launchd_sim` parent) and drops connections of offline simulators. It runs whenever it's installed and enabled, so connections opened while a simulator was online are cut the moment it goes offline. |
| **App shim** (`FaradayShim.dylib`, optional) | Loaded into simulator apps. Makes `NWPath.status`, `NWPathMonitor` updates, `nw_path_*` and `SCNetworkReachability*` report offline, makes `getaddrinfo` and the other POSIX name lookups fail, and tells running observers immediately. |
| **`Faraday.app` and the `faraday` CLI** | Control both parts. They talk to the filter over XPC, and the filter only accepts apps signed by the same team. |

Offline simulators are reset when your Mac restarts.

## Requirements

macOS 15 or later. Tested with Xcode 27 on macOS 27 and iOS 26 simulators.

To build it yourself you also need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and a paid Apple Developer Program membership — macOS only allows Network Extensions from paid teams. The download below needs none of that.

## Install

Download the app from [the latest release](../../releases/latest), unzip it, drag **Faraday.app** to `/Applications` and open it. It's signed and notarized, so no Apple account, Xcode or developer settings are involved.

Then click the network icon in the menu bar, choose **Install Filter**, approve Faraday in **System Settings → General → Login Items & Extensions → Network Extensions**, and allow the filter configuration when macOS asks.

### Build it

To use Faraday, download the latest release.

```bash
Scripts/install-shim-only.sh          # builds the CLI and the shim into ~/.faraday
~/.faraday/faraday shim install       # load the shim into apps this simulator launches
~/.faraday/faraday --shim-only on     # apps see no network
~/.faraday/faraday --shim-only off
```

Apps then behave as if there were no network: `NWPathMonitor`, `nw_path_monitor` and `SCNetworkReachability` report offline and name lookups fail, which is enough to exercise most offline UI. Connections are not blocked, so code that ignores those APIs still reaches the network.

## Use

**Menu bar:** every booted simulator has an **Offline** switch. The options are:

- **Cut connections that are already open.** Connections opened before the filter was installed can't be cut.
- **Make reachability and DNS fail in apps too.** Loads the shim into apps the simulators launch from then on; relaunch apps that are already running.

**CLI:** `/Applications/Faraday.app/Contents/Helpers/faraday`. It talks to the filter directly, so Faraday.app doesn't have to be running.

```bash
faraday list
faraday on                      # the booted simulator; or pass a UDID or device name
faraday off "iPhone 17 Pro"
faraday all-online
faraday shim install            # app shim for apps this simulator launches from now on
faraday shim env                # DYLD_INSERT_LIBRARIES=… to load the shim into one app via its Xcode scheme
faraday status --json
```

Exit codes: `0` success, `1` usage error, `2` filter unavailable, `3` simulator problem, `4` shim library missing.

## Limitations

- **Open connections:** connections opened before the filter was installed can't be cut.
- **DNS without the shim:** the simulator uses the Mac's resolver, so answers it already has cached can still come back while offline. Connections still fail.
- **DNS after going offline:** lookups an offline simulator starts are dropped mid-flight, and for a minute or so afterwards the Mac's resolver can be slow to answer those same names, for your Mac and other simulators too. It clears by itself. With the shim, lookups fail inside the app and never reach the resolver, so this doesn't happen.
- **Loopback:** `127.0.0.1` and `localhost` always work, which keeps local mock servers and debugging usable. The shim leaves lookups of `localhost` and numeric addresses alone for the same reason.
- **Without the shim**, reachability APIs keep reporting a connection even though every connection fails.
- **The shim** fails name lookups made through `getaddrinfo`, `gethostbyname`, `gethostbyname2` and `getipnodebyname`, not through `getaddrinfo_async_start` or the DNSService APIs; it doesn't push updates to Swift `NWPathMonitor` used as an `AsyncSequence` (`for await path in monitor`), and doesn't change `usesInterfaceType` or `availableInterfaces`.
- **Other content filters** and corporate device management may conflict with or block the extension.

## Uninstall

1. Menu bar → **All Online**, so no simulator is left offline.
2. Menu bar → **More** → **Uninstall Filter**.
3. Delete `/Applications/Faraday.app` and `~/Library/Application Support/Faraday`.

Simulators forget the shim when they shut down; `faraday shim uninstall <udid>` removes it from a running one.

## License

MIT. See [LICENSE](LICENSE).
