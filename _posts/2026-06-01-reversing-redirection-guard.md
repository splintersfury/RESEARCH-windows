---
title: "Reversing Redirection Guard"
date: 2026-06-01 12:22:34 +0800
categories: [Research]
tags: [windows, redirection-guard, ntfs, reparse-points, junctions, mitigations, kernel, reverse-engineering]
source: "https://msrc.microsoft.com/blog/2025/06/redirectionguard-mitigating-unsafe-junction-traversal-in-windows"
---

> Follow-up to [Arbitrary Directory Creation to Arbitrary File Read]({% post_url 2026-05-31-windows-exploitation-tricks-arbitrary-directory-creation-to-arbitrary-file-read %}). That post pointed at Redirection Guard as the actual fix for the whole junction-redirection class, then waved its hands. This one reads the code.

## TL;DR

- Redirection Guard brands a reparse point the moment it's created. Trust `2` if an admin made it, `1` if not. That byte gets written into the file record.
- When something later follows that reparse, NTFS reads the brand back and checks it against the **following** process's mitigation policy. Brand `1` plus a follower with Enforce turned on means blocked, `STATUS 0xC00004BC` ("the path cannot be traversed because it contains an untrusted mount point").
- The decision lives in `nt` (`IoComputeRedirectionTrustLevel`, `IoCheckRedirectionTrustLevel`). NTFS calls it from two spots: `NtfsSetReparsePointInternal` when you make a reparse, `NtfsGetReparsePointValue` when you follow one.
- The whole thing keys on the **follower**, not on whoever made the junction. Which is the entire reason the `NtGetNlsSectionPtr` trick from last post still works. There the follower is the attacker's own process, and it never opted in.

I read this out of `ntoskrnl` and `ntfs.sys` first, then put a breakpoint on it on a live box to check. They matched.

## Why bother

Last post I ended with "Redirection Guard is the real fix, but it's opt-in and usually off." True, but that's the kind of sentence you write when you haven't actually read the thing. I wanted the exact rule. What gets blocked, who has to opt in, where the call happens. So I read it.

## Finding the pieces

Symbol search on a live kernel, instant map:

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

So the policy plumbing and the decision both sit in `nt`. The two `Io*` functions are the ones I care about. They're exported, which is why filesystems can call them.

## The decision (in nt)

`IoComputeRedirectionTrustLevel` is basically one line:

```c
*trust = SeTokenIsAdmin(token) ? 2 : 1;   // 2 = admin-created (trusted), 1 = non-admin (untrusted)
```

`IoCheckRedirectionTrustLevel` is where it actually says yes or no. Trimmed from the Hex-Rays:

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

So a reparse only matters if a non-admin made it (`trust == 1`). For those it reads the **following** process's token policy. Enforce blocks, audit logs, nothing lets it through. Quick sanity check on the status code:

```
kd> !error 0xc00004bc
0xc00004bc - The path cannot be traversed because it contains an untrusted mount point.
```

Two things I didn't expect. The policy bits sit in the **token** at `+0xC8`, not just on the EPROCESS, and they get there through `PspSetRedirectionTrustPolicy` (the `SetProcessMitigationPolicy` path). And when you're impersonating, it wants **both** the primary and the client token to carry Enforce. So a protected service that impersonates some client who didn't opt in just weakened its own guard. Nice little seam.

## The enforcement (in ntfs.sys)

`nt` decides. `ntfs.sys` is what calls it, twice, mirrored.

Creating a reparse, `NtfsSetReparsePointInternal` brands it:

```c
v71 = IoComputeRedirectionTrustLevel((tag != MOUNT_POINT) + 1, NtfsEffectiveMode(creator), 0, &trust);
// trust = SeTokenIsAdmin(creator) ? 2 : 1, then stored into the file record
```

Following one, `NtfsGetReparsePointValue` reads the brand back and checks it:

```c
stored_trust = *(BYTE *)(reparse + 37);                 // the brand from creation time
v27 = IoCheckRedirectionTrustLevel((tag != MOUNT_POINT) + 1,
                                   NtfsEffectiveMode(follower), 0, stored_trust, etw);
if (v27 < 0)   // 0xC00004BC -> traversal refused
    ...
```

That's the whole shape of it. Trust gets decided once, at creation, off the creator's admin status, and the answer is **stored in the reparse point**. Nothing re-checks the creator when you follow it later. NTFS just reads that one byte and weighs it against the follower. `NtfsEffectiveMode` is the switch for whether the check even runs, so kernel and trusted opens skip it.

## Watching it decide, live

Reading decompiler output is easy to get wrong, so I dropped a breakpoint on the decision, made a junction on the target, then walked a path through it:

```
kd> bp nt!IoCheckRedirectionTrustLevel
(on the target, as SYSTEM)
  mklink /J C:\testjunc C:\Windows
  dir C:\testjunc\System32\drivers\etc
```

It hit on the traversal. Return address came back as:

```
Ntfs!NtfsGetReparsePointValue+0x48e
```

which is the exact follow-side caller the static read said it'd be. And the live args lined up one for one:

```
rcx (a1) = 1   ; (tag != MOUNT_POINT)+1  -> it is a mount point (the junction)
dl  (a2) = 1   ; NtfsEffectiveMode       -> check is armed
r8  (a3) = 0   ; null subject context    -> capture the follower (the 'dir' process)
r9  (a4) = 2   ; stored trust level      -> admin-created -> (2 & ~2)==0 -> ALLOW
```

`a4 = 2` because SYSTEM made the junction, so `IoComputeRedirectionTrustLevel` had already branded it trusted back at `mklink`, and the follow check waved it through. Static read and live box, same answer.

## What this means for the old trick

Last post I said `NtGetNlsSectionPtr` is still good because Redirection Guard is opt-in. Reading the code makes that a lot less hand-wavy. The check looks at the **follower's** token, that's it. In the self-call case the follower is the attacker's own process with no Enforce bit, so even a junction the attacker made (`trust = 1`) gets followed, no complaint. Redirection Guard covers the "trick a protected service into walking my junction" shape, and only for the services that turned it on. A syscall you drive in your own process? It does nothing.

So it's a real, well-built mitigation. Just narrower than the headline, and the code just says it.

## Prior work

I'm not the first here. The groundwork is [Gal De Leon's 2022 Unit 42 writeup](https://unit42.paloaltonetworks.com/junctions-windows-redirection-trust-mitigation/), which reversed the core decision functions and the opt-in policy, and the [MSRC post](https://msrc.microsoft.com/blog/2025/06/redirectionguard-mitigating-unsafe-junction-traversal-in-windows) is the official one. Both worth reading.

What this one adds is detail on a current build: the exact `ntfs.sys` call sites (`NtfsSetReparsePointInternal` on create, `NtfsGetReparsePointValue` on follow), a live breakpoint confirming the follow path and its arguments, the impersonation rule (`enforce && client_token_enforce`), and where coverage sits now.

Two specifics I wanted nailed down, since they're easy to get fuzzy:

- **Where the trust lives.** Create writes the byte to the FCB at offset 37, then `NtfsUpdateStandardInformation` persists it into the file's `$STANDARD_INFORMATION`.
- **The block status code.** `0xC00004BC`, "the path cannot be traversed because it contains an untrusted mount point". The same value the function returns in the decompile.

## Stuff I took away

- A mitigation can belong to the **consumer**, not the resource. Redirection Guard never makes a junction "safe." It only changes what happens when a process that opted in tries to walk one. The question isn't "is this protected," it's "who's being protected."
- Branding once at create and storing it is cheap, but the stored trust is about the creator at that one moment. It says nothing about the path when you actually follow it.
- Symbol names did most of the work here. `x nt!*RedirectionTrust*`, follow the exports into NTFS, done in a few minutes.
- A breakpoint is the cheapest fact-check for a static read. One junction traversal confirmed the caller plus every argument at once.

## Pivot topics — dive into next

- [ ] **Watch it actually block.** Same thing but a non-admin junction (`trust = 1`) walked by a process that turned on `EnforceRedirectionTrust`. Should spit `0xC00004BC` with `a4 = 1`.
- [ ] **`NtfsEffectiveMode`.** This is the switch that arms or skips the check. When exactly does it return 0? That set is the real "who's exempt" list.
- [ ] **Other filesystems.** Does `fastfat` / `refs` call `IoCheckRedirectionTrustLevel` the same way, or is this an NTFS thing?
- [ ] **The token bit at `+0xC8`.** Line `0x400000` / `0x800000` up against the documented `PROCESS_MITIGATION_REDIRECTION_TRUST_POLICY` fields and nail the audit-vs-enforce mapping.
- [ ] **Who actually ships it on.** Count the processes whose primary token has the Enforce bit on a stock install, instead of guessing at coverage.
