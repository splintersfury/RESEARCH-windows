---
title: "Reversing Redirection Guard"
date: 2026-06-01 12:22:34 +0800
categories: [Research]
tags: [windows, redirection-guard, ntfs, reparse-points, junctions, mitigations, kernel, reverse-engineering]
source: "https://msrc.microsoft.com/blog/2025/06/redirectionguard-mitigating-unsafe-junction-traversal-in-windows"
---

> Follow-up to [Arbitrary Directory Creation to Arbitrary File Read]({% post_url 2026-05-31-windows-exploitation-tricks-arbitrary-directory-creation-to-arbitrary-file-read %}). That post named Redirection Guard as the real mitigation for the whole junction-redirection bug class but treated it as a black box. This one opens the box.

## TL;DR

- Redirection Guard brands every reparse point at **creation** time with a trust level: `2` if an admin created it, `1` if a non-admin did. That byte is stored in the file record.
- At **follow** time, NTFS reads the stored brand and checks it against the **following** process's mitigation policy. An untrusted brand (`1`) plus a follower that opted into Enforce means the traversal is blocked with `STATUS 0xC00004BC`, "the path cannot be traversed because it contains an untrusted mount point."
- The decision lives in `nt` (`IoComputeRedirectionTrustLevel` / `IoCheckRedirectionTrustLevel`); the two enforcement points are in `ntfs.sys` (`NtfsSetReparsePointInternal` on create, `NtfsGetReparsePointValue` on follow).
- It is keyed entirely on the **follower**, not the attacker. That is exactly why the `NtGetNlsSectionPtr` self-call from the previous post still works: the follower is the attacker's own process, which never opted in.

I reversed this statically from `ntoskrnl` + `ntfs.sys` and then confirmed it on a live kernel-debug target. Both agreed.

## Why bother

The last post ended on an unsatisfying note. The conclusion was "Redirection Guard is the real fix, but it is opt in and usually off." That is true, but it is the kind of sentence you write when you have not actually read the code. I wanted the exact rule: what gets blocked, who has to opt in, and where the decision is made. So I went and read it.

## Finding the pieces

A symbol search on a live kernel gives the lay of the land fast:

```
kd> x nt!*RedirectionTrust*
nt!IoCheckRedirectionTrustLevel
nt!IoComputeRedirectionTrustLevel
nt!SeTokenGetRedirectionTrustPolicy
nt!PspGetRedirectionTrustPolicy / PspSetRedirectionTrustPolicy
nt!EtwTimLogRedirectionTrustPolicy
nt!MITIGATION_ENFORCE_REDIRECTION_TRUST_POLICY
nt!MITIGATION_AUDIT_REDIRECTION_TRUST_POLICY
```

So the policy plumbing and the decision both live in `nt`. The two `Io*` functions are the interesting ones, and they are exported, which means filesystems call into them.

## The decision (in nt)

`IoComputeRedirectionTrustLevel` is tiny. It boils down to one line:

```c
*trust = SeTokenIsAdmin(token) ? 2 : 1;   // 2 = admin-created (trusted), 1 = non-admin (untrusted)
```

`IoCheckRedirectionTrustLevel` is where allow-or-block happens. Trimmed from the Hex-Rays output:

```c
if (!enabled || (trust & ~2) == 0) return 0;            // disabled, or trust==2 -> ALLOW
flags   = caller_PrimaryToken[+0xC8];                   // token mitigation flags
enforce = flags & 0x400000;                             // EnforceRedirectionTrust
audit   = flags & 0x800000;                             // AuditRedirectionTrust
if (impersonating >= SecurityImpersonation)
    enforce = enforce && client_token_enforce;          // both tokens must agree
if (enforce) { EtwTimLog(...); return 0xC00004BC; }     // BLOCK
if (audit)   { EtwTimLog(...); return 0; }              // AUDIT: log only, allow
return 0;                                               // no policy -> ALLOW
```

In words: a reparse point is only interesting if it was created by a non-admin (`trust == 1`). For those, it reads the **following** process's token policy. Enforce blocks, audit logs, nothing allows. The block code is worth confirming:

```
kd> !error 0xc00004bc
0xc00004bc - The path cannot be traversed because it contains an untrusted mount point.
```

Two details I did not expect. The policy bits live in the **token** at offset `0xC8`, not just the EPROCESS, and they get there via `PspSetRedirectionTrustPolicy` (the `SetProcessMitigationPolicy` path). And under impersonation the check requires **both** the primary and the impersonated client token to carry Enforce. If a protected service impersonates a client that did not opt in, its own guard weakens. That is a seam worth remembering.

## The enforcement (in ntfs.sys)

