# Third-Party Notices

deviceterm itself is licensed under the GNU General Public License, version 3
or later. See `LICENSE`.

deviceterm is distributed as a macOS application bundle. Entries below
identify either components redistributed within that bundle or upstream
work acknowledged by deviceterm. Each entry states the applicable
relationship and license, and each remains under its own terms rather than
deviceterm's.

## Corresponding source

deviceterm is licensed under the GPL, so the source for everything in
the app bundle is published at
https://github.com/sethdeckard/deviceterm. Each bundle records the
commit it was built from in its Info.plist as `DTSourceCommit`. The
About window shows that commit in its Commit row.

libghostty arrives as a prebuilt binary, so recovering its source takes
one more step. `Package.swift` pins an exact version of
https://github.com/sethdeckard/libghostty-spm. That tag's
`GHOSTTY_VERSION` file names the Ghostty commit the binary was compiled
from, and the same two lines appear in the notes of the matching GitHub
release. Its first line is a `git describe` and can move when upstream
retags, so use the commit line. Ghostty's `build.zig.zon`, together
with the nested `pkg/*/build.zig.zon` manifests, pins every library
named below by URL and content hash.

The source-availability terms in the sections below are met this way,
by publication, rather than by written offer.

## Ghostty (libghostty) — direct dependency

deviceterm embeds libghostty, the core of the Ghostty terminal, as its
terminal engine. Licensed under the MIT License.

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

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

## Sparkle — direct dependency

deviceterm embeds the Sparkle framework to deliver signed in-app updates.
Licensed under the MIT License.

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Sparkle has its own dependencies, statically linked into the framework
binary. deviceterm does not depend on them directly and carries them only
because it embeds Sparkle:

- **bsdiff / bspatch** — BSD 2-clause, Copyright 2003-2005 Colin Percival
- **sais-lite** — MIT, Copyright (c) 2008-2010 Yuta Mori
- **Ed25519 (portable C)** — zlib, Copyright (c) 2015 Orson Peters
- **`SUSignatureVerifier.m`** — BSD 2-clause, Copyright (c) 2011 Mark Hamlin

Their full license texts are reproduced in Sparkle's own `LICENSE`, upstream
at https://github.com/sparkle-project/Sparkle/blob/main/LICENSE. Note that
the framework binary itself ships no license file, so that upstream text is
the authoritative copy rather than anything inside the embedded framework.

## Meta idb private headers — vendored source

