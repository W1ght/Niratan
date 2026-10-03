//
//  AboutView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct AboutView: View {
    @State private var updateChecker = UpdateChecker.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
    
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        nativeContent
            .navigationTitle("About")
    }

    private var nativeContent: some View {
        NativeSettingsForm {
            NativeSettingsSectionCard("App") {
                NativeSettingsRow("Version") {
                    Text(version)
                        .foregroundStyle(.secondary)
                }
            }

            NativeSettingsSectionCard("Software Update") {
                NativeSettingsToggle(
                    "Automatically Check for Updates",
                    isOn: $updateChecker.automaticChecksEnabled
                )
                NativeSettingsSeparator()
                NativeSettingsRow {
                    updateStatus
                } accessory: {
                    updateAction
                }
            } footer: {
                Text("Niratan checks the latest GitHub release once a day.")
            }

            NativeSettingsSectionCard("Links") {
                linkRow("GitHub", systemImage: "link", url: "https://github.com/W1ght/Niratan")
                NativeSettingsSeparator()
                linkRow("Privacy Policy", systemImage: "hand.raised", url: "https://github.com/W1ght/Niratan/blob/main/PRIVACY.md")
            }

            NativeSettingsSectionCard("Dependencies") {
                nativeLicenseRows(dependencyItems)
            }

            NativeSettingsSectionCard("Attribution") {
                nativeLicenseRows(attributionItems)
            }
        }
    }

    private var updateStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(updateStatusTitle)
            if let lastCheckedAt = updateChecker.lastCheckedAt {
                Text("Last checked: \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var updateStatusTitle: String {
        if updateChecker.isDownloading {
            return updateChecker.downloadStatusText
        }
        if updateChecker.isChecking {
            return String(localized: "Checking for Updates...")
        }
        if let release = updateChecker.availableRelease {
            return String(format: String(localized: "Version %@ is available."), release.version)
        }
        if updateChecker.lastCheckFailed {
            return String(localized: "Unable to check for updates. Please try again later.")
        }
        if updateChecker.lastCheckedAt != nil {
            return String(format: String(localized: "Niratan %@ is the latest version."), updateChecker.currentVersion)
        }
        return String(localized: "Not checked yet")
    }

    @ViewBuilder
    private var updateAction: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if updateChecker.availableRelease != nil {
                    Button("Download and Install") {
                        Task {
                            await updateChecker.downloadAndOpenAvailableUpdate()
                        }
                    }
                }
                Button("Check Now") {
                    Task {
                        await updateChecker.check(manual: true)
                    }
                }
            }
        }
        .buttonStyle(NativeSettingsActionButtonStyle())
        .disabled(updateChecker.isBusy)
    }

    private func linkRow(_ title: LocalizedStringKey, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            NativeSettingsRow {
                Label(title, systemImage: systemImage)
            } accessory: {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func nativeLicenseRows(_ items: [LicenseItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
                NativeSettingsSeparator()
            }
            NativeLicenseRow(item: item)
        }
    }
    
    private var bsdLicenseZstd: String {
        """
        BSD License
        
        For Zstandard software
        
        Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
        
        Redistribution and use in source and binary forms, with or without modification,
        are permitted provided that the following conditions are met:
        
         * Redistributions of source code must retain the above copyright notice, this
           list of conditions and the following disclaimer.
        
         * Redistributions in binary form must reproduce the above copyright notice,
           this list of conditions and the following disclaimer in the documentation
           and/or other materials provided with the distribution.
        
         * Neither the name Facebook, nor Meta, nor the names of its contributors may
           be used to endorse or promote products derived from this software without
           specific prior written permission.
        
        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
        ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
        LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
        ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
        SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }
    
    private var bsdLicenseTtu: String {
        """
        BSD 3-Clause License
        
        Copyright (c) 2024, ッツ Reader Authors
        All rights reserved.
        
        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:
        
        1. Redistributions of source code must retain the above copyright notice, this
           list of conditions and the following disclaimer.
        
        2. Redistributions in binary form must reproduce the above copyright notice,
           this list of conditions and the following disclaimer in the documentation
           and/or other materials provided with the distribution.
        
        3. Neither the name of the copyright holder nor the names of its
           contributors may be used to endorse or promote products derived from
           this software without specific prior written permission.
        
        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
        FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
        CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
        OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }
    
    private var bsdLicenseKanjiStrokeOrders: String {
        """
        Copyright (C) 2004-2020 Ulrich Apel, the AAAA project and the Wadoku project
        All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions
        are met:

        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.
        3. Neither the name of the author may be used to endorse or promote products
           derived from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
        OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
        IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
        INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
        NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
        DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
        THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
        THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }

    private var bsdLicensexxHash: String {
        """
        xxHash Library
        Copyright (c) 2012-2021 Yann Collet
        All rights reserved.
        
        BSD 2-Clause License (https://www.opensource.org/licenses/bsd-license.php)
        
        Redistribution and use in source and binary forms, with or without modification,
        are permitted provided that the following conditions are met:
        
        * Redistributions of source code must retain the above copyright notice, this
          list of conditions and the following disclaimer.
        
        * Redistributions in binary form must reproduce the above copyright notice, this
          list of conditions and the following disclaimer in the documentation and/or
          other materials provided with the distribution.
        
        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
        ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
        LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
        ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
        SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }
    
    private func mitLicense(copyright: String) -> String {
        """
        MIT License
        
        \(copyright)
        
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
        """
    }

    private var dependencyItems: [LicenseItem] {
        var items = [
            LicenseItem(
                name: "AEXML (EPUBKit)",
                license: "MIT",
                url: "https://github.com/tadija/AEXML",
                text: mitLicense(copyright: "Copyright (c) 2014-2024 Marko Tadić (https://markotadic.com)")
            ),
            LicenseItem(
                name: "ZIPFoundation (EPUBKit)",
                license: "MIT",
                url: "https://github.com/weichsel/ZIPFoundation",
                text: mitLicense(copyright: "Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)")
            ),
            LicenseItem(
                name: "Wasm3 Swift Wrapper (AidokuRuntime)",
                license: "MIT",
                url: "https://github.com/Skittyblock/Wasm3",
                text: mitLicense(copyright: "Copyright (c) 2023-2025 Skittyblock")
            ),
            LicenseItem(
                name: "Wasm3 Core (AidokuRuntime)",
                license: "MIT",
                url: "https://github.com/wasm3/wasm3",
                text: mitLicense(copyright: "Copyright (c) 2019 Steven Massey, Volodymyr Shymanskyy")
            ),
            LicenseItem(
                name: "SwiftSoup 2.13.7 (AidokuRuntime)",
                license: "MIT",
                url: "https://github.com/scinfu/SwiftSoup/tree/2.13.7",
                text: mitLicense(copyright: "Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>\nCopyright (c) 2016-2025 Nabil Chatbi (Swift port)")
            ),
            LicenseItem(
                name: "ZIPFoundation (AidokuRuntime)",
                license: "MIT",
                url: "https://github.com/weichsel/ZIPFoundation",
                text: mitLicense(copyright: "Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)")
            ),
            LicenseItem(
                name: "libdeflate (hoshidicts)",
                license: "MIT",
                url: "https://github.com/ebiggers/libdeflate",
                text: mitLicense(copyright: "Copyright 2016 Eric Biggers\nCopyright 2024 Google LLC")
            ),
            LicenseItem(
                name: "utfcpp (hoshidicts)",
                license: "BSL-1.0",
                url: "https://github.com/nemtrif/utfcpp",
                text: nil
            ),
            LicenseItem(
                name: "glaze (hoshidicts)",
                license: "MIT",
                url: "https://github.com/stephenberry/glaze",
                text: mitLicense(copyright: "Copyright (c) 2019 - present, Stephen Berry")
            ),
            LicenseItem(
                name: "xxHash (hoshidicts)",
                license: "BSD-2.0",
                url: "https://github.com/Cyan4973/xxHash",
                text: bsdLicensexxHash
            ),
            LicenseItem(
                name: "unordered_dense (hoshidicts)",
                license: "MIT",
                url: "https://github.com/martinus/unordered_dense",
                text: mitLicense(copyright: "Copyright (c) 2022 Martin Leitner-Ankerl")
            ),
            LicenseItem(
                name: "zstd",
                license: "BSD-3",
                url: "https://github.com/facebook/zstd",
                text: bsdLicenseZstd
            ),
            LicenseItem(
                name: "SwiftUI Introspect",
                license: "MIT",
                url: "https://github.com/siteline/swiftui-introspect",
                text: mitLicense(copyright: "Copyright 2019 Timber Software")
            ),
            LicenseItem(
                name: "EPUBKit",
                license: "MIT",
                url: "https://github.com/witekbobrowski/EPUBKit",
                text: mitLicense(copyright: "Copyright (c) 2022 Witek Bobrowski")
            ),
            LicenseItem(
                name: "hoshidicts",
                license: "GPLv3",
                url: "https://github.com/Manhhao/hoshidicts",
                text: nil
            )
        ]
        items.append(
            LicenseItem(
                name: "libmpv",
                license: "GPLv2+",
                url: "https://github.com/mpv-player/mpv",
                text: nil
            )
        )
        return items
    }

    private var attributionItems: [LicenseItem] {
        [
            LicenseItem(
                name: String(localized: "Original Hoshi Reader Project"),
                license: "GPLv3",
                url: "https://github.com/Manhhao/Hoshi-Reader",
                text: nil
            ),
            LicenseItem(
                name: "Ankiconnect Android",
                license: "GPLv3",
                url: "https://github.com/KamWithK/AnkiconnectAndroid",
                text: nil
            ),
            LicenseItem(
                name: "Yomitan",
                license: "GPLv3",
                url: "https://github.com/yomidevs/yomitan",
                text: nil
            ),
            LicenseItem(
                name: "ッツ Reader",
                license: "BSD-3",
                url: "https://github.com/ttu-ttu/ebook-reader",
                text: bsdLicenseTtu
            ),
            LicenseItem(
                name: "JMdict for Yomitan",
                license: "CC-BY-SA-4.0",
                url: "https://github.com/yomidevs/jmdict-yomitan",
                text: nil
            ),
            LicenseItem(
                name: "Jiten",
                license: "Apache-2.0",
                url: "https://github.com/Sirush/Jiten",
                text: nil
            ),
            LicenseItem(
                name: "Kanji alive",
                license: "CC-BY-4.0",
                url: "https://github.com/kanjialive/kanji-data-media",
                text: nil
            ),
            LicenseItem(
                name: "Tofugu/WaniKani Audio",
                license: "CC-BY-SA-4.0",
                url: "https://github.com/tofugu/japanese-vocabulary-pronunciation-audio",
                text: nil
            ),
            LicenseItem(
                name: "Kanji Stroke Order Font",
                license: "BSD-3",
                url: "https://www.nihilist.org.uk",
                text: bsdLicenseKanjiStrokeOrders
            )
        ]
    }
}

private struct LicenseItem: Identifiable {
    let name: String
    let license: String
    let url: String
    let text: String?

    var id: String { "\(name)-\(url)" }
}

private struct NativeLicenseRow: View {
    let item: LicenseItem

    var body: some View {
        if let text = item.text {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Link("GitHub", destination: URL(string: item.url)!)
                        .font(.caption)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
                .padding(.leading, 4)
            } label: {
                label
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else {
            Link(destination: URL(string: item.url)!) {
                label
                    .frame(minHeight: 46)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Text(item.name)
                .foregroundStyle(.primary)
            Spacer(minLength: 20)
            NativeSettingsValuePill {
                Text(item.license)
            }
        }
    }
}

private struct LicenseRow: View {
    let name: String
    let license: String
    let url: String
    let text: String?
    
    var body: some View {
        if let text {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Link("GitHub", destination: URL(string: url)!)
                        .font(.caption)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                label
            }
        } else {
            Link(destination: URL(string: url)!) {
                label
            }
        }
    }
    
    private var label: some View {
        HStack {
            Text(name)
            Spacer()
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
