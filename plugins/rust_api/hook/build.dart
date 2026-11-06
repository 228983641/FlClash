import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }

  final configured = Platform.environment['LIBCLANG_PATH'];
  if (configured != null && configured.isNotEmpty) {
    final directory = Directory(configured);
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return _androidBindgenEnvironment(directory.path, input);
    }
  }

  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return _androidBindgenEnvironment(directory.path, input);
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

Map<String, String> _androidBindgenEnvironment(
  String libclangPath,
  BuildInput input,
) {
  if (!Platform.isWindows) {
    return {'LIBCLANG_PATH': libclangPath};
  }
  final llvmRoot = File.fromUri(
    input.config.code.cCompiler!.compiler,
  ).parent.parent;
  final clangResources = Directory.fromUri(llvmRoot.uri.resolve('lib/clang/'));
  if (!clangResources.existsSync()) {
    return {'LIBCLANG_PATH': libclangPath};
  }
  final resources = clangResources
      .listSync()
      .whereType<Directory>()
      .where(
        (directory) => File.fromUri(
          directory.uri.resolve('include/stdbool.h'),
        ).existsSync(),
      )
      .toList();
  final targetTriple = switch (input.config.code.targetArchitecture) {
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.arm => 'armv7-linux-androideabi',
    Architecture.x64 => 'x86_64-linux-android',
    Architecture.ia32 => 'i686-linux-android',
    _ => null,
  };
  if (targetTriple == null || resources.length != 1) {
    return {'LIBCLANG_PATH': libclangPath};
  }
  final sysroot = Directory.fromUri(
    llvmRoot.uri.resolve('sysroot/'),
  ).path.replaceAll(r'\', '/');
  final includeTriple = targetTriple == 'armv7-linux-androideabi'
      ? 'arm-linux-androideabi'
      : targetTriple;
  final resourcePath = resources.single.path.replaceAll(r'\', '/');
  return {
    'BINDGEN_EXTRA_CLANG_ARGS_${targetTriple.replaceAll('-', '_')}':
        '--sysroot="$sysroot" -I"$sysroot/usr/include/$includeTriple" -resource-dir="$resourcePath"',
    'LIBCLANG_PATH': libclangPath,
  };
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
