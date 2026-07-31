import 'model.dart';

/// Emits the Kotlin that `androidx.appfunctions` reads at compile time.
///
/// The shape is dictated by what the Android probe measured, and it is not the
/// shape of the iOS output (see docs/android.md):
///
///   * `@AppFunction` cannot be a top-level function. Every intent becomes a
///     method on one abstract service class annotated
///     `@AppFunctionServiceEntryPoint`, from which KSP generates the concrete
///     service. So iOS gets one struct per intent; Android gets one class for
///     all of them.
///   * Descriptions come from KDoc, not annotation arguments. Emitting a
///     `description = "..."` would be silently ignored, so the prose has to be
///     real KDoc — including inline per-property KDoc, since class-level
///     `@param` tags are explicitly not read.
///   * A function takes a single `@AppFunctionSerializable` object, not loose
///     arguments, so one params class is synthesised per intent.
class KotlinEmitter {
  KotlinEmitter(this.manifest, {required this.packageName});

  final Manifest manifest;

  /// Application id of the host app; generated code lives in it so the service
  /// is visible to the manifest entry.
  final String packageName;

  static const serviceName = 'OsIntentsAppFunctionService';
  static const xmlFileName = 'os_intents_app_functions';

  /// Only intents the OS can run without a screen are exposed.
  ///
  /// An `Execution.foreground` intent needs an Activity, which an
  /// `AppFunctionService` has no way to provide; offering it to an agent would
  /// produce an action that always fails.
  List<IntentSpec> get exposed =>
      manifest.intents.where((i) => i.needsHeadlessEngine).toList();

  /// File name → contents. Empty when nothing qualifies.
  Map<String, String> emit() {
    if (exposed.isEmpty) return const {};
    return {
      'OsIntentsAppFunctions.kt': _serviceFile(),
      'OsIntentsSetup.kt': _setupFile(),
    };
  }

  String _serviceFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('package $packageName')
      ..writeln()
      ..writeln('import androidx.annotation.RequiresApi')
      ..writeln('import androidx.appfunctions.AppFunction')
      ..writeln('import androidx.appfunctions.AppFunctionSerializable')
      ..writeln('import androidx.appfunctions.AppFunctionService')
      ..writeln('import androidx.appfunctions.AppFunctionServiceEntryPoint')
      ..writeln('import dev.osintents.os_intents_android.OsIntentsBridge')
      ..writeln();

    for (final intent in exposed) {
      b
        ..writeln(_paramsClass(intent))
        ..writeln();
    }

    b
      ..writeln('/** What an os_intents action answers with. */')
      ..writeln('@AppFunctionSerializable(isDescribedByKDoc = true)')
      ..writeln('data class OsIntentsReply(')
      ..writeln('    /** What the assistant should say. */')
      ..writeln('    val spoken: String,')
      ..writeln(')')
      ..writeln();

    // AppFunctionService is @RequiresApi(36); the app itself may target lower.
    b
      ..writeln('/**')
      ..writeln(' * Hosts every action this app exposes to on-device agents.')
      ..writeln(' *')
      ..writeln(' * KSP generates the concrete `$serviceName` from this class,')
      ..writeln(' * along with `$xmlFileName.xml`.')
      ..writeln(' */')
      ..writeln('@RequiresApi(36)')
      ..writeln('@AppFunctionServiceEntryPoint(')
      ..writeln('    serviceName = "$serviceName",')
      ..writeln('    appFunctionXmlFileName = "$xmlFileName",')
      ..writeln(')')
      ..writeln(
        'abstract class BaseOsIntentsAppFunctionService : AppFunctionService() {',
      )
      ..writeln();

    for (final intent in exposed) {
      b
        ..writeln(_function(intent))
        ..writeln();
    }

    b
      ..writeln('    override fun onDestroy() {')
      ..writeln('        OsIntentsBridge.shutdown()')
      ..writeln('        super.onDestroy()')
      ..writeln('    }')
      ..writeln('}');

