# Heartbeat — storyboard (2:45 maximum)

Record only after the real testnet loop has been verified. Use the minute-scale demo
parameters from DEPLOY. Accelerate waiting footage and label the time-lapse; do not
edit simulated activity into a live transaction sequence.

| Time | Shot | English narration |
|---|---|---|
| 0:00–0:20 | Title and three-chain diagram | “Your assets may live on one chain while your activity happens on three. Heartbeat combines explicit activity signals into one configurable inheritance policy.” |
| 0:20–0:45 | Read owner, beneficiary and threshold getters; show funded token balance | “This vault holds demo tokens. Its owner chooses the beneficiary, warning threshold, release threshold and grace period. Native gas funding is separate from the principal.” |
| 0:45–1:15 | Send ping on each chain; open actual origin, reactive and callback receipts | “A ping on Base, Unichain or Ethereum Sepolia reaches this Reactive contract on Lasna. The authenticated callback resets the vault's warning state. No application keeper is running.” |
| 1:15–1:40 | Labeled time-lapse; Warning event and timestamp | “Now the owner goes quiet. Network cron events check elapsed time. A warning starts a grace period on the destination chain.” |
| 1:40–2:10 | Release receipt and beneficiary balance change | “After the thresholds and grace period, the callback transfers the demo tokens. Repeated delivery cannot release twice. The release acknowledgement stops cron.” |
| 2:10–2:30 | Separate unreleased fixture: cancel/configure; rejected stale callback test | “Until release, the owner can cancel or change policy. Every change advances an epoch, making old queued callbacks harmless.” |
| 2:30–2:45 | README evidence rows and test log | “This is an asynchronous inactivity policy, not proof of death. The code, tests and transaction trail show precisely what it does.” |

Narration: about 220 words. Never read an invented transaction hash. If the live
demo is unavailable, present this as an implementation preview, not a completed loop.
