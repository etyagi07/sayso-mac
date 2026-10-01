# Sayso for Mac: user guide

Sayso sits in a small panel beside your chart. You **speak** an order, Sayso
shows the exact contract and reads it back, and **nothing is sent until you
press `y`**. Every order is real money: there is no paper or practice mode.
To learn it, start with a 1-share order.

## What you need

- A Mac with Apple Silicon (M1 or later), running macOS 14 or later.
- About 2 GB of free space. The speech model downloads on first use (about
  0.5 GB).
- A Shoonya (Finvasia) account with API access. Options need the F&O
  segments: NFO for Nifty and Bank Nifty, BFO for Sensex.
- A microphone. The built-in one works, and a headset works better in a noisy
  room.

## Install

1. Drag **Sayso** into your **Applications** folder.
2. Open it. The first time, macOS asks you to confirm opening an app
   downloaded from the internet: click **Open**.
3. The first launch installs Sayso's engine. That takes a few seconds, and
   it needs the internet once: it downloads Shoonya's own connector from
   Shoonya's publisher, then the speech model (about 0.5 GB) the first time
   you speak. You can keep working meanwhile.

## One-time set-up

### 1. Shoonya's API key page

On Shoonya's API key page, note your **Client ID** (it ends in `_U`) and the
**secret code**. Then set two things:

- **Redirect URL:** exactly `http://127.0.0.1:8787/`. The login can't finish
  without it; the browser would wait forever.
- **Primary and Backup IP:** your internet addresses. Shoonya refuses logins
  and orders from any other address. Setup & health shows **this Mac's
  address**, so you can copy it. If it changes (a new Wi-Fi, a phone
  hotspot), Sayso shows **Wrong IP** on the panel.

### 2. First launch

Open Sayso. The panel appears at the edge of your screen.

1. A one-time notice reminds you that every order is real money and that
   Sayso isn't investment advice. Click **I understand**.
2. **Setup & health** opens by itself. Work down the list:

| Row | What to do |
|---|---|
| **Speech model** | It loads by itself. If it says "Couldn't load", click **Retry**. |
| **Microphone** | Click **Set up**. macOS asks for microphone access first. Then there are 3 seconds of silence, and then 5 seconds of repeating a phrase. |
| **Registered IP** | If it isn't green, type the IP from the API key page and click **Save**. |
| **Shoonya** | Click **Connect**. Enter the Client ID, your User ID and the secret code. Your browser opens Shoonya's login; finish it there. |
| **Account** | Market data and your F&O segments. A missing segment only limits what you can trade, and the row says which. |
| **Talk key** | The key you press to talk. See "If ⌃⌥Space does nothing" below. |
| **Your limits** | Your daily limits. **Change** to set your own (see Limits). |

When everything is green, it says **All set**. The checklist is always one
click away: click the coloured dot on the panel.

The secret code is used for one login and never saved; the IDs are
remembered. Shoonya logins last one trading day, so you **Connect** again
each morning.

## Your first order

Start small: **one share of Yes Bank** costs about ₹22.

1. Press **⌃⌥Space** (Control + Option + Space) and say "buy one yes bank
   intraday".