    return b.toString();
  }

  /// One `@AppFunctionSerializable` class per intent, since a function takes a
  /// single object rather than loose arguments.
  String _paramsClass(IntentSpec i) {
    final b = StringBuffer()
      ..writeln('/** Parameters for "${_escapeDoc(i.title)}". */')
      ..writeln('@AppFunctionSerializable(isDescribedByKDoc = true)')
      ..writeln('data class ${_paramsName(i)}(');

    if (i.params.isEmpty) {
      // A data class needs at least one property, and the platform needs an
      // object to describe. A flag the agent can ignore is the smallest thing
      // that satisfies both.
      b
        ..writeln('    /** Unused; this action takes no input. */')
        ..writeln('    val unused: Boolean = true,');
    }
    for (final p in i.params) {
      b
        ..writeln('    /** ${_escapeDoc(p.description ?? p.title)} */')
        ..writeln('    val ${p.name}: ${_kotlinType(p)},');
    }
    b.write(')');
    return b.toString();
  }

  String _function(IntentSpec i) {
    final b = StringBuffer()
      ..writeln('    /**')
      ..writeln('     * ${_escapeDoc(i.description ?? i.title)}')
      ..writeln('     *')
      ..writeln('     * @param params the values for this action')
      ..writeln('     */')
      ..writeln('    @AppFunction(isDescribedByKDoc = true)')
      ..writeln(
        '    suspend fun ${i.id}(params: ${_paramsName(i)}): OsIntentsReply {',
      );

    if (i.execution == ExecutionMode.static_) {
      // The whole point of Execution.static_: answer from what the app stored,
      // without starting an isolate. Falls through when nothing was published
      // yet — usually a first run, before publishStatic has been called — and
      // running the handler beats answering with silence.
      b
        ..writeln('        val stored = OsIntentsBridge.staticResult(')
        ..writeln('            applicationContext,')
        ..writeln('            "${i.id}",')
        ..writeln('        )')
        ..writeln('        if (stored != null) {')
        ..writeln(
          '            return OsIntentsReply(spoken = stored["spoken"] as? String ?: "")',
        )
        ..writeln('        }');
    }

    b
      ..writeln('        val outcome = OsIntentsBridge.invoke(')
      ..writeln('            context = applicationContext,')
      ..writeln('            id = "${i.id}",');

    if (i.params.isEmpty) {
      b.writeln('            args = emptyMap(),');
    } else {
      b.writeln('            args = mapOf(');
      for (final p in i.params) {
        b.writeln('                "${p.name}" to params.${p.name},');
      }
      b.writeln('            ),');
    }

    b
      ..writeln('        )')
      ..writeln('        return OsIntentsReply(spoken = outcome.spoken ?: "")')
      ..write('    }');
    return b.toString();
  }

  /// Hands the bridge what only the app module can supply.
  ///
  /// Mirrors `OsIntentsBackground.swift`: `GeneratedPluginRegistrant` lives in
  /// the app, so a package cannot reach it.
  String _setupFile() {
    final b = StringBuffer()
      ..writeln(_header)
      ..writeln('package $packageName')
      ..writeln()
      ..writeln('import dev.osintents.os_intents_android.OsIntentsBridge')
      ..writeln('import io.flutter.plugins.GeneratedPluginRegistrant')
      ..writeln()
      ..writeln('/**')
      ..writeln(' * Call once from `Application.onCreate`.')
      ..writeln(' *')
      ..writeln(
        ' * Unlike iOS, where the plugin finds its setup class through the',
      )
      ..writeln(
        ' * ObjC runtime, an AppFunctionService can start with no Activity and',
      )
      ..writeln(
        ' * no plugin registration having happened, so there is nothing to hook.',
      )
      ..writeln(' */')
      ..writeln('object OsIntentsSetup {')
      ..writeln('    fun configure() {');
    final uri = manifest.entrypointLibraryUri;
    if (uri != null) {
      b.writeln('        OsIntentsBridge.entrypointLibraryUri = "$uri"');
    }
    b
      ..writeln(
        '        OsIntentsBridge.pluginRegistrantCallback = { engine ->',
      )
      ..writeln('            GeneratedPluginRegistrant.registerWith(engine)')
      ..writeln('        }')
      ..writeln('    }')
      ..writeln('}');
    return b.toString();
  }

  static String _paramsName(IntentSpec i) =>
      '${i.id[0].toUpperCase()}${i.id.substring(1)}Params';

  /// Kotlin type for a parameter, using the same wire shapes as iOS.
  static String _kotlinType(ParamSpec p) {
    final base = switch (p.type) {
      // Epoch milliseconds, matching the iOS side.
      ParamType.dateTime => 'Long',
      // Entities travel as their identifier; the app resolves them itself.
      ParamType.entity => 'String',
      _ => p.type.kotlin,
    };
    return p.isRequired ? base : '$base?';
  }

  /// KDoc is parsed, so `*/` inside it would end the comment early.
  static String _escapeDoc(String raw) =>
      raw.replaceAll('*/', '* /').replaceAll('\n', ' ').trim();

  static const String _header = '''
// GENERATED BY os_intents — do not edit.
//
// Regenerate with:
//   dart run build_runner build && dart run os_intents sync
''';
}
