# Third-party notices

Wisp itself is licensed under the GNU General Public License, version 3 or (at your option) any
later version. See [LICENSE](LICENSE). It has no third-party package dependencies. This file
credits the work it builds on.

## DeskPad (MIT)

<https://github.com/Stengo/DeskPad>

The Objective-C declarations of Apple's private `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`,
`CGVirtualDisplayMode` and `CGVirtualDisplaySettings` classes in
`Sources/CGVirtualDisplayPrivate/include/CGVirtualDisplay.h`, and the approach of creating HiDPI
virtual displays through them, follow DeskPad. The interface is Apple's; DeskPad documented how
to declare and use it.

```
MIT License

Copyright (c) 2022 Bastian Andelefski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apple frameworks

Wisp links against frameworks that ship with macOS and are used under Apple's macOS and Xcode
license terms; none of their code is included in this repository. Used: AppKit, Foundation,
CoreGraphics (including the private `CGVirtualDisplay` classes, see above), ScreenCaptureKit,
VideoToolbox, CoreMedia, CoreVideo, CoreImage, ImageIO, UniformTypeIdentifiers, Network,
ApplicationServices (Accessibility and event injection), CoreServices (LaunchServices), CryptoKit
and IOKit (power management assertions).

Private API: `CGVirtualDisplay` is undocumented and unsupported by Apple. It can change or
disappear in any macOS update. See "Risks" in [README.md](README.md).

## Tailscale

Wisp is designed to run over a [Tailscale](https://tailscale.com) network but does not include,
link or redistribute any Tailscale code. Tailscale is a trademark of Tailscale Inc.; Wisp is not
affiliated with or endorsed by Tailscale Inc. or Apple Inc.