2. Check the card, then press `y`.
3. The panel shows **Bought 1 @ 22.45**. Sell it the same way ("sell my yes
   bank"). It's real, but tiny.

## Placing an order

1. Press **⌃⌥Space** (Control + Option + Space) and speak. Stop talking to
   finish: a pause of about a second ends the command. While you speak, the
   panel shows a level meter. You can also **double-click the pill** and type
   the command instead.
2. The **card** appears. It shows:
   - the side, on a solid tile: blue **BUY**, orange **SELL**, **EXIT**;
   - the strike, and CALL or PUT;
   - the index and expiry;
   - the lots and quantity, the price, and the total.

   Sayso reads the order back.
3. **Check it, then:**
   - **`y`** sends. It lights up once the card has been on screen long enough
     to read.
   - **`p`** types your own limit price.
   - **`esc`** cancels.

   If you do nothing, the bar runs out and the order is **cancelled**. A
   timeout never sends.
4. The panel shows **Sending**, and then the result, with the contract:
   **Bought 65 @ 72.35**, **Rejected**, **Resting @ 72.70**, or **Part
   filled 30/65**. A resting order stays on the panel ("1 resting") while
   Sayso follows it, for up to 5 minutes. It tells you when the order fills.
   After that, check it in Shoonya's app; resting orders are cancelled
   there, not by voice.

**What you'll hear:**

| Sound | Meaning |
|---|---|
| A bright chime | Filled |
| A soft tick | Placed, waiting to fill |
| A low tone | Rejected |
| An alarm | The order **may be live**: check your order book |
| A pop | Anything else: listen to the words |

Sayso reads every order back when the card opens. A speaker mark shows
while it's speaking, and pressing the talk key cuts it short.

Things you can say:

```
buy nifty call                         buy sensex put
buy bank nifty call fifty five six hundred
buy 2 lots of sensex call seventy four thousand
exit call                              exit the 23100 call
buy 10 reliance intraday               sell my reliance
what is the nifty call at              funds          what do I own
```

If Sayso isn't sure, it asks: "Which index?". Answer by voice, or press
`1`–`3` for the choices shown. If it still can't work out an order, it says
so and **nothing is sent**.

### When a card looks different

- An **amber band** across the top means look twice. It names the reason:
  - a large order;
  - several lots;
  - closing a position;
  - your own price;
  - a strike that isn't listed (Sayso uses the nearest and says "Not 23075");
  - an expiry that is today.

### "ORDER MAY BE LIVE"

A **red** panel means Sayso sent an order but can't confirm what happened. The
usual cause is a dropped connection. It names the order.

1. Click **Check orders** to look it up in today's order book, or check in
   Shoonya's own app.
2. Don't place it again until you know.
3. Hold **hold to clear** to dismiss the panel.

## Your account at a glance

- **List button, or right-click → Positions / Today's orders / Funds.**
  Orders placed by voice have a small waveform mark.
- **The pill** shows:
  - **LIVE**, and your account ID;
  - a moon when the market is closed;
  - **Wrong IP** when the IP check fails;
  - how many orders are resting.
- **Several accounts:** right-click → **Account** to switch, or
  **New account…** to add one. Sayso restarts its engine for that account,
  and you log in to it.

## Limits

Every account starts with these daily limits:

| Limit | Default |
|---|---|
| Per stock order | ₹15,000 |
| Stocks a day | ₹50,000 |
| Stock orders a day | 20 |
| Shares per order | 1,000 |
| Option orders a day | 10 |
| Lots per option order | Nifty 10, Bank Nifty 3, Sensex 10 |

They are your own to change: right-click → **Your limits…**, or **Change**
in Setup & health.
- Lowering a limit applies at once.
- **Raising one asks "Are you sure?"**, and nothing changes unless you say
  yes.
- **Defaults** puts them back.

An order over a limit is refused, and nothing is sent.

They exist to catch a mishearing ("twenty lots" heard for "two"). They are
not a view on how much you should trade.

## Troubleshooting

| You see | Do this |
|---|---|
| "Finish logging in, in your browser" never ends | Check the redirect URL on the API key page is exactly `http://127.0.0.1:8787/`, then **Connect** again. |
| **Wrong IP** | Add this Mac's address on the API key page, or switch to a registered network. Then save it in Setup & health. |
| "Another app is using port 8787" | Quit the other app, or restart the Mac. |
| "Sayso's engine couldn't start" / "stopped" | Quit and reopen Sayso. If it persists, the **Copy diagnostics** button (also on the right-click menu) copies what's needed to trace it, and **Open logs folder** shows the full logs. |
| "Sayso needs the internet once…" | The first launch downloads Shoonya's connector. Connect to the internet; Sayso tries again by itself. |
| Nothing happens on ⌃⌥Space | macOS uses ⌃⌥Space to switch input sources if you have more than one keyboard language, and another app may use it too. Pick another key: right-click → **Talk key**. |
| It hears you wrongly | Set up the microphone again. Speak after the panel says "Listening", then pause. |

**Copy details** under any message copies the technical text behind it.
Diagnostics hold no secrets: no password, secret code or token. They do
include your account ID, your IP addresses and the path of your user folder.

## Privacy

Sayso has no account of its own, no servers and no analytics. Everything it
keeps stays on this Mac.

**What leaves this Mac**

| Where it goes | What | When |
|---|---|---|
| **Shoonya** (your broker) | Your login, the orders you confirm, and requests for quotes, positions, orders and funds; a check that your login is still valid; Shoonya's public lists of contracts | When you log in, trade or open a pane; the login check about every 2 minutes; the contract lists about twice a day |
| **api.ipify.org**, or **checkip.amazonaws.com** as a fallback | A request that returns this Mac's public internet address, for the IP check. Nothing else is sent. | About every 2 minutes, and after each order |
| **Hugging Face** | A download of the speech model. Nothing is uploaded. | Once, on first use |
| **PyPI** (Python's package index) | A download of Shoonya's connector, which Sayso isn't allowed to ship itself. Nothing is uploaded. | Once, on first launch |

**What never leaves this Mac**

- **Your voice.** Speech is recognised on this Mac. Audio is never saved or
  sent.
- **The login token.** Your login for the day is kept only on this Mac, in
  Sayso's folder.
- **Your secret code.** It is used for one login and never saved anywhere.
  Your client and user IDs are remembered to save typing.

**The log Sayso keeps**, in its logs folder (right-click → **Open logs
folder**):
- For each command: what it heard, the card (contract, quantity, price), what
  you decided and how long you took, and what happened to the order.
- The engine's own log.

It is there so a problem can be traced. The logs replace themselves at 5 MB,
keeping one older file. Nothing is sent anywhere unless you copy it yourself.
"Copy diagnostics" copies Sayso's status and the last lines of the engine's
log, which can include fill messages. It never includes the command log, or
anything you said.

**Deleting it all:** see Uninstall below.

## Uninstall

1. Quit Sayso: right-click → **Quit Sayso**. Delete `Sayso.app`.
2. Delete `~/Library/Application Support/Sayso`. It holds the engine, your
   login token and the logs.
3. Delete `~/.cache/huggingface/hub/models--mlx-community--whisper-small.en-mlx`.
   That is the speech model.
4. Optionally, run `defaults delete com.ekanshtyagi.sayso` to forget the
   remembered IDs.
