# maciOS
**maciOS** is a simple app made to run macOS applications on iOS, using Mach-O patching and custom libraries. with a simple AppKit implementation and multithreading to allow for several applications (Will look into proper subprocesses later

> maciOS is very early and only very simple apps will run.

---

## How does it work?

1. maciOS uses dyld-lv-bypass to use JIT / Executable Memory to bypass codesigning requirements

2. maciOS patches the binary you want to run (More Information on the [LiveContainer Github](https://github.com/LiveContainer/LiveContainer#patching-guest-executable)):
	- Changes platform Identifier to iOS from macOS
    - Patches the app to act like a dynamic library 
    - Replaces uses of macOS frameworks with ones that come with maciOS that have Hooks / Stubs for funcs that don't exist or re-implementations of the macOS counterpart

5. Sets up hook using fishhook that hooks funcs such as tcgetattr / tcsetattr, ioctl and isatty  
   
4. Runs main() using dlopen and dlysm

--- 

## Getting started

1. Install `maciOS.ipa` from the [releases](../../releases) with AltStore, SideStore or a similar tool, and enable JIT for it (StikDebug, SideStore, ...).
   On iOS 26 devices with TXM, StikDebug needs `maciOS.js` from the same release: in LiveContainer, choose it under maciOS's settings > JIT launch script; in StikDebug, assign it to maciOS. Keep StikDebug running in the background while you use maciOS, since it prepares the memory of each program you run.
2. Open maciOS. The Terminal window runs a bash login shell, with the usual command-line tools.
3. The first shell installs [Homebrew](https://brew.sh) into `~/homebrew` (this needs a network connection and takes a minute). Then:

```sh
brew install msedit   # or jq, ...: formulae with bottles for macOS
edit notes.txt
```

`~` is the app's Documents folder, which the Files app shows. Exiting the shell starts a new one. If the Homebrew install fails, run `install-homebrew` to try again.

Limits: there is no compiler, so only formulae with bottles can be installed; Homebrew lives in `~/homebrew` rather than `/opt/homebrew`, so the few bottles that only work there cannot be used; and without git, `brew update` does not work (formulae come from Homebrew's API, so `brew install` and `brew upgrade` see new versions anyway).

## Guest root

Guest programs see a stand-in for `/bin`, `/usr` and `/etc`: `Documents/root`. It holds bash, uutils coreutils, curl, bsdtar, GNU sed/grep/findutils and a few small tools (`lockf`, `sysctl`, `getconf`, stubs of `xcode-select`, `codesign`, ...) that programs such as Homebrew expect from macOS, plus `/etc/profile` (which installs Homebrew) and `/etc/homebrew/brew.env`.

- `GuestRoot/build-root.sh` builds it from Homebrew bottles on your Mac (needs Homebrew).
- The **Embed Guest Root** build phase runs it and puts it in the app as `GuestRoot.aar`; the app installs it into `Documents/root` on launch whenever it is a different build. Without Homebrew on the Mac, the app is built without a guest root.
- `scripts/build-ipa.sh` builds an unsigned `maciOS.ipa` with it. Pushing a `v*` tag runs the same in GitHub Actions and publishes a release.

`brew.env` sets `HOMEBREW_SPAWN_SYSTEM=1` (forked children share the parent's memory, so Homebrew must not run Ruby code in them) and `HOMEBREW_NO_AUTO_UPDATE=1`.

---

## FAQ

**Will this be on the App Store?**  
- Never. It requires JIT, and even without JIT, it would still need to be installed via SideStore or AltStore like LiveContainer.

**Will this run [Insert App Here]?**  
- Probably not. iOS is missing many libraries, functions and frameworks that most GUI and CLI apps depend on.
    - Even if a library or framework exists on iOS, differences in implementation between the macOS and iOS versions can cause compatibility issues and lead to application failures

**Is this Emulation?**
- No, maciOS runs all the apps natively 

---

## Credits

- [LiveContainer](https://github.com/LiveContainer/LiveContainer) – Mach-O patching and guidance.
- [SideStore](https://sidestore.io), [idevice](https://github.com/jkcoxson/idevice) and [StikDebug](https://stikdebug.xyz) – Emotional support 

