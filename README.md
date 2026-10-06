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

## Guest root and Homebrew

Guest programs see a stand-in for `/bin`, `/usr` and `/etc`: `Documents/root`. It holds bash, uutils coreutils, curl, bsdtar, GNU sed/grep/findutils and a few small tools (`lockf`, `sysctl`, `getconf`, ...) that programs such as Homebrew expect from macOS.

- `GuestRoot/build-root.sh` builds it from Homebrew bottles on your Mac (needs Homebrew).
- The **Embed Guest Root** build phase runs it and puts the result in the app; the app installs it into `Documents/root` on launch whenever it is a different build. Without Homebrew on the Mac, the app is built without a guest root.

Homebrew itself can then be installed from inside maciOS:

```sh
mkdir homebrew && curl -L https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C homebrew
homebrew/bin/brew install msedit
```

`/etc/homebrew/brew.env` in the guest root sets `HOMEBREW_SPAWN_SYSTEM=1`: forked children share the parent's memory, so Homebrew must not run Ruby code in them.

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