The `Io*` functions decide, but `ntfs.sys` is what calls them, and it does so in two mirrored places.

**On create**, `NtfsSetReparsePointInternal` brands the reparse point:

```c
v71 = IoComputeRedirectionTrustLevel((tag != MOUNT_POINT) + 1, NtfsEffectiveMode(creator), 0, &trust);
// trust = SeTokenIsAdmin(creator) ? 2 : 1, then stored into the file record
```

**On follow**, `NtfsGetReparsePointValue` reads that stored brand back and checks it:

```c
stored_trust = *(BYTE *)(reparse + 37);                 // the brand from creation time
v27 = IoCheckRedirectionTrustLevel((tag != MOUNT_POINT) + 1,
                                   NtfsEffectiveMode(follower), 0, stored_trust, etw);
if (v27 < 0)   // 0xC00004BC -> traversal refused
    ...
```

That is the whole architecture. The trust decision is made **once, at creation, from the creator's admin status**, and the result is **stored in the reparse point**. At follow time nothing re-evaluates the creator. NTFS just reads the stored byte and weighs it against the follower's policy. `NtfsEffectiveMode` is the gate that decides whether the check applies at all, so kernel and trusted operations can skip it.

## Watching it decide, live

Static reading is cheap to get wrong, so I set a breakpoint on the decision function on a live target, made a junction, and walked through it:

```
kd> bp nt!IoCheckRedirectionTrustLevel
(on the target, as SYSTEM)
  mklink /J C:\testjunc C:\Windows
  dir C:\testjunc\System32\drivers\etc
```

The breakpoint fired on the traversal. The return address resolved to:

```
Ntfs!NtfsGetReparsePointValue+0x48e
```

which is exactly the follow-side caller the static read predicted. And the live arguments matched the reversed logic to the letter:

```
rcx (a1) = 1   ; (tag != MOUNT_POINT)+1  -> it is a mount point (the junction)
dl  (a2) = 1   ; NtfsEffectiveMode       -> check is armed
r8  (a3) = 0   ; null subject context    -> capture the follower (the 'dir' process)
r9  (a4) = 2   ; stored trust level      -> admin-created -> (2 & ~2)==0 -> ALLOW
```

`a4 = 2` because SYSTEM created the junction, so `IoComputeRedirectionTrustLevel` had branded it trusted at `mklink` time, and the follow check let it straight through. Static and dynamic agree.

## What this means for the older trick

The previous post argued that `NtGetNlsSectionPtr` is still abusable because Redirection Guard is opt in. Reading the code makes that sharper. The check keys on the **follower's** token, full stop. In the self-call case the follower is the attacker's own process, which has no Enforce bit, so even a junction the attacker created (`trust = 1`) is followed without complaint. Redirection Guard protects the "trick a protected service into traversing my junction" pattern, and only for services that actually enabled it. It does nothing for a syscall the attacker drives in their own context.

So the mitigation is real and well built, but its scope is narrower than the headline suggests, and the code says so plainly.

## Learning points

A mitigation can be a property of the **consumer**, not the resource. Redirection Guard never makes a junction safe in the abstract. It only changes what happens when a process that opted in tries to follow one. Ask "who is being protected here," not "is this thing protected."

Decide-once-store-the-result is a common kernel pattern with trade-offs. Branding at creation is cheap and avoids re-deriving trust on every traversal, but it means the stored trust reflects the creator at that moment, not anything about the path at follow time.

Symbol names are a map. `x nt!*RedirectionTrust*` plus following the exports into `ntfs.sys` got me from "no idea" to the two enforcement points in a few minutes. Start there.

A live breakpoint is the cheapest way to check a static read. One traversal of a junction confirmed the caller and every argument at once.

## Pivot topics — dive into next

- [ ] **Watch it block.** Same setup, but a non-admin junction (`trust = 1`) traversed by a process that turned on `EnforceRedirectionTrust` via `SetProcessMitigationPolicy`. Should return `0xC00004BC` live with `a4 = 1`.
- [ ] **`NtfsEffectiveMode`.** This is the gate that arms or skips the check. Exactly when does it return 0? That set is the real "who is exempt" list.
- [ ] **Other filesystems.** Does `fastfat` / `refs` / the redirected-DLL path call `IoCheckRedirectionTrustLevel` the same way, or is this NTFS only?
- [ ] **The token bit at `+0xC8`.** Map `0x400000` / `0x800000` against the documented `PROCESS_MITIGATION_REDIRECTION_TRUST_POLICY` fields and confirm the audit-vs-enforce mapping end to end.
- [ ] **Which services ship it on.** Enumerate processes whose primary token has the Enforce bit set on a default install, to measure real coverage rather than guess at it.
