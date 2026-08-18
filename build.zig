const std = @import("std");

const src = "src";

fn boolOption(b: *std.Build, name: []const u8, description: []const u8, default: bool) bool {
    return b.option(bool, name, description) orelse default;
}

fn concat(b: *std.Build, base: []const []const u8, extra: []const []const u8) []const []const u8 {
    const out = b.allocator.alloc([]const u8, base.len + extra.len) catch @panic("OOM");
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

fn x86Target(
    b: *std.Build,
    base: std.Build.ResolvedTarget,
    features: []const std.Target.x86.Feature,
) std.Build.ResolvedTarget {
    var q = base.query;
    q.cpu_features_add = std.Target.x86.featureSet(features);
    return b.resolveTargetQuery(q);
}

fn archFeatureLib(
    b: *std.Build,
    xmrig: *std.Build.Dependency,
    name: []const u8,
    base: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    features: []const std.Target.x86.Feature,
    def: []const u8,
    file: []const u8,
) *std.Build.Step.Compile {
    const f_target = x86Target(b, base, features);
    const m = b.createModule(.{
        .target = f_target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addIncludePath(xmrig.path("src"));
    m.addIncludePath(xmrig.path("src/3rdparty/argon2/lib"));
    m.addCMacro(def, "1");
    m.addCSourceFile(.{ .file = xmrig.path(file), .flags = &.{ "-Wall", "-Wno-strict-aliasing" } });
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = m,
    });
}

fn blake2bFeatureLib(
    b: *std.Build,
    xmrig: *std.Build.Dependency,
    name: []const u8,
    base: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    features: []const std.Target.x86.Feature,
    file: []const u8,
) *std.Build.Step.Compile {
    const f_target = x86Target(b, base, features);
    const m = b.createModule(.{
        .target = f_target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addIncludePath(xmrig.path("src"));
    m.addIncludePath(xmrig.path("src/3rdparty"));
    m.addCSourceFile(.{
        .file = xmrig.path(file),
        .flags = &.{ "-O3", "-ffast-math", "-Wall", "-Wno-strict-aliasing" },
    });
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = m,
    });
}

const Options = struct {
    tls: bool,
    hwloc: bool,
    opencl: bool,
    http: bool,
    use_asm: bool,
    sse4_1: bool,
    avx2: bool,
    vaes: bool,
    benchmark: bool,
    msr: bool,
    dmi: bool,
    env: bool,
    debug_log: bool,
    cn_lite: bool,
    cn_heavy: bool,
    cn_pico: bool,
    cn_femto: bool,
    randomx: bool,
    argon2: bool,
    kawpow: bool,
    ghostrider: bool,
    static_exe: bool,
    no_donation: bool,

    fn init(b: *std.Build) Options {
        return .{
            .tls = boolOption(b, "tls", "Enable TLS support (requires OpenSSL)", true),
            .hwloc = boolOption(b, "hwloc", "Enable hwloc (NUMA) support", false),
            .opencl = boolOption(b, "opencl", "Enable OpenCL backend", true),
            .http = boolOption(b, "http", "Enable HTTP protocol support (client/server)", true),
            .use_asm = boolOption(b, "asm", "Enable ASM PoW implementations", true),
            .sse4_1 = boolOption(b, "sse4_1", "Enable SSE 4.1 for Blake2", true),
            .avx2 = boolOption(b, "avx2", "Enable AVX2 for Blake2", true),
            .vaes = boolOption(b, "vaes", "Enable VAES instructions for CryptoNight", true),
            .benchmark = boolOption(b, "benchmark", "Enable builtin RandomX benchmark and stress test", true),
            .msr = boolOption(b, "msr", "Enable MSR mod & 1st-gen Ryzen fix", true),
            .dmi = boolOption(b, "dmi", "Enable DMI/SMBIOS reader", true),
            .env = boolOption(b, "env", "Enable environment variables support in config file", true),
            .debug_log = boolOption(b, "debug_log", "Enable debug log output", false),
            .cn_lite = boolOption(b, "cn_lite", "Enable CryptoNight-Lite algorithms family", true),
            .cn_heavy = boolOption(b, "cn_heavy", "Enable CryptoNight-Heavy algorithms family", true),
            .cn_pico = boolOption(b, "cn_pico", "Enable CryptoNight-Pico algorithm", true),
            .cn_femto = boolOption(b, "cn_femto", "Enable CryptoNight-UPX2 algorithm", true),
            .randomx = boolOption(b, "randomx", "Enable RandomX algorithms family", true),
            .argon2 = boolOption(b, "argon2", "Enable Argon2 algorithms family", true),
            .kawpow = boolOption(b, "kawpow", "Enable KawPow algorithms family", true),
            .ghostrider = boolOption(b, "ghostrider", "Enable GhostRider algorithm", true),
            .static_exe = boolOption(b, "static", "Build static binary", false),
            .no_donation = boolOption(b, "no_donation", "Disable built-in dev donation", false),
        };
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const opts = Options.init(b);

    const t = target.result;
    const is_win = t.os.tag == .windows;
    const is_x86_64 = t.cpu.arch == .x86_64;
    const want_asm = opts.use_asm and is_x86_64;

    // --------------------------------------------------------------- xmrig dep
    const xmrig = b.dependency("xmrig", .{});
    const xmr_root = xmrig.path(".");

    // ---------------------------------------------------------------- libuv
    const uv_dep = b.dependency("libuv", .{
        .target = target,
        .optimize = optimize,
    });
    const uv = uv_dep.artifact("uv");

    // -------------------------------------------------------------- openssl
    var ssl_artifact: ?*std.Build.Step.Compile = null;
    var ssl_include: ?std.Build.LazyPath = null;
    if (opts.tls) {
        const ssl_dep = b.dependency("openssl", .{
            .target = target,
            .optimize = optimize,
        });
        ssl_artifact = ssl_dep.artifact("openssl");
        ssl_include = ssl_artifact.?.getEmittedIncludeTree();
    }

    // ------------------------------------------------------------ xmrig-asm
    var asm_lib: ?*std.Build.Step.Compile = null;
    if (want_asm) {
        const asm_target = if (is_x86_64) x86Target(b, target, &.{.aes}) else target;
        const asm_mod = b.createModule(.{
            .target = asm_target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        asm_mod.addIncludePath(xmrig.path(src));
        asm_mod.addIncludePath(xmrig.path("src/3rdparty"));
        asm_mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                "src/crypto/common/Assembly.cpp",
                "src/crypto/cn/r/CryptonightR_gen.cpp",
            },
            .flags = &.{
                "-Wall",
                "-fexceptions",
                "-fno-rtti",
                "-Wno-strict-aliasing",
            },
        });
        asm_mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                "src/crypto/cn/asm/cn_main_loop.S",
                "src/crypto/cn/asm/CryptonightR_template.S",
            },
            .language = .assembly_with_preprocessor,
        });
        asm_lib = b.addLibrary(.{
            .name = "xmrig-asm",
            .linkage = .static,
            .root_module = asm_mod,
        });
    }

    // ----------------------------------------------------------------- argon2
    var argon2_lib: ?*std.Build.Step.Compile = null;
    if (opts.argon2 and is_x86_64) {
        const a2_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        a2_mod.addIncludePath(xmrig.path(src));
        a2_mod.addIncludePath(xmrig.path("src/3rdparty/argon2/lib"));
        a2_mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                "src/3rdparty/argon2/lib/argon2.c",
                "src/3rdparty/argon2/lib/core.c",
                "src/3rdparty/argon2/lib/encoding.c",
                "src/3rdparty/argon2/lib/genkat.c",
                "src/3rdparty/argon2/lib/impl-select.c",
                "src/3rdparty/argon2/lib/blake2/blake2.c",
                "src/3rdparty/argon2/arch/x86_64/lib/argon2-arch.c",
            },
            .flags = &.{ "-Wall", "-Wno-strict-aliasing" },
        });
        argon2_lib = b.addLibrary(.{
            .name = "argon2",
            .linkage = .static,
            .root_module = a2_mod,
        });
        a2_mod.linkLibrary(archFeatureLib(b, xmrig, "argon2-sse2", target, optimize, &.{.sse2}, "HAVE_SSE2", "src/3rdparty/argon2/arch/x86_64/lib/argon2-sse2.c"));
        a2_mod.linkLibrary(archFeatureLib(b, xmrig, "argon2-ssse3", target, optimize, &.{.ssse3}, "HAVE_SSSE3", "src/3rdparty/argon2/arch/x86_64/lib/argon2-ssse3.c"));
        a2_mod.linkLibrary(archFeatureLib(b, xmrig, "argon2-xop", target, optimize, &.{.xop}, "HAVE_XOP", "src/3rdparty/argon2/arch/x86_64/lib/argon2-xop.c"));
        a2_mod.linkLibrary(archFeatureLib(b, xmrig, "argon2-avx2", target, optimize, &.{.avx2}, "HAVE_AVX2", "src/3rdparty/argon2/arch/x86_64/lib/argon2-avx2.c"));
        a2_mod.linkLibrary(archFeatureLib(b, xmrig, "argon2-avx512f", target, optimize, &.{ .avx512f, .evex512 }, "HAVE_AVX512F", "src/3rdparty/argon2/arch/x86_64/lib/argon2-avx512f.c"));
    }

    // ------------------------------------------------------------------ ethash
    var ethash_lib: ?*std.Build.Step.Compile = null;
    if (opts.kawpow) {
        const eth_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        eth_mod.addIncludePath(xmrig.path(src));
        eth_mod.addIncludePath(xmrig.path("src/3rdparty"));
        eth_mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                "src/3rdparty/libethash/ethash_internal.c",
                "src/3rdparty/libethash/keccakf800.c",
            },
            .flags = &.{ "-Wall", "-Wno-strict-aliasing" },
        });
        ethash_lib = b.addLibrary(.{
            .name = "ethash",
            .linkage = .static,
            .root_module = eth_mod,
        });
    }

    // --------------------------------------------------------------- ghostrider
    var ghostrider_lib: ?*std.Build.Step.Compile = null;
    if (opts.ghostrider) {
        const gr_target = if (is_x86_64) x86Target(b, target, &.{.aes}) else target;
        const gr_mod = b.createModule(.{
            .target = gr_target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        gr_mod.addIncludePath(xmrig.path(src));
        gr_mod.addIncludePath(xmrig.path("src/3rdparty"));
        gr_mod.addIncludePath(xmrig.path("src/crypto/ghostrider"));
        gr_mod.addIncludePath(uv.getEmittedIncludeTree());
        gr_mod.addCMacro("XMRIG_MINER_PROJECT", "");
        gr_mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                "src/crypto/ghostrider/ghostrider.cpp",
            },
            .flags = &.{
                "-Wall",
                "-fexceptions",
                "-fno-rtti",
                "-Wno-strict-aliasing",
            },
        });
        const sph_flags = &.{ "-Os", "-Wno-unused-parameter", "-Wno-unused-variable" };
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_blake.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_bmw.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_cubehash.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_echo.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_fugue.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_groestl.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_hamsi.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_jh.c"), .flags = &.{ "-Os", "-Wno-unused-parameter", "-Wno-unused-variable", "-fno-tree-vrp" } });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_keccak.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_luffa.c"), .flags = &.{ "-Os", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wno-unused-const-variable" } });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_shabal.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_shavite.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_simd.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_sha2.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_skein.c"), .flags = sph_flags });
        gr_mod.addCSourceFile(.{ .file = xmrig.path("src/crypto/ghostrider/sph_whirlpool.c"), .flags = sph_flags });
        ghostrider_lib = b.addLibrary(.{
            .name = "ghostrider",
            .linkage = .static,
            .root_module = gr_mod,
        });
    }

    // ------------------------------------------------------------- main module
    const mod_target = if (is_x86_64) x86Target(b, target, &.{.aes}) else target;
    const mod = b.createModule(.{
        .target = mod_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    const exe = b.addExecutable(.{
        .name = "xmrig",
        .root_module = mod,
    });

    mod.addIncludePath(xmrig.path(src));
    mod.addIncludePath(xmrig.path("src/3rdparty"));

    if (opts.no_donation) {
        // Satisfy donate.h's include guard so its constexpr defaults are
        // skipped, and supply 0% defaults via macros instead of patching.
        mod.addCMacro("XMRIG_DONATE_H", "");
        mod.addCMacro("kDefaultDonateLevel", "0");
        mod.addCMacro("kMinimumDonateLevel", "0");
    }

    if (ssl_include) |p| mod.addIncludePath(p);

    // -------- defines
    mod.addCMacro("XMRIG_MINER_PROJECT", "");
    mod.addCMacro("XMRIG_JSON_SINGLE_LINE_ARRAY", "");
    mod.addCMacro("__STDC_FORMAT_MACROS", "");
    mod.addCMacro("UNICODE", "");
    mod.addCMacro("_FILE_OFFSET_BITS", "64");
    mod.addCMacro("_CRT_SECURE_NO_WARNINGS", "");
    mod.addCMacro("_CRT_NONSTDC_NO_WARNINGS", "");
    mod.addCMacro("NOMINMAX", "");
    mod.addCMacro("HAVE_ROTR", "");
    mod.addCMacro("XMRIG_64_BIT", "");

    if (is_win) {
        mod.addCMacro("WIN32", "1");
        mod.addCMacro("XMRIG_OS_WIN", "");
        mod.addCMacro("HAVE_ALIGNED_MALLOC", "");
    }

    if (is_x86_64) mod.addCMacro("RAPIDJSON_SSE2", "");
    mod.addCMacro("RAPIDJSON_WRITE_DEFAULT_FLAGS", "6");

    if (opts.cn_lite) mod.addCMacro("XMRIG_ALGO_CN_LITE", "");
    if (opts.cn_heavy) mod.addCMacro("XMRIG_ALGO_CN_HEAVY", "");
    if (opts.cn_pico) mod.addCMacro("XMRIG_ALGO_CN_PICO", "");
    if (opts.cn_femto) mod.addCMacro("XMRIG_ALGO_CN_FEMTO", "");
    if (opts.randomx) mod.addCMacro("XMRIG_ALGO_RANDOMX", "");
    if (opts.argon2) mod.addCMacro("XMRIG_ALGO_ARGON2", "");
    if (opts.kawpow) mod.addCMacro("XMRIG_ALGO_KAWPOW", "");
    if (opts.ghostrider) mod.addCMacro("XMRIG_ALGO_GHOSTRIDER", "");

    if (opts.http) {
        mod.addCMacro("XMRIG_FEATURE_HTTP", "");
        mod.addCMacro("XMRIG_FEATURE_API", "");
    }
    if (opts.tls) mod.addCMacro("XMRIG_FEATURE_TLS", "");
    if (opts.env) mod.addCMacro("XMRIG_FEATURE_ENV", "");
    if (opts.randomx and opts.benchmark) mod.addCMacro("XMRIG_FEATURE_BENCHMARK", "");
    if ((opts.dmi and is_win) or opts.http) mod.addCMacro("XMRIG_FEATURE_DMI", "");
    if (want_asm) mod.addCMacro("XMRIG_FEATURE_ASM", "");
    if (opts.sse4_1 and is_x86_64) mod.addCMacro("XMRIG_FEATURE_SSE4_1", "");
    if (opts.avx2 and is_x86_64) mod.addCMacro("XMRIG_FEATURE_AVX2", "");
    if (opts.vaes) mod.addCMacro("XMRIG_VAES", "");
    if (opts.opencl) {
        mod.addCMacro("XMRIG_FEATURE_OPENCL", "");
        mod.addCMacro("CL_USE_DEPRECATED_OPENCL_1_2_APIS", "");
        mod.addCMacro("CL_TARGET_OPENCL_VERSION", "200");
        mod.addCMacro("XMRIG_STRICT_OPENCL_CACHE", "");
        mod.addCMacro("XMRIG_FEATURE_ADL", "");
    }
    if (opts.msr and is_win) {
        mod.addCMacro("XMRIG_FEATURE_MSR", "");
        mod.addCMacro("XMRIG_FIX_RYZEN", "");
    }
    if (opts.debug_log) mod.addCMacro("APP_DEBUG", "");

    // -------- flags
    const cpp_flags: []const []const u8 = &.{
        "-Wall",
        "-fexceptions",
        "-fno-rtti",
        "-Wno-strict-aliasing",
        "-Wno-date-time",
    };
    const c_flags: []const []const u8 = &.{
        "-Wall",
        "-Wno-strict-aliasing",
        "-Wno-date-time",
    };
    const fast_flags: []const []const u8 = &.{
        "-O3",
        "-ffast-math",
    };

    // -------- base sources
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/3rdparty/fmt/format.cc",
            src ++ "/base/crypto/Algorithm.cpp",
            src ++ "/base/crypto/Coin.cpp",
            src ++ "/base/crypto/keccak.cpp",
            src ++ "/base/crypto/sha3.cpp",
            src ++ "/base/io/Async.cpp",
            src ++ "/base/io/Console.cpp",
            src ++ "/base/io/Env.cpp",
            src ++ "/base/io/json/Json.cpp",
            src ++ "/base/io/json/JsonChain.cpp",
            src ++ "/base/io/json/JsonRequest.cpp",
            src ++ "/base/io/log/backends/ConsoleLog.cpp",
            src ++ "/base/io/log/backends/FileLog.cpp",
            src ++ "/base/io/log/FileLogWriter.cpp",
            src ++ "/base/io/log/Log.cpp",
            src ++ "/base/io/log/Tags.cpp",
            src ++ "/base/io/Signals.cpp",
            src ++ "/base/io/Watcher.cpp",
            src ++ "/base/kernel/Base.cpp",
            src ++ "/base/kernel/config/BaseConfig.cpp",
            src ++ "/base/kernel/config/BaseTransform.cpp",
            src ++ "/base/kernel/config/Title.cpp",
            src ++ "/base/kernel/Entry.cpp",
            src ++ "/base/kernel/Platform.cpp",
            src ++ "/base/kernel/Process.cpp",
            src ++ "/base/net/dns/Dns.cpp",
            src ++ "/base/net/dns/DnsConfig.cpp",
            src ++ "/base/net/dns/DnsRecord.cpp",
            src ++ "/base/net/dns/DnsRecords.cpp",
            src ++ "/base/net/dns/DnsUvBackend.cpp",
            src ++ "/base/net/http/Http.cpp",
            src ++ "/base/net/stratum/BaseClient.cpp",
            src ++ "/base/net/stratum/Client.cpp",
            src ++ "/base/net/stratum/Job.cpp",
            src ++ "/base/net/stratum/NetworkState.cpp",
            src ++ "/base/net/stratum/Pool.cpp",
            src ++ "/base/net/stratum/Pools.cpp",
            src ++ "/base/net/stratum/ProxyUrl.cpp",
            src ++ "/base/net/stratum/Socks5.cpp",
            src ++ "/base/net/stratum/strategies/FailoverStrategy.cpp",
            src ++ "/base/net/stratum/strategies/SinglePoolStrategy.cpp",
            src ++ "/base/net/stratum/Url.cpp",
            src ++ "/base/net/tools/LineReader.cpp",
            src ++ "/base/net/tools/NetBuffer.cpp",
            src ++ "/base/tools/Arguments.cpp",
            src ++ "/base/tools/Chrono.cpp",
            src ++ "/base/tools/cryptonote/BlockTemplate.cpp",
            src ++ "/base/tools/cryptonote/Signatures.cpp",
            src ++ "/base/tools/cryptonote/WalletAddress.cpp",
            src ++ "/base/tools/Cvt.cpp",
            src ++ "/base/tools/String.cpp",
            src ++ "/base/tools/Timer.cpp",
        },
        .flags = cpp_flags,
    });
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/base/tools/cryptonote/crypto-ops-data.c",
            src ++ "/base/tools/cryptonote/crypto-ops.c",
        },
        .flags = c_flags,
    });
    if (is_win) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/base/io/json/Json_win.cpp",
                src ++ "/base/kernel/Platform_win.cpp",
                src ++ "/base/kernel/Process_win.cpp",
            },
            .flags = cpp_flags,
        });
    }

    // -------- http
    if (opts.http) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/3rdparty/llhttp/llhttp.c",
                src ++ "/3rdparty/llhttp/api.c",
                src ++ "/3rdparty/llhttp/http.c",
            },
            .flags = c_flags,
        });
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/base/api/Api.cpp",
                src ++ "/base/api/Httpd.cpp",
                src ++ "/base/api/requests/ApiRequest.cpp",
                src ++ "/base/api/requests/HttpApiRequest.cpp",
                src ++ "/base/net/http/Fetch.cpp",
                src ++ "/base/net/http/HttpApiResponse.cpp",
                src ++ "/base/net/http/HttpClient.cpp",
                src ++ "/base/net/http/HttpContext.cpp",
                src ++ "/base/net/http/HttpData.cpp",
                src ++ "/base/net/http/HttpListener.cpp",
                src ++ "/base/net/http/HttpResponse.cpp",
                src ++ "/base/net/http/HttpServer.cpp",
                src ++ "/base/net/stratum/DaemonClient.cpp",
                src ++ "/base/net/stratum/SelfSelectClient.cpp",
                src ++ "/base/net/tools/TcpServer.cpp",
                src ++ "/hw/api/HwApi.cpp",
            },
            .flags = cpp_flags,
        });
    }

    // -------- tls
    if (opts.tls) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/base/net/stratum/Tls.cpp",
                src ++ "/base/net/tls/ServerTls.cpp",
                src ++ "/base/net/tls/TlsConfig.cpp",
                src ++ "/base/net/tls/TlsContext.cpp",
                src ++ "/base/net/tls/TlsGen.cpp",
            },
            .flags = cpp_flags,
        });
        if (opts.http) {
            mod.addCSourceFiles(.{
                .root = xmr_root,
                .files = &.{
                    src ++ "/base/net/https/HttpsClient.cpp",
                    src ++ "/base/net/https/HttpsContext.cpp",
                    src ++ "/base/net/https/HttpsServer.cpp",
                },
                .flags = cpp_flags,
            });
        }
    }

    if (opts.kawpow or opts.ghostrider) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/base/net/stratum/AutoClient.cpp",
                src ++ "/base/net/stratum/EthStratumClient.cpp",
            },
            .flags = cpp_flags,
        });
    }

    if (opts.randomx and opts.benchmark) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/base/net/stratum/benchmark/BenchClient.cpp",
                src ++ "/base/net/stratum/benchmark/BenchConfig.cpp",
            },
            .flags = cpp_flags,
        });
    }

    // -------- crypto (cn)
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/crypto/cn/c_blake256.c",
            src ++ "/crypto/cn/c_groestl.c",
            src ++ "/crypto/cn/c_jh.c",
            src ++ "/crypto/cn/c_skein.c",
        },
        .flags = c_flags,
    });
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/crypto/cn/CnCtx.cpp",
            src ++ "/crypto/common/HugePagesInfo.cpp",
            src ++ "/crypto/common/MemoryPool.cpp",
            src ++ "/crypto/common/Nonce.cpp",
            src ++ "/crypto/common/VirtualMemory.cpp",
        },
        .flags = cpp_flags,
    });
    mod.addCSourceFile(.{
        .file = xmrig.path(src ++ "/crypto/cn/CnHash.cpp"),
        .flags = concat(b, cpp_flags, fast_flags),
    });
    if (opts.vaes and is_x86_64) {
        const vaes_target = x86Target(b, target, &.{ .avx2, .avx512f, .evex512, .vaes });
        const vaes_mod = b.createModule(.{
            .target = vaes_target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        vaes_mod.addIncludePath(xmrig.path(src));
        vaes_mod.addIncludePath(xmrig.path("src/3rdparty"));
        vaes_mod.addCSourceFile(.{
            .file = xmrig.path(src ++ "/crypto/cn/CryptoNight_x86_vaes.cpp"),
            .flags = cpp_flags,
        });
        vaes_mod.addCSourceFile(.{
            .file = xmrig.path(src ++ "/crypto/randomx/aes_hash_vaes512.cpp"),
            .flags = cpp_flags,
        });
        const vaes_lib = b.addLibrary(.{
            .name = "xmrig-vaes",
            .linkage = .static,
            .root_module = vaes_mod,
        });
        mod.linkLibrary(vaes_lib);
    }
    if (is_win) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/App_win.cpp",
                src ++ "/crypto/common/VirtualMemory_win.cpp",
            },
            .flags = cpp_flags,
        });
    }

    // -------- randomx
    if (opts.randomx) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/crypto/randomx/aes_hash.cpp",
                src ++ "/crypto/randomx/allocator.cpp",
                src ++ "/crypto/randomx/blake2_generator.cpp",
                src ++ "/crypto/randomx/bytecode_machine.cpp",
                src ++ "/crypto/randomx/dataset.cpp",
                src ++ "/crypto/randomx/instructions_portable.cpp",
                src ++ "/crypto/randomx/randomx.cpp",
                src ++ "/crypto/randomx/soft_aes.cpp",
                src ++ "/crypto/randomx/superscalar.cpp",
                src ++ "/crypto/randomx/virtual_machine.cpp",
                src ++ "/crypto/randomx/virtual_memory.cpp",
                src ++ "/crypto/randomx/vm_compiled_light.cpp",
                src ++ "/crypto/randomx/vm_compiled.cpp",
                src ++ "/crypto/randomx/vm_interpreted_light.cpp",
                src ++ "/crypto/randomx/vm_interpreted.cpp",
                src ++ "/crypto/rx/Rx.cpp",
                src ++ "/crypto/rx/RxAlgo.cpp",
                src ++ "/crypto/rx/RxBasicStorage.cpp",
                src ++ "/crypto/rx/RxCache.cpp",
                src ++ "/crypto/rx/RxConfig.cpp",
                src ++ "/crypto/rx/RxDataset.cpp",
                src ++ "/crypto/rx/RxQueue.cpp",
                src ++ "/crypto/rx/RxVm.cpp",
            },
            .flags = cpp_flags,
        });
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/crypto/randomx/blake2/blake2b.c",
                src ++ "/crypto/randomx/reciprocal.c",
            },
            .flags = c_flags,
        });
        if (opts.sse4_1 and is_x86_64) {
            mod.linkLibrary(blake2bFeatureLib(b, xmrig, "xmrig-blake2b-sse41", target, optimize, &.{.sse4_1}, "src/crypto/randomx/blake2/blake2b_sse41.c"));
        }
        if (opts.avx2 and is_x86_64) {
            mod.linkLibrary(blake2bFeatureLib(b, xmrig, "xmrig-blake2b-avx2", target, optimize, &.{.avx2}, "src/crypto/randomx/blake2/avx2/blake2b_avx2.c"));
        }
        if (want_asm) {
            mod.addCSourceFile(.{
                .file = xmrig.path(src ++ "/crypto/randomx/jit_compiler_x86_static.S"),
                .language = .assembly_with_preprocessor,
            });
            mod.addCSourceFile(.{
                .file = xmrig.path(src ++ "/crypto/randomx/jit_compiler_x86.cpp"),
                .flags = concat(b, cpp_flags, &.{ "-Wno-unused-const-variable" }),
            });
        } else {
            mod.addCSourceFile(.{
                .file = xmrig.path(src ++ "/crypto/randomx/jit_compiler_fallback.cpp"),
                .flags = cpp_flags,
            });
        }
        if (opts.msr and is_win) {
            mod.addCSourceFiles(.{
                .root = xmr_root,
                .files = &.{
                    src ++ "/crypto/rx/RxFix_win.cpp",
                    src ++ "/hw/msr/Msr_win.cpp",
                    src ++ "/crypto/rx/RxMsr.cpp",
                    src ++ "/hw/msr/Msr.cpp",
                    src ++ "/hw/msr/MsrItem.cpp",
                },
                .flags = cpp_flags,
            });
        }
    }

    // -------- argon2
    if (opts.argon2) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/crypto/argon2/Impl.cpp",
            },
            .flags = cpp_flags,
        });
        mod.addIncludePath(xmrig.path("src/3rdparty/argon2/lib"));
    }

    // -------- kawpow
    if (opts.kawpow) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/crypto/kawpow/KPCache.cpp",
                src ++ "/crypto/kawpow/KPHash.cpp",
            },
            .flags = cpp_flags,
        });
    }

    // -------- opencl
    if (opts.opencl) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/backend/opencl/cl/OclSource.cpp",
                src ++ "/backend/opencl/generators/ocl_generic_cn_generator.cpp",
                src ++ "/backend/opencl/generators/ocl_vega_cn_generator.cpp",
                src ++ "/backend/opencl/kernels/Cn0Kernel.cpp",
                src ++ "/backend/opencl/kernels/Cn1Kernel.cpp",
                src ++ "/backend/opencl/kernels/Cn2Kernel.cpp",
                src ++ "/backend/opencl/kernels/CnBranchKernel.cpp",
                src ++ "/backend/opencl/OclBackend.cpp",
                src ++ "/backend/opencl/OclCache.cpp",
                src ++ "/backend/opencl/OclConfig.cpp",
                src ++ "/backend/opencl/OclLaunchData.cpp",
                src ++ "/backend/opencl/OclThread.cpp",
                src ++ "/backend/opencl/OclThreads.cpp",
                src ++ "/backend/opencl/OclWorker.cpp",
                src ++ "/backend/opencl/runners/OclBaseRunner.cpp",
                src ++ "/backend/opencl/runners/OclCnRunner.cpp",
                src ++ "/backend/opencl/runners/tools/OclCnR.cpp",
                src ++ "/backend/opencl/runners/tools/OclSharedData.cpp",
                src ++ "/backend/opencl/runners/tools/OclSharedState.cpp",
                src ++ "/backend/opencl/wrappers/OclContext.cpp",
                src ++ "/backend/opencl/wrappers/OclDevice.cpp",
                src ++ "/backend/opencl/wrappers/OclError.cpp",
                src ++ "/backend/opencl/wrappers/OclKernel.cpp",
                src ++ "/backend/opencl/wrappers/OclLib.cpp",
                src ++ "/backend/opencl/wrappers/OclPlatform.cpp",
            },
            .flags = cpp_flags,
        });
        if (is_win) {
            mod.addCSourceFile(.{
                .file = xmrig.path(src ++ "/backend/opencl/OclCache_win.cpp"),
                .flags = cpp_flags,
            });
        }
        if (opts.randomx) {
            mod.addCSourceFiles(.{
                .root = xmr_root,
                .files = &.{
                    src ++ "/backend/opencl/generators/ocl_generic_rx_generator.cpp",
                    src ++ "/backend/opencl/kernels/rx/Blake2bHashRegistersKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/Blake2bInitialHashBigKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/Blake2bInitialHashDoubleKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/Blake2bInitialHashKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/ExecuteVmKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/FillAesKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/FindSharesKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/HashAesKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/InitVmKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/RxJitKernel.cpp",
                    src ++ "/backend/opencl/kernels/rx/RxRunKernel.cpp",
                    src ++ "/backend/opencl/runners/OclRxBaseRunner.cpp",
                    src ++ "/backend/opencl/runners/OclRxJitRunner.cpp",
                    src ++ "/backend/opencl/runners/OclRxVmRunner.cpp",
                },
                .flags = cpp_flags,
            });
        }
        if (opts.kawpow) {
            mod.addCSourceFiles(.{
                .root = xmr_root,
                .files = &.{
                    src ++ "/backend/opencl/generators/ocl_generic_kawpow_generator.cpp",
                    src ++ "/backend/opencl/kernels/kawpow/KawPow_CalculateDAGKernel.cpp",
                    src ++ "/backend/opencl/runners/OclKawPowRunner.cpp",
                    src ++ "/backend/opencl/runners/tools/OclKawPow.cpp",
                },
                .flags = cpp_flags,
            });
        }
        if (is_win) {
            mod.addCSourceFile(.{
                .file = xmrig.path(src ++ "/backend/opencl/wrappers/AdlLib.cpp"),
                .flags = cpp_flags,
            });
        }
    }

    // -------- backend
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/backend/common/Hashrate.cpp",
            src ++ "/backend/common/Threads.cpp",
            src ++ "/backend/common/Worker.cpp",
            src ++ "/backend/common/Workers.cpp",
        },
        .flags = cpp_flags,
    });
    if (opts.randomx and opts.benchmark) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/backend/common/benchmark/Benchmark.cpp",
                src ++ "/backend/common/benchmark/BenchState.cpp",
            },
            .flags = cpp_flags,
        });
    }
    if (opts.opencl) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/backend/common/HashrateInterpolator.cpp",
                src ++ "/backend/common/GpuWorker.cpp",
            },
            .flags = cpp_flags,
        });
    }
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/backend/cpu/Cpu.cpp",
            src ++ "/backend/cpu/CpuBackend.cpp",
            src ++ "/backend/cpu/CpuConfig.cpp",
            src ++ "/backend/cpu/CpuLaunchData.cpp",
            src ++ "/backend/cpu/CpuThread.cpp",
            src ++ "/backend/cpu/CpuThreads.cpp",
            src ++ "/backend/cpu/CpuWorker.cpp",
            src ++ "/backend/cpu/platform/BasicCpuInfo.cpp",
        },
        .flags = cpp_flags,
    });

    // -------- dmi
    if (opts.dmi and is_win) {
        mod.addCSourceFiles(.{
            .root = xmr_root,
            .files = &.{
                src ++ "/hw/dmi/DmiBoard.cpp",
                src ++ "/hw/dmi/DmiMemory.cpp",
                src ++ "/hw/dmi/DmiReader.cpp",
                src ++ "/hw/dmi/DmiReader_win.cpp",
                src ++ "/hw/dmi/DmiTools.cpp",
            },
            .flags = cpp_flags,
        });
    }

    // -------- main
    mod.addCSourceFiles(.{
        .root = xmr_root,
        .files = &.{
            src ++ "/App.cpp",
            src ++ "/core/config/Config.cpp",
            src ++ "/core/config/ConfigTransform.cpp",
            src ++ "/core/Controller.cpp",
            src ++ "/core/Miner.cpp",
            src ++ "/core/Taskbar.cpp",
            src ++ "/net/JobResults.cpp",
            src ++ "/net/Network.cpp",
            src ++ "/net/strategies/DonateStrategy.cpp",
            src ++ "/Summary.cpp",
            src ++ "/xmrig.cpp",
        },
        .flags = cpp_flags,
    });
    if (is_win) {
        mod.addWin32ResourceFile(.{
            .file = xmrig.path("res/app.rc"),
            .include_paths = &.{ xmrig.path("res"), xmrig.path("src") },
        });
    }

    // -------- link
    mod.linkLibrary(uv);
    if (asm_lib) |lib| mod.linkLibrary(lib);
    if (argon2_lib) |lib| mod.linkLibrary(lib);
    if (ethash_lib) |lib| mod.linkLibrary(lib);
    if (ghostrider_lib) |lib| mod.linkLibrary(lib);
    if (ssl_artifact) |lib| mod.linkLibrary(lib);

    if (is_win) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("psapi", .{});
        mod.linkSystemLibrary("iphlpapi", .{});
        mod.linkSystemLibrary("userenv", .{});
        mod.linkSystemLibrary("dbghelp", .{});
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("shell32", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("ntdll", .{});
        mod.linkSystemLibrary("powrprof", .{});
        if (opts.tls) mod.linkSystemLibrary("crypt32", .{});
    }

    if (opts.static_exe) {
        // FIXME: not implemented yet
    }

    b.installArtifact(exe);

    if (is_win) {
        const driver = b.addInstallFileWithDir(xmrig.path("bin/WinRing0/WinRing0x64.sys"), .bin, "WinRing0x64.sys");
        b.getInstallStep().dependOn(&driver.step);
        b.addNamedLazyPath("winring0", xmrig.path("bin/WinRing0/WinRing0x64.sys"));
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run xmrig");
    run_step.dependOn(&run_cmd.step);
}