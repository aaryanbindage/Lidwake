# LidWake

Keeps a MacBook running **with the lid closed and no external monitor**. It ends when the first of your chosen events happens: Claude finishes, the battery gets low, a process exits, a timer runs out, and so on. You can change a running session from the terminal, the menu bar, or **your phone**.

## How it works

macOS always sleeps when you close the lid unless an external display is connected. `caffeinate` can't stop that. Only `pmset -a disablesleep 1` can, and it needs root. The installer adds a sudoers rule that lets LidWake run exactly that command (plus `disablesleep 0` and `shutdown -h now`) without a password. When the event happens, LidWake turns normal sleep back on and then sleeps, shuts down, or does nothing.

What gets installed:

| Part | What it is |
|---|---|
| `lidwake` | The engine and CLI (bash). The session re-reads its event list every 5 s, so you can add or remove events while it runs. |
| `lidwaked` | Remote control server (Swift, LaunchAgent). Serves the web page and a token-protected API, connects to the relay or tunnel, and ends the session if the Mac gets critically hot. |
| `relay/` | End-to-end encrypted relay (Node) for a permanent link, plus optional accounts (Postgres). Deploy it to Render. |
| `LidWake.app` | Menu bar app: start, add or remove events, and a QR code for your phone. |
| `com.lidwake.recover` | Runs at login. Turns sleep back on if a session ever crashed. |

## Install (on the Mac)

```bash
cd LidWake
bash install.sh                 # REMOTE=0 bash install.sh to skip the web server
lidwake claude-hook --install   # optional: lets --claude work
```
The server and the app need `swiftc`; run `xcode-select --install` first if you don't have it. To remove everything, run `bash uninstall.sh`.

## Use

```bash
lidwake start --claude -b                       # until Claude Code finishes its reply
lidwake start --process ffmpeg --then shutdown  # until ffmpeg exits, then shut down
lidwake status                                  # events with their IDs
lidwake add --for 1h                            # add an event to the running session
lidwake extend 7 30m                            # push timer #7 back
lidwake remove 3                                # drop event #3
lidwake set then none                           # change what happens at the end
lidwake end                                     # end now and run the "then" action
lidwake stop                                    # end now, just allow sleep
```

Events: `--claude`, `--pid`, `--process`, `--for`, `--at`, `--file`, `--cmd`, `--signal`, `--unplug`, `--battery N`.

### Pipe any command into it

```bash
make build | lidwake                         # awake until the build finishes
./train.sh 2>&1 | lidwake --then shutdown    # include stderr, then shut down
rsync -a src/ dst/ | lidwake --battery 20    # any start options work
```
The event is the piped command finishing (its output closing). The output still shows in your terminal. If a session is already running, the pipe is added to it as one more event. Ctrl-C stops the session, or, if the session was already running before the pipe, just removes the pipe's event.

Safety limits that are added automatically (you can remove them):
- **battery ≤ 10%**
- a **12h limit**, unless you set `--for` or `--at`

## Remote control: any device, anywhere

```bash
lidwake remote        # prints the internet link and the local-network link
```
Open the link in any browser (phone, laptop, tablet, a work PC), on any network, or scan the QR code in the menu bar app. On phones the page is one column; on wider screens it has two. The Mac only makes outgoing connections, so you don't need to forward any router ports.

How the Mac is reachable from the internet (switch any time with `lidwake remote --public MODE`):

| Mode | Setup | Address |
|---|---|---|
| `relay` (default) | None. The installer uses the hosted relay at `https://lidwake-relay.onrender.com`; to run your own, see below. | `https://lidwake-relay.onrender.com/#d=…&k=…`: **permanent** and **end-to-end encrypted**. |
| `cloudflare` | None; the installer adds `cloudflared` | `https://<random>.trycloudflare.com`. It **changes when the Mac restarts**: run `lidwake remote` again, or set up `NTFY_URL` (below) to get the new address as a push notification. |
| `tailscale` | Install [Tailscale](https://tailscale.com/download/mac) on the Mac and sign in. The device you open the page from needs nothing. | `https://<mac>.<tailnet>.ts.net`, **permanent**, so you can bookmark it. The first time, Tailscale may print a link to approve Funnel. |
| `off` | | Local network only: `http://<mac-ip>:7878` |

### Accounts (optional)

On the relay page you can **create an account** (an email and a password; nothing is ever emailed). Each Mac you open while signed in is saved to it. After that, signing in on any phone, laptop or work PC takes you straight to your Mac, with no link to copy. If you have several Macs, a picker appears at the top.

The installer opens the page on the Mac at the end. Sign in there and that Mac is added. Later, `lidwake remote --open` does the same.

Accounts keep the end-to-end encryption:
- Your password never leaves the browser. It's stretched with PBKDF2-SHA256 (600,000 rounds) and split into two keys. The **auth key** is sent to sign you in, and the relay stores only a scrypt hash of it. The **vault key** never leaves the browser and encrypts each saved Mac's link.
- So the database holds only hashes and ciphertext. Neither the server nor anyone who steals the database can reach your Macs without cracking your password.
- That also means **a forgotten password can't be reset**. Make a new account and open each Mac's link again; the Macs themselves keep working.
- Wrong passwords are rate-limited (10 per IP and 20 per account per 15 minutes). Sessions last 90 days. **Account → Delete account** removes everything.
- Links still work without an account.

From the page you can:
- see the battery level and time left
- add events (Claude, timer, clock time, process, PID, file, charger, battery, safety limit, signal)
- use **+30m** on timers and remove events
- change what happens at the end
- **Stop** or **End now**
- start a new session when none is running

### Run your own relay (optional)

The installer uses the hosted relay by default. Because of the encryption, that relay can't read or change your commands, so running your own isn't needed for security. Do it if you want to stay independent of the hosted one.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/aaryanbindage/Lidwake)

1. Click the button, or in Render go to **New → Blueprint** and pick this repo. It uses `render.yaml`: a free Node web service called `lidwake-relay` and a free Postgres database `lidwake-db` for accounts, which is reachable only from the service.
   - Render's free Postgres **expires 30 days after it's created**. Upgrade it to a paid plan in the Render dashboard to keep accounts, or set `DATABASE_URL` to any other Postgres (Neon, Supabase, …).
   - Without a database, the relay still works; the page just doesn't offer accounts. Self-hosting with a persistent disk can use `ACCOUNTS_FILE=/path/accounts.json` instead of Postgres.
2. Copy the service URL Render gives you, e.g. `https://lidwake-relay.onrender.com`.
3. On each Mac, run `lidwake remote --public relay https://lidwake-relay.onrender.com`. Or install with `RELAY_URL=… bash install.sh`.
4. To make your relay the default for everyone who installs from your copy of the repo, put its URL in `DEFAULT_RELAY_URL` near the top of `lidwake`.

One relay serves any number of Macs. Each Mac gets its own random device ID and key.

How the relay is secured:
- **Mac connects out.** The Mac makes an outgoing, long-polling HTTPS connection to the relay, so it never accepts inbound connections. It proves which device it is with a 256-bit secret; its device ID is derived from that secret.
- **End-to-end encryption.** Every request and reply is encrypted with **AES-256-GCM**. The key exists only on the Mac and in the link after `#`, and browsers never send that part to any server. The relay only sees device IDs and ciphertext, so it can't read, forge, or change commands. A hijacked or malicious relay could at worst drop messages.
- **No replays.** Requests carry a timestamp and a single-use nonce, and replies echo the nonce. A captured request can't be replayed, and a reply can't be swapped onto a different request.
- **Nothing readable stored.** The relay logs no traffic. Its database holds only account data, as hashes and ciphertext (see Accounts above).
- **Free tier note.** Render's free tier sleeps when idle. A Mac's long-poll keeps it awake while LidWake is running; if it does fall asleep, the first request takes about a minute to wake it.
- **Leaked link.** Run `lidwake remote --new-token`. That rotates the key, and old links stop working.

Security (direct and tunnel modes):
- Every API call needs the 128-bit token in the link. If a link leaks, run `lidwake remote --new-token`.
- After 20 wrong tokens in a minute, the API is locked for a minute.
- The token sits after `#` in the link, so browsers never send it in requests or logs. The page keeps it in that browser's storage.
- `--cmd` events are refused over the network, so the token can't be used to run arbitrary commands.
- Internet traffic is HTTPS (through the tunnel). The local-network link is plain HTTP.
- With `cloudflare`, a new address is a new site to the browser, so it asks for the token again. Open the full link from `lidwake remote`, or paste the token in.
- Change the port with `REMOTE_PORT=8080` in `~/Library/Application Support/LidWake/config`.
- If macOS asks whether `lidwaked` may accept incoming connections, click Allow.

### Phone notifications when it ends

Add `NTFY_URL=https://ntfy.sh/<some-random-topic>` to the config file and subscribe to that topic in the [ntfy](https://ntfy.sh) app. You'll get a push notification when the session ends and why. This is useful because once the Mac sleeps, the web page can't tell you.

## Claude Code

`lidwake claude-hook --install` adds a `Stop` hook to `~/.claude/settings.json` (it backs up the file first). The hook runs `lidwake signal claude`, and does nothing if no session is running.
- **Any** Claude Code session finishing ends the LidWake session.
- If Claude is waiting on a permission prompt, it hasn't finished. LidWake stays awake until the battery or safety limit, so use auto mode for runs where you're away, or keep an eye on it from the remote page.

## Caveats

- A closed MacBook runs warmer. Don't put it in a bag while a session is running. (`lidwaked` ends the session if the Mac's thermal state becomes critical.)
- When the session ends with sleep or shutdown, the web page loses its connection. That's expected.
- Logs are in `~/Library/Application Support/LidWake/` (`lidwake.log`, `com.lidwake.remote.log`).