deviceterm vendors a snapshot of private CoreSimulator, SimulatorKit, and
SimulatorApp header declarations from Meta's idb project
(https://github.com/facebook/idb). Upstream copyright notices are preserved
in every vendored header. Licensed under the MIT License.

```
MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.

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

## Apple device protocol acknowledgments

deviceterm includes independently developed support for undocumented Apple
device protocols, including behavior determined through direct observation,
device captures, and original implementation work.

Some portions of its protocol handling, including certain constants,
wire-format details, and related implementation techniques, were informed by
or adapted from:

- **pymobiledevice3** (https://github.com/doronz88/pymobiledevice3) — GNU
  General Public License v3.0 or later
- **idevice** (https://github.com/jkcoxson/idevice) — MIT License

This acknowledgment applies only to the relevant portions and does not
indicate that deviceterm's implementation as a whole was derived from these
projects. Copyright in the respective upstream materials remains with their
authors and contributors. Neither project is bundled with or required at
runtime by deviceterm.

The MIT notice for idevice follows:

```
Copyright 2026 Jackson Coxson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The components below are transitive dependencies — not direct deviceterm
dependencies. They are redistributed because Ghostty embeds or bundles
them inside the libghostty binary and resource bundle that deviceterm
ships.

## JetBrains Mono — transitive dependency (via Ghostty)

JetBrains Mono is embedded in the libghostty binary as Ghostty's
built-in fallback typeface. Copyright 2020 The JetBrains Mono Project
Authors (https://github.com/JetBrains/JetBrainsMono), with Reserved Font
Name "JetBrains Mono". Licensed under the SIL Open Font License, Version
1.1 (reproduced below).

## Symbols Nerd Font — transitive dependency (via Ghostty)

The symbols-only Nerd Font is embedded in the libghostty binary to
provide icon/symbol glyph coverage. Copyright (c) 2014, Ryan L McIntyre
and the Nerd Fonts project (https://github.com/ryanoasis/nerd-fonts),
with Reserved Font Name "Symbols Nerd Font". Licensed under the SIL Open
Font License, Version 1.1 (reproduced below). The Symbols Nerd Font
aggregates glyphs from multiple upstream icon sets, each under its own
license; see the Nerd Fonts license audit for the full per-source
breakdown:
https://github.com/ryanoasis/nerd-fonts/blob/master/LICENSE

Both fonts above are licensed under the SIL Open Font License, Version
1.1:

```
This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

## Statically linked libraries — transitive dependency (via Ghostty)

Ghostty links these libraries into libghostty, so their object code is
inside the binary deviceterm ships. deviceterm does not depend on any
of them directly and carries them only because it embeds libghostty.
Each asks that its notice be reproduced and nothing further. The four
sections after this one carry conditions beyond that.

- **libxev** (https://github.com/mitchellh/libxev) — MIT, Copyright
  (c) 2023 Mitchell Hashimoto
- **zig-objc** (https://github.com/mitchellh/zig-objc) — MIT,
  Copyright (c) 2023 Mitchell Hashimoto
- **libvaxis** (https://github.com/rockorager/libvaxis) — MIT,
  Copyright (c) 2023 Tim Culverhouse
- **zf** (https://github.com/natecraddock/zf) — MIT, Copyright (c)
  Nathan Craddock
- **uucode** (https://github.com/jacobsandlund/uucode) — MIT,
  Copyright (c) 2025, 2026 Jacob Sandlund
- **Dear ImGui** (https://github.com/ocornut/imgui) — MIT, Copyright
  (c) 2014-2025 Omar Cornut
- **dear_bindings** (https://github.com/dearimgui/dear_bindings) — MIT
- **sentry-native** (https://github.com/getsentry/sentry-native) —
  MIT, Copyright (c) 2019 Sentry (https://sentry.io) and individual
  contributors
- **Oniguruma** (https://github.com/kkos/oniguruma) — BSD 2-clause,
  Copyright (c) 2002-2021 K.Kosako
- **zlib** (https://zlib.net) — zlib License, (C) 1995-2022 Jean-loup
  Gailly and Mark Adler
- **libpng** (http://www.libpng.org/pub/png/libpng.html) — PNG
  Reference Library License version 2, Copyright (c) 1995-2024 The PNG
  Reference Library Authors
- **FreeType** (https://freetype.org) — FreeType License, Copyright
  1996-2023 David Turner, Robert Wilhelm, and Werner Lemberg
- **stb_image, stb_image_resize** (https://github.com/nothings/stb) —
  MIT or public domain at your option, Copyright (c) 2017 Sean Barrett

dear_bindings ships as generated C sources carrying only the project
URL, with no copyright line, so the entry above is the notice that
travels with the binary.

FreeType is offered under the FreeType License or GPLv2. deviceterm
uses it under the FreeType License, which asks for this credit:

```
Portions of this software are copyright © 2023 The FreeType
Project (www.freetype.org).  All rights reserved.
```

The full FreeType License is at
https://gitlab.freedesktop.org/freetype/freetype/-/blob/master/docs/FTL.TXT

The MIT-licensed libraries above share one permission notice:

```
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

Oniguruma:

```
Oniguruma LICENSE
-----------------

Copyright (c) 2002-2021  K.Kosako  <kkosako0@gmail.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
```

zlib:

```
Copyright notice:

 (C) 1995-2022 Jean-loup Gailly and Mark Adler

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  Jean-loup Gailly        Mark Adler
  jloup@gzip.org          madler@alumni.caltech.edu
```

libpng:

```
PNG Reference Library License version 2
---------------------------------------

 * Copyright (c) 1995-2024 The PNG Reference Library Authors.
 * Copyright (c) 2018-2024 Cosmin Truta.
 * Copyright (c) 2000-2002, 2004, 2006-2018 Glenn Randers-Pehrson.
 * Copyright (c) 1996-1997 Andreas Dilger.
 * Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.

The software is supplied "as is", without warranty of any kind,
express or implied, including, without limitation, the warranties
of merchantability, fitness for a particular purpose, title, and
non-infringement.  In no event shall the Copyright owners, or
anyone distributing the software, be liable for any damages or
other liability, whether in contract, tort or otherwise, arising
from, out of, or in connection with the software, or the use or
other dealings in the software, even if advised of the possibility
of such damage.

Permission is hereby granted to use, copy, modify, and distribute
this software, or portions hereof, for any purpose, without fee,
subject to the following restrictions:

 1. The origin of this software must not be misrepresented; you
    must not claim that you wrote the original software.  If you
    use this software in a product, an acknowledgment in the product
    documentation would be appreciated, but is not required.

 2. Altered source versions must be plainly marked as such, and must
    not be misrepresented as being the original software.

 3. This Copyright notice may not be removed or altered from any
    source or altered source distribution.
```

stb_image and stb_image_resize offer either the MIT terms above or a
public domain dedication:

```
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2017 Sean Barrett
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
ALTERNATIVE B - Public Domain (www.unlicense.org)
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Apache-2.0 licensed components — transitive dependency (via Ghostty)

Five statically linked components are licensed under the Apache
License, Version 2.0:

- **Highway** (https://github.com/google/highway) — Copyright 2020
  Google LLC
- **Wuffs** (https://github.com/google/wuffs) — Copyright 2023 The
  Wuffs Authors
- **simdutf** (https://github.com/simdutf/simdutf)
- **SPIRV-Cross** (https://github.com/KhronosGroup/SPIRV-Cross) —
  Copyright 2015-2021 Arm Limited
- **glslang** (https://github.com/KhronosGroup/glslang) — Copyright
  2020 The Khronos Group Inc, and see below

A copy of the license ships at
Contents/Resources/licenses/Apache-2.0.txt. It is also at
https://www.apache.org/licenses/LICENSE-2.0.txt

None of the five ships a NOTICE file, so there is no NOTICE text to
carry forward.

Ghostty vendors modified copies of three Highway sources —
hwy/targets.cc, hwy/abort.cc and hwy/per_target.cc — into
pkg/highway/src/cpp/. The changes drop upstream CPU feature probing for
Ghostty's own target detection and remove a libc-backed diagnostic
path. Each file names in its header the upstream commit it came from
and what was changed, which is the record of changes the license asks
for. The other four are used as published. deviceterm modifies none of
them.

glslang should not be called Apache-2.0 without qualification. Its
license file combines BSD 3-clause, BSD 2-clause, MIT and Apache-2.0
terms across different parts of the project, along with a GPL-3 section
carrying a bison exception that applies to generated parser files
current glslang no longer contains. That file ships at
Contents/Resources/licenses/glslang-LICENSE.txt.

simdutf's amalgamated header includes one file adapted from Torch,
internal/isadetection.h, under BSD 3-clause. Its notice appears in the
Breakpad section below with the other BSD 3-clause notices.

## Breakpad — transitive dependency (via Ghostty)

Ghostty links Google Breakpad's macOS crash-reporting client
(https://chromium.googlesource.com/breakpad/breakpad). Google's own
code is BSD 3-clause, Copyright 2006 Google LLC. The macOS client is
not BSD 3-clause throughout: two files under other terms compile into
the binary deviceterm ships.

- **src/common/convert_UTF.cc** — Unicode, Inc. terms of use,
  Copyright © 1991-2015 Unicode, Inc.
  (http://www.unicode.org/copyright.html)
- **src/client/mac/handler/breakpad_nlist_64.cc**, with the Mach-O
  headers under src/third_party/mac_headers/ — Apple Public Source
  License, Version 2.0, and a BSD 4-clause notice from The Regents of
  the University of California

The Regents notice is the original four-clause BSD, not the three-clause
form. Its third condition requires that advertising material mentioning
features or use of the software display an acknowledgement of the
University of California, Berkeley and its contributors. The University
withdrew that clause from its BSD-licensed code in 1999, and this file
is copyright The Regents, so the condition is not one deviceterm carries
forward. It is reproduced here because the text that ships still states
it:

```
3. All advertising materials mentioning features or use of this software
   must display the following acknowledgement:
     This product includes software developed by the University of
     California, Berkeley and its contributors.
```

Breakpad's license file carries all of these together, each with the
list of files it covers, including the full Apple Public Source License,
the Unicode terms, and the Regents notice in full. It ships at
Contents/Resources/licenses/Breakpad-LICENSE.txt.

Google's BSD 3-clause notice:

```
Copyright 2006 Google LLC

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
    * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The BSD 3-clause notice for the Torch-derived isadetection.h inside
simdutf, which names different copyright holders:

```
Copyright (c) 2016-     Facebook, Inc            (Adam Paszke)
Copyright (c) 2014-     Facebook, Inc            (Soumith Chintala)
Copyright (c) 2011-2014 Idiap Research Institute (Ronan Collobert)
Copyright (c) 2012-2014 Deepmind Technologies    (Koray Kavukcuoglu)
Copyright (c) 2011-2012 NEC Laboratories America (Koray Kavukcuoglu)
Copyright (c) 2011-2013 NYU                      (Clement Farabet)
Copyright (c) 2006-2010 NEC Laboratories America (Ronan Collobert, Leon Bottou,
Iain Melvin, Jason Weston) Copyright (c) 2006      Idiap Research Institute
(Samy Bengio) Copyright (c) 2001-2004 Idiap Research Institute (Ronan Collobert,
Samy Bengio, Johnny Mariethoz)

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

3. Neither the names of Facebook, Deepmind Technologies, NYU, NEC Laboratories
America and IDIAP Research Institute nor the names of its contributors may be
   used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## z2d — transitive dependency (via Ghostty)

Ghostty links z2d (https://github.com/vancluever/z2d), a 2D vector
rasterizer. Copyright © 2024-2025 Chris Marchesi. Licensed under the
Mozilla Public License, Version 2.0.

The MPL's copyleft is per-file. It covers z2d's own source files and
reaches nothing else in deviceterm, and combining those files with a
larger work under other terms is what the license allows.

For a binary distribution the MPL asks that recipients be told how to
get the source form of the covered files and how to get the license.
The exact z2d in any deviceterm build is pinned by URL and content hash
in Ghostty's build.zig.zon at the commit named in GHOSTTY_VERSION,
which Corresponding source above explains how to find. Upstream is
https://github.com/vancluever/z2d. The license ships at
Contents/Resources/licenses/MPL-2.0.txt and is at
https://mozilla.org/MPL/2.0/

deviceterm modifies no z2d file. The version Ghostty pins ships no
license file of its own, carrying the MPL identification in SPDX
headers inside its sources, so this notice is where it is reproduced.

## GNU libintl — transitive dependency (via Ghostty)

Ghostty links GNU gettext's runtime message-lookup library, libintl.
Copyright (C) 1995-2025 Free Software Foundation, Inc. Licensed under
the GNU Lesser General Public License, version 2.1 or later. Ghostty
builds it from the upstream sources with its own build configuration
and does not modify the library sources; neither does deviceterm.

This section is the notice the LGPL asks for: libintl is used in
deviceterm, and libintl and its use are covered by the LGPL. A copy of
the license ships at Contents/Resources/licenses/LGPL-2.1.txt and is at
https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt

The LGPL lets a work that only links the library ship under other
terms, provided recipients can modify the library and relink the work
against their version. deviceterm meets that by publication, not by
offer. The route is:

1. Take the deviceterm source at the commit the bundle records in
   DTSourceCommit, from https://github.com/sethdeckard/deviceterm
2. Read the libghostty-spm version pinned in its Package.swift, then
   read GHOSTTY_VERSION at that tag for the Ghostty commit.
3. Rebuild GhosttyKit.xcframework from that libghostty-spm tag with
   scripts/build-xcframework.sh, substituting your libintl for the one
   Ghostty's pkg/libintl fetches by hash.
4. Point deviceterm's Package.swift at your framework and rebuild.
   scripts/make-app-bundle.sh assembles the bundle.

Nothing on that path is withheld. "Or later" also keeps the combination
clean, since LGPL-2.1-or-later can be taken as LGPL-3.0, which is
compatible with GPLv3.

## iTerm2-Color-Schemes — transitive dependency (via Ghostty)

Ghostty bundles its built-in color themes from the iTerm2-Color-Schemes
project, which deviceterm redistributes in libghostty's resource bundle.
Licensed under the MIT License.

```
MIT License

Copyright (c) 2015 mbadolato and iTerm2-Color-Schemes contributors

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

## Ghostty shell integration — transitive dependency (via Ghostty)

Ghostty's shell integration scripts ship in libghostty's resource tree,
which deviceterm redistributes twice inside the app bundle: once inside
libghostty's own resource bundle, and once flattened to
Contents/Resources/ghostty/ghostty/shell-integration/. The repeated
path segment there is not a typo — the copied tree keeps Ghostty's own
directory layout inside a directory already named ghostty. Three of
those files are licensed under the GNU General Public License, version
3 or later:

- **shell-integration/bash/ghostty.bash** — GPL-3.0-or-later
- **shell-integration/zsh/ghostty-integration** — GPL-3.0-or-later
- **shell-integration/zsh/.zshenv** — GPL-3.0-or-later

Each began as, or borrows from, Kitty's shell integration
(https://github.com/kovidgoyal/kitty), which is distributed under
GPLv3. Each says so in its own header and reproduces the GPL notice
there, and deviceterm ships those headers unaltered. Copyright in the
Kitty-derived material remains with the Kitty authors and in Ghostty's
additions with the Ghostty authors. Neither project states a copyright
line in these files, so none is stated here.

The GPL's source requirement for them is self-satisfying: they ship as
source, which is the form preferred for modifying them, and nothing is
compiled from them. The requirement that a copy of the license
accompany them is met by deviceterm's own LICENSE, the complete text of
GPLv3, which ships in every bundle at Contents/Resources/LICENSE.
libghostty also places a copy beside the scripts themselves at
shell-integration/GPL-3.0.txt.

deviceterm is licensed under GPL-3.0-or-later, so these files ask
nothing of it that its own license does not already ask. They appear
here because deviceterm redistributes them. They reach nothing else in
it: the user's shell sources them, and no part of deviceterm links
against them.

## bash-preexec — transitive dependency (via Ghostty)

Ghostty's bash integration depends on bash-preexec
(https://github.com/rcaloras/bash-preexec), which ships in the same
directory as the scripts above, at
shell-integration/bash/bash-preexec.sh. Licensed under the MIT License,
Copyright (c) 2017 Ryan Caloras and contributors, forked from earlier
work by Glyph Lefkowitz.

The copy that ships carries an author line and no license text, so the
notice below is the one that travels with it.

```
MIT License

Copyright (c) 2017 Ryan Caloras and contributors

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

Ghostty's own fish, elvish and nushell integrations ship in the same
tree under Ghostty's MIT license, reproduced at the top of this
document.
