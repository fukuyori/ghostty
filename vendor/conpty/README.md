# ConPTY host

Ghostty on Windows drives its ptys through ConPTY. The ConPTY that ships in
`kernel32.dll` rebuilds a program's output from a text screen buffer before
handing it to the terminal, and drops anything it does not model on the way.
APC (`ESC _ ... ESC \`) is one of those things, which is the envelope the
Kitty graphics protocol travels in: under that host, a program in a Ghostty
pty cannot show an image at all, because the escape never arrives. Query
replies do not survive the round trip either — `ESC [ c` is answered by the
in-box console host rather than by Ghostty.

The OpenConsole host from the [Microsoft Terminal][terminal] project passes
those sequences through untouched. Microsoft publishes it for exactly this
use, as the [`Microsoft.Windows.Console.ConPTY`][nuget] NuGet package, so
that an application can pin a version instead of taking whatever the OS
happens to have. `src/os/conpty.zig` prefers a `conpty.dll` found next to
`ghostty.exe` and falls back to `kernel32.dll` when there isn't one.

## Getting the binaries

They are not committed here; `.gitignore` keeps them out. Run:

```powershell
./scripts/fetch-conpty.ps1
```

That downloads the pinned package, checks it against the hash recorded in the
script, and writes `conpty.dll` and `OpenConsole.exe` into this directory.
`build.zig` installs both next to `ghostty.exe` when they are present, and
the release and installer scripts fetch them first.

**Both files are needed, and they must come from the same package version.**
`conpty.dll` on its own silently falls back to the in-box host, so a mismatch
looks like no change at all rather than an error.

## Pinned version

`1.24.260710001`, the current stable release of the package.

## License

The binaries are built from the Microsoft Terminal project and are provided
by Microsoft under the MIT license. Redistributing them requires shipping the
notice below, which is why it is repeated in
`dist/windows/THIRD-PARTY-NOTICES.md` for the installer.

```
Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

[terminal]: https://github.com/microsoft/terminal
[nuget]: https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY
