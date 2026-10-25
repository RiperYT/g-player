import Foundation

/// A Windows component games commonly need, installed into a space (Wine prefix) on demand.
/// Ids are winetricks verb names, so a component without a native install here goes to winetricks.
public struct RuntimeComponent: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let summary: String
    /// Download size in bytes, rounded, measured on the files winetricks 20260125 pins. Nil when unknown. Some
    /// components share a download (the DirectX ones) or download more through their dependencies; the summary says so.
    public let approximateBytes: Int64?
    /// Installed into every new space, and offered for existing ones.
    public let isBase: Bool
    /// Whose license covers the files that get downloaded.
    public let license: String
}

public enum RuntimeCatalog {
    private static let vc = "Microsoft Visual C++ Redistributable license"
    private static let directX = "Microsoft DirectX End-User Runtime license"
    /// One download (directx_Jun2010_redist.exe, 100 MB) serves all of these.
    private static let sharedDirectX = String(localized: "Shares one 100 MB DirectX download with the other DirectX components.")

    private static func component(_ id: String, _ name: String.LocalizationValue, _ summary: String.LocalizationValue,
                                  _ bytes: Int64?, base: Bool = false, license: String) -> RuntimeComponent {
        RuntimeComponent(id: id, name: String(localized: name), summary: String(localized: summary), approximateBytes: bytes,
                         isBase: base, license: license)
    }

    /// A component named after a product (Visual C++, .NET, PhysX…): the name isn't translated.
    private static func component(_ id: String, verbatim name: String, _ summary: String.LocalizationValue,
                                  _ bytes: Int64?, base: Bool = false, license: String) -> RuntimeComponent {
        RuntimeComponent(id: id, name: name, summary: String(localized: summary), approximateBytes: bytes,
                         isBase: base, license: license)
    }

    /// Base set first, then the on-demand set. G-Player installs the base set itself; the rest goes through winetricks.
    public static let all: [RuntimeComponent] = [
        component("vcrun2022", verbatim: "Visual C++ 2015–2022", "The runtime most games need. 32- and 64-bit. Also stands in for the 2015, 2017 and 2019 runtimes.",
                  39_600_000, base: true, license: vc),
        component("d3dcompiler_47", "DirectX shader compiler", "Compiles shaders for DirectX 11 games.", 8_000_000, base: true,
                  license: "Microsoft DirectX shader compiler license"),
        component("d3dx9", "DirectX 9 helpers", "Extra DirectX 9 libraries older games ask for. \(sharedDirectX)", 100_300_000, license: directX),
        component("d3dx10", "DirectX 10 helpers", "Extra DirectX 10 libraries. \(sharedDirectX)", 100_300_000, license: directX),
        component("d3dx11_43", "DirectX 11 helpers", "Extra DirectX 11 libraries. \(sharedDirectX)", 100_300_000, license: directX),
        component("d3dcompiler_43", "DirectX shader compiler 43", "For games built with the 2010 DirectX kit. \(sharedDirectX)", 100_300_000, license: directX),
        component("xact", "XACT audio", "The sound engine of many XNA and DirectX games. \(sharedDirectX)", 100_300_000, license: directX),
        component("xinput", "Xbox controller input", "Controller support for older games. \(sharedDirectX)", 100_300_000, license: directX),
        component("dotnet48", verbatim: ".NET Framework 4.8", "For games and launchers built on .NET. Installs .NET 4.0 first. Large and slow.", 123_200_000,
                  license: "Microsoft .NET Framework license"),
        component("physx", verbatim: "NVIDIA PhysX", "Physics for games that ask for the PhysX runtime.", 29_400_000,
                  license: "NVIDIA PhysX System Software license"),
        component("xna40", verbatim: "XNA Framework 4.0", "For games built with XNA. Installs .NET 4.0 too.", 57_500_000,
                  license: "Microsoft XNA Framework Redistributable license"),
        component("openal", verbatim: "OpenAL", "3D audio library some games need.", 600_000, license: "Creative Labs OpenAL installer license"),
        component("mfc140", verbatim: "Visual C++ 2015 MFC", "For programs built with Visual C++ 2015 and MFC.", 29_800_000, license: vc),
        component("vcrun2013", verbatim: "Visual C++ 2013", "For games built with Visual Studio 2013.", 13_700_000, license: vc),
        component("vcrun2010", verbatim: "Visual C++ 2010", "For games built with Visual Studio 2010.", 10_800_000, license: vc),
        component("vcrun2008", verbatim: "Visual C++ 2008", "For games built with Visual Studio 2008.", 9_700_000, license: vc),
        component("corefonts", "Microsoft core fonts", "Arial, Times New Roman, Verdana and friends.", 3_900_000,
                  license: "Microsoft core fonts EULA"),
        component("cjkfonts", "CJK fonts", "Chinese, Japanese and Korean text.", 107_500_000,
                  license: "SIL Open Font License (Source Han Sans, GNU Unifont)"),
    ]

    /// Installed into every new space.
    public static let base: [RuntimeComponent] = all.filter(\.isBase)

    public static func component(_ id: String) -> RuntimeComponent? { all.first { $0.id == id } }

    /// Windows DLL → the runtime component that provides it.
    static let componentForDLL: [(prefix: String, component: String)] = [
        ("msvcp140", "vcrun2022"), ("vcruntime140", "vcrun2022"), ("concrt140", "vcrun2022"), ("vcomp140", "vcrun2022"),
        ("mfc140", "mfc140"),
        ("msvcp120", "vcrun2013"), ("msvcr120", "vcrun2013"),
        ("msvcp110", "vcrun2012"), ("msvcr110", "vcrun2012"),
        ("msvcp100", "vcrun2010"), ("msvcr100", "vcrun2010"),
        ("msvcp90", "vcrun2008"), ("msvcr90", "vcrun2008"),
        ("d3dx9_", "d3dx9"), ("d3dx10_", "d3dx10"), ("d3dx11_", "d3dx11_43"),
        ("d3dcompiler_43", "d3dcompiler_43"), ("d3dcompiler_47", "d3dcompiler_47"),
        ("xinput1_", "xinput"), ("xaudio2_", "xact"), ("x3daudio1_", "xact"), ("xactengine", "xact"),
        ("physxloader", "physx"), ("physx3", "physx"), ("physxcudart", "physx"),
        ("openal32", "openal"), ("mscoree", "dotnet48"), ("xnafx40", "xna40"),
    ]

    /// The component that provides a Windows DLL (`d3dx9_43.dll` → `d3dx9`), if G-Player knows one.
    public static func component(forDLL dll: String) -> String? {
        let name = dll.lowercased()
        return componentForDLL.first { name.hasPrefix($0.prefix) }?.component
    }

    /// Components G-Player installs on its own when a game's files use them. .NET is left out: Wine Mono runs most
    /// .NET games, and Microsoft's .NET is large and replaces it.
    public static func installsByItself(_ id: String) -> Bool { id != "dotnet48" && isInstallable(id) }

    /// Runtimes many older games use, offered in one go when a game doesn't start and the log doesn't say why.
    /// The DirectX parts share one download, so the whole set is about 105 MB.
    public static let commonSet = ["d3dx9", "d3dx11_43", "xact", "xinput", "openal", "corefonts"]

    // MARK: Aliases and what can be installed

    /// Runtimes that the newer one replaces. The 2015, 2017 and 2019 Visual C++ runtimes are one family: the 2015–2022
    /// redistributable installs the same DLLs and is the one Microsoft keeps current (winetricks' own vcrun2019 pin is
    /// stale, because Microsoft replaced the file behind its link).
    private static let aliases = ["vcrun2015": "vcrun2022", "vcrun2017": "vcrun2022", "vcrun2019": "vcrun2022"]

    /// The id to install for `id`: itself, or the runtime that replaces it.
    public static func canonicalID(_ id: String) -> String { aliases[id] ?? id }

    /// Verbs that aren't in the catalog but install cleanly into a 64-bit space (a new-style WoW64 prefix), checked
    /// against winetricks 20260125: every download has a SHA-256 (the hardened script refuses the rest), none is marked
    /// 32-bit only or broken on WoW64, none needs a service pack. The DirectX ones share the catalog's 100 MB download
    /// (or the February 2010 kit's 109 MB) and only unpack files from it.
    private static let installableVerbs: Set<String> = {
        var verbs: Set<String> = [
            // DirectX 2010 kit and February 2010 kit.
            "d3dcompiler_42", "d3dx10_43", "d3dx11_42", "xact_x64",
            "d3dxof", "directplay", "directmusic", "dmband", "dmcompos", "dmime", "dmloader", "dmscript", "dmstyle",
            "dmsynth", "dmusic", "dmusic32", "dsound", "dswave", "l3codecx",
            // Visual C++.
            "vcrun2012", "mfc42", "mfc90", "ucrtbase2019",
            // Fonts.
            "andale", "arial", "comicsans", "courier", "fakechinese", "georgia", "impact", "lucida", "sourcehansans",
            "tahoma", "times", "trebuchet", "verdana", "webdings",
        ]
        for version in 24...43 { verbs.insert("d3dx9_\(version)") }
        return verbs
    }()

    /// Components that fixes ask for and G-Player can't install, with how a note names them. Why (winetricks 20260125):
    ///  - `dgvoodoo2`, `dotnetdesktop10`, `eossdk`, `segoe_script`, `xliveless` aren't winetricks verbs;
    ///  - `ubisoftconnect` downloads its installer without a checksum, which the hardened script always refuses, and so does
    ///    `d3dcompiler_46` with its two files;
    ///  - `dotnet20`, `dotnet20sp2`, `dotnet30`, `dotnet35`, `dotnet35sp1`, `xna31`: installers of old .NET versions that don't
    ///    work in a 64-bit space; `dotnet40`, `dotnet45`, `dotnet462`: winetricks warns they may not fully work there
    ///    (`dotnet48` is offered, and installs `dotnet40` as part of itself); `mdx` needs .NET;
    ///  - `icodecs`: marked broken on new-style WoW64;
    ///  - `crypt32`, `gdiplus`, `msxml3`, `ole32`, `oleaut32`, `usp10` replace Windows' own DLLs with ones taken out of a
    ///    Windows service pack, a 0.5 to 0.9 GB download;
    ///  - `allfonts` installs every font winetricks has.
    /// Said in "Needs …, which G-Player can't install yet.": each name fits after "Needs".
    static let unsupportedNames: [String: String] = [
        "dgvoodoo2": String(localized: "DirectX wrapper dgVoodoo 2", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"), "xliveless": "xliveless", "eossdk": "Epic Online Services",
        "segoe_script": String(localized: "the Segoe Script font", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"), "dotnetdesktop10": ".NET Desktop 10", "ubisoftconnect": "Ubisoft Connect",
        "dotnet20": ".NET 2.0", "dotnet20sp2": ".NET 2.0 SP2", "dotnet30": ".NET 3.0", "dotnet35": ".NET 3.5",
        "dotnet35sp1": ".NET 3.5 SP1", "dotnet40": ".NET 4.0", "dotnet45": ".NET 4.5", "dotnet462": ".NET 4.6.2",
        "xna31": "XNA Framework 3.1", "mdx": "Managed DirectX", "d3dcompiler_46": String(localized: "DirectX shader compiler 46", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"),
        "icodecs": String(localized: "Intel video codecs", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"), "msxml3": "Microsoft XML 3", "gdiplus": "GDI+", "crypt32": String(localized: "the Windows crypto library", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"),
        "ole32": String(localized: "the Windows OLE library", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"), "oleaut32": String(localized: "the Windows OLE automation library", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"),
        "usp10": String(localized: "the Windows text layout library", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"), "allfonts": String(localized: "every Windows font", comment: "Follows “Needs” in “Needs …, which G-Player can't install yet.”"),
    ]

    /// True for ids G-Player can install: the catalog's components (and the ids they stand in for), and the winetricks
    /// verbs in `installableVerbs`. False for everything else, in particular settings such as `win7` or
    /// `hidewineexports=enable` (they aren't components), anything with `=`, and the ids in `unsupportedNames`.
    public static func isInstallable(_ id: String) -> Bool {
        let id = canonicalID(id)
        return component(id) != nil || installableVerbs.contains(id)
    }

    /// How to say a component the user can't get, in plain words.
    public static func plainName(_ id: String) -> String { unsupportedNames[id] ?? component(id)?.name ?? id }

    // MARK: Native installs

    /// How a base component installs without winetricks: what to download, where the files go, which DLLs Wine
    /// should load from the space, and which setup programs to run. Every file is pinned.
    struct NativeRuntime: Sendable {
        enum Arch: Sendable { case x86, x64 }
        struct Copy: Sendable {
            let file: PinnedDownload
            let arch: Arch
            /// Name in `system32` (64-bit) or `syswow64` (32-bit).
            let name: String
        }
        /// Files taken out of a setup program's own cabinet and put into the space before it runs. Wine's built-in
        /// copy has a higher version number, so the setup leaves it alone (bugs.winehq.org/show_bug.cgi?id=57518).
        struct Replacement: Sendable {
            /// Name of the cabinet inside the .exe that holds the DLLs.
            let container: String
            /// What each DLL's name carries inside it (`msvcp140.dll_x86`).
            let suffix: String
            let names: [String]
        }
        struct Setup: Sendable {
            let file: PinnedDownload
            let arch: Arch
            let arguments: [String]
            let replaces: Replacement?
        }
        let id: String
        /// DLLs that go into `HKCU\Software\Wine\DllOverrides`.
        let overrides: [(dll: String, mode: DLLOverrideMode)]
        let copies: [Copy]
        let setups: [Setup]
        /// Native files that must exist afterwards, under `system32` (and `syswow64` where it exists).
        let expected: [String]
        /// Only expected in 64-bit spaces (the 32-bit Visual C++ runtime has no vcruntime140_1).
        let expected64Only: [String]

        var downloads: [PinnedDownload] { copies.map(\.file) + setups.map(\.file) }
    }

    static let native: [String: NativeRuntime] = [vcrun2022.id: vcrun2022, d3dcompiler47.id: d3dcompiler47]

    // Pins copied from winetricks 20260125 (src/winetricks, load_vcrun2022 and load_d3dcompiler_47). Its manual
    // replacement of msvcp140.dll looks for a name the current redistributable no longer uses (`msvcp140.dll_x86`),
    // so here the names and the cabinets that hold them (a10 in the x86 setup, a12 in the x64 one) are spelled out.
    // winetricks fetches the redistributables from aka.ms/vs/17/release/vc_redist.{x86,x64}.exe, a link Microsoft
    // moves to each new release. The URLs below are where those links pointed when the SHA-256 was taken (the
    // file's own hash is in the path), so they keep serving the pinned file. The DLLs come from Mozilla's fxc2
    // repository at the commit that last touched them instead of its moving `master`.
    static let vcrun2022 = NativeRuntime(
        id: "vcrun2022",
        overrides: ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids",
                    "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"].map { ($0, DLLOverrideMode.nativeThenBuiltin) },
        copies: [],
        setups: [
            NativeRuntime.Setup(
                file: PinnedDownload(
                    url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe")!,
                    fileName: "vc_redist.x86.exe",
                    sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64",
                    approximateBytes: 13_953_392),
                arch: .x86, arguments: ["/install", "/quiet", "/norestart"],
                replaces: NativeRuntime.Replacement(container: "a10", suffix: "_x86", names: ["msvcp140.dll"])),
            NativeRuntime.Setup(
                file: PinnedDownload(
                    url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!,
                    fileName: "vc_redist.x64.exe",
                    sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b",
                    approximateBytes: 25_635_768),
                arch: .x64, arguments: ["/install", "/quiet", "/norestart"],
                replaces: NativeRuntime.Replacement(container: "a12", suffix: "_amd64", names: ["msvcp140.dll", "vcruntime140_1.dll"])),
        ],
        expected: ["msvcp140.dll", "vcruntime140.dll"],
        expected64Only: ["vcruntime140_1.dll"])

    static let d3dcompiler47 = NativeRuntime(
        id: "d3dcompiler_47",
        overrides: [("d3dcompiler_47", .native)],
        copies: [
            NativeRuntime.Copy(
                file: PinnedDownload(
                    url: URL(string: "https://raw.githubusercontent.com/mozilla/fxc2/9aba9b11079303d5577e0e3eb455f4d00f3b5946/dll/d3dcompiler_47_32.dll")!,
                    fileName: "d3dcompiler_47_32.dll",
                    sha256: "2ad0d4987fc4624566b190e747c9d95038443956ed816abfd1e2d389b5ec0851",
                    approximateBytes: 3_657_992),
                arch: .x86, name: "d3dcompiler_47.dll"),
            NativeRuntime.Copy(
                file: PinnedDownload(
                    url: URL(string: "https://raw.githubusercontent.com/mozilla/fxc2/9aba9b11079303d5577e0e3eb455f4d00f3b5946/dll/d3dcompiler_47.dll")!,
                    fileName: "d3dcompiler_47_64.dll",
                    sha256: "4432bbd1a390874f3f0a503d45cc48d346abc3a8c0213c289f4b615bf0ee84f3",
                    approximateBytes: 4_346_120),
                arch: .x64, name: "d3dcompiler_47.dll"),
        ],
        setups: [],
        expected: ["d3dcompiler_47.dll"],
        expected64Only: [])
}
