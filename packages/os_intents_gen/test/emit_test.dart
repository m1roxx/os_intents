import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:test/test.dart';

Manifest manifest({
  List<IntentSpec> intents = const [],
  List<EntitySpec> entities = const [],
}) =>
    Manifest(source: 'lib/intents.dart', intents: intents, entities: entities);

IntentSpec intent({
  String id = 'addTask',
  String title = 'Add task',
  List<String> phrases = const [],
  ExecutionMode execution = ExecutionMode.foreground,
  List<ParamSpec> params = const [],
  String? systemImageName,
}) => IntentSpec(
  id: id,
  functionName: id,
  title: title,
  execution: execution,
  phrases: phrases,
  params: params,
  systemImageName: systemImageName,
);

ParamSpec param(
  String name, {
  ParamType type = ParamType.string,
  bool required = true,
  String? entityTypeName,
}) => ParamSpec(
  name: name,
  title: name,
  type: type,
  isRequired: required,
  entityTypeName: entityTypeName,
);

void main() {
  group('Dart registry', () {
    test('binds each intent id to its function', () {
      final out = emitDartRegistry(manifest(intents: [intent()]));
      expect(out, contains("'addTask': IntentBinding("));
      expect(out, contains('invoke: (args) => addTask('));
    });

    test('required parameters go through the null check', () {
      final out = emitDartRegistry(
        manifest(
          intents: [
            intent(params: [param('title')]),
          ],
        ),
      );
      expect(out, contains("_require(args['title'] as String?, 'title')"));
    });

    test('optional parameters are passed straight through', () {
      final out = emitDartRegistry(
        manifest(
          intents: [
            intent(params: [param('note', required: false)]),
          ],
        ),
      );
      expect(out, contains("note: args['note'] as String?"));
      expect(out, isNot(contains('_require')));
    });

    test('dates are decoded from epoch millis as UTC', () {
      // MethodChannel cannot carry a DateTime, and ISO strings lose the zone on
      // the Android side, so the wire format is millis.
      final out = emitDartRegistry(
        manifest(
          intents: [
            intent(
              params: [param('due', type: ParamType.dateTime, required: false)],
            ),
          ],
        ),
      );
      expect(out, contains('DateTime.fromMillisecondsSinceEpoch'));
      expect(out, contains('isUtc: true'));
    });

    test('the _require helper is only emitted when something needs it', () {
      final withRequired = manifest(
        intents: [
          intent(params: [param('a')]),
        ],
      );
      final without = manifest(
        intents: [
          intent(params: [param('a', required: false)]),
        ],
      );
      expect(emitDartHelpers(withRequired), contains('T _require<T>'));
      expect(emitDartHelpers(without), isEmpty);
    });

    test('an empty library still produces a usable registry', () {
      final out = emitDartRegistry(manifest());
      expect(out, contains(r'$osIntentsRegistry'));
      expect(out, contains('IntentRegistry(<String, IntentBinding>{})'));
    });
  });

  group('Swift intents', () {
    String intentsFor(Manifest m) =>
        SwiftEmitter(m).emit()['OsIntentsGenerated.swift']!;

    test('foreground intents open the app, others do not', () {
      expect(
        intentsFor(manifest(intents: [intent()])),
        contains('static let openAppWhenRun = true'),
      );
      expect(
        intentsFor(
          manifest(intents: [intent(execution: ExecutionMode.background)]),
        ),
        contains('static let openAppWhenRun = false'),
      );
    });

    test('a static intent answers from the store first', () {
      final out = intentsFor(
        manifest(intents: [intent(execution: ExecutionMode.static_)]),
      );
      expect(out, contains('staticResult(for: "addTask")'));
      // Never the plain foreground path: that would need the app on screen,
      // which defeats the point of a static answer.
      expect(out, isNot(contains('shared.invoke(')));
    });

    test(
      'a static intent falls back to the handler when nothing is stored',
      () {
        // Answering with silence before the app has ever published would look
        // like a broken action to the user.
        final out = intentsFor(
          manifest(intents: [intent(execution: ExecutionMode.static_)]),
        );
        expect(out, contains('invokeBackground('));
      },
    );

    test('required and optional parameters differ by Swift optionality', () {
      final out = intentsFor(
        manifest(
          intents: [
            intent(params: [param('title'), param('note', required: false)]),
          ],
        ),
      );
      expect(out, contains('var title: String\n'));
      expect(out, contains('var note: String?'));
    });

    test('dates are converted to epoch millis on the way out', () {
      final out = intentsFor(
        manifest(
          intents: [
            intent(params: [param('due', type: ParamType.dateTime)]),
          ],
        ),
      );
      expect(out, contains('Int(due.timeIntervalSince1970 * 1000)'));
    });

    test('entities travel as their identifier', () {
      final out = intentsFor(
        manifest(
          intents: [
            intent(
              params: [
                param(
                  'project',
                  type: ParamType.entity,
                  entityTypeName: 'Project',
                ),
              ],
            ),
          ],
        ),
      );
      expect(out, contains('var project: ProjectEntity'));
      expect(out, contains('"project": project.id'));
    });
  });

  group('Swift shortcuts provider', () {
    String shortcutsFor(Manifest m) =>
        SwiftEmitter(m).emit()['OsIntentsShortcuts.swift']!;

    test(r'$app expands to the applicationName placeholder Apple requires', () {
      final out = shortcutsFor(
        manifest(
          intents: [
            intent(phrases: [r'Add a task to $app']),
          ],
        ),
      );
      expect(out, contains(r'"Add a task to \(.applicationName)"'));
    });

    test('intents without phrases produce no provider at all', () {
      // A provider with no shortcuts would still claim the app's single
      // provider slot — see Risk #1b.
      final out = shortcutsFor(manifest(intents: [intent()]));
      expect(out, isNot(contains('struct OsIntentsShortcuts')));
      expect(out, contains('No intent declares phrases'));
    });

    test('falls back to a default glyph', () {
      final out = shortcutsFor(
        manifest(
          intents: [
            intent(phrases: [r'Do it in $app']),
          ],
        ),
      );
      expect(out, contains('systemImageName: "app.badge"'));
    });

    test('quotes in a title cannot break out of the Swift literal', () {
      final out = shortcutsFor(
        manifest(
          intents: [
            intent(title: 'Say "hi"', phrases: [r'Greet in $app']),
          ],
        ),
      );
      expect(out, contains(r'shortTitle: "Say \"hi\""'));
    });
  });

  group('Swift entities', () {
    test('emits a query only when one was declared', () {
      final base = EntitySpec(
        typeName: 'Project',
        dartClassName: 'ProjectEntity',
        idProperty: 'id',
        properties: [
          EntityPropertySpec(
            name: 'name',
            type: ParamType.string,
            isTitle: true,
          ),
        ],
      );
      final without = SwiftEmitter(
        manifest(entities: [base]),
      ).emit()['OsIntentsEntities.swift']!;
      expect(without, isNot(contains('EntityStringQuery')));

      final with_ = SwiftEmitter(
        manifest(
          entities: [
            EntitySpec(
              typeName: base.typeName,
              dartClassName: base.dartClassName,
              idProperty: base.idProperty,
              properties: base.properties,
              hasQuery: true,
              queryClassName: 'ProjectResolver',
            ),
          ],
        ),
      ).emit()['OsIntentsEntities.swift']!;
      expect(with_, contains('struct ProjectQuery: EntityStringQuery'));
      expect(with_, contains('func entities(matching string: String)'));
    });

    test('no entities means no entities file', () {
      expect(
        SwiftEmitter(manifest(intents: [intent()])).emit(),
        isNot(contains('OsIntentsEntities.swift')),
      );
    });
  });

  group('entity parameters', () {
    EntitySpec project({bool hasQuery = true}) => EntitySpec(
      typeName: 'Project',
      dartClassName: 'ProjectEntity',
      idProperty: 'id',
      properties: [
        EntityPropertySpec(name: 'name', type: ParamType.string, isTitle: true),
      ],
      hasQuery: hasQuery,
      queryClassName: hasQuery ? 'ProjectResolver' : null,
    );

    Manifest withEntityParam({bool required = false, bool hasQuery = true}) =>
        manifest(
          intents: [
            intent(
              params: [
                param(
                  'project',
                  type: ParamType.entity,
                  entityTypeName: 'Project',
                  required: required,
                ),
              ],
            ),
          ],
          entities: [project(hasQuery: hasQuery)],
        );

    test('the binding becomes async, because resolving is a call', () {
      final out = emitDartRegistry(withEntityParam());
      expect(out, contains('invoke: (args) async => addTask('));
      expect(
        out,
        contains("project: await _resolveProject(args['project'] as String?)"),
      );
    });

    test('a resolver helper is emitted using the user\'s own EntityQuery', () {
      final out = emitDartHelpers(withEntityParam());
      expect(
        out,
        contains('Future<ProjectEntity?> _resolveProject(String? id)'),
      );
      expect(out, contains('await ProjectResolver().byIds([id])'));
    });

    test('required entity params are null-checked after resolution', () {
      // Resolution can legitimately come back empty — the object may have been
      // deleted since the shortcut was built.
      final out = emitDartRegistry(withEntityParam(required: true));
      expect(out, contains("_require(await _resolveProject("));
    });

    test('no helper is emitted for an entity nobody takes as a parameter', () {
      final out = emitDartHelpers(
        manifest(intents: [intent()], entities: [project()]),
      );
      expect(out, isNot(contains('_resolveProject')));
    });

    test('an entity parameter without an EntityQuery is a build error', () {
      final problems = withEntityParam(hasQuery: false).validateEntityUse();
      expect(problems.single, contains('no @EntityQuery(ProjectEntity)'));
    });

    test('an entity parameter naming an unknown entity is a build error', () {
      final problems = manifest(
        intents: [
          intent(
            params: [
              param('project', type: ParamType.entity, entityTypeName: 'Ghost'),
            ],
          ),
        ],
      ).validateEntityUse();
      expect(problems.single, contains('not declared anywhere'));
    });
  });

  group('background execution', () {
    test('an entrypoint is emitted only when something runs headless', () {
      expect(emitBackgroundEntrypoint(manifest(intents: [intent()])), isEmpty);
      final out = emitBackgroundEntrypoint(
        manifest(intents: [intent(execution: ExecutionMode.background)]),
      );
      expect(out, contains('osIntentsBackgroundEntrypoint'));
      expect(out, contains('OsIntents.installBackground'));
    });

    test("the entrypoint is pinned against tree shaking", () {
      // Nothing in Dart references it, so without the pragma a release build
      // drops it and the engine fails to start with a bare `false`.
      final out = emitBackgroundEntrypoint(
        manifest(intents: [intent(execution: ExecutionMode.background)]),
      );
      expect(out, contains("@pragma('vm:entry-point')"));
    });

    test('the library URI survives merging', () {
      // merge() throws individual sources away; losing this would leave the
      // engine looking in main.dart, where the entrypoint is not.
      final merged = Manifest.merge([
        Manifest(
          source: 'my_app|lib/other.dart',
          intents: [intent(id: 'x')],
        ),
        Manifest(
          source: 'my_app|lib/intents.dart',
          intents: [intent(id: 'y', execution: ExecutionMode.background)],
        ),
      ]);
      expect(merged.entrypointLibraryUri, 'package:my_app/intents.dart');
    });

    test('no URI is offered when nothing runs headless', () {
      final merged = Manifest.merge([
        Manifest(source: 'my_app|lib/intents.dart', intents: [intent()]),
      ]);
      expect(merged.entrypointLibraryUri, isNull);
    });

    test('background intents split across libraries are rejected', () {
      final merged = Manifest.merge([
        Manifest(
          source: 'my_app|lib/a.dart',
          intents: [intent(id: 'x', execution: ExecutionMode.background)],
        ),
        Manifest(
          source: 'my_app|lib/b.dart',
          intents: [intent(id: 'y', execution: ExecutionMode.background)],
        ),
      ]);
      final problems = merged.validateGlobal();
      expect(
        problems.singleWhere((p) => p.contains('more than one library')),
        contains('package:my_app/a.dart'),
      );
    });

    test('background intents route through the engine picker', () {
      final swift = SwiftEmitter(
        manifest(intents: [intent(execution: ExecutionMode.background)]),
      ).emit()['OsIntentsGenerated.swift']!;
      expect(swift, contains('OsIntentsBridge.shared.invokeBackground('));
    });

    test('foreground intents do not', () {
      final swift = SwiftEmitter(
        manifest(intents: [intent()]),
      ).emit()['OsIntentsGenerated.swift']!;
      expect(swift, contains('OsIntentsBridge.shared.invoke('));
      expect(swift, isNot(contains('invokeBackground')));
    });

    test('the setup file is emitted only when needed, and carries the URI', () {
      expect(
        SwiftEmitter(manifest(intents: [intent()])).emit(),
        isNot(contains('OsIntentsBackground.swift')),
      );
      final m = Manifest(
        source: 'my_app|lib/intents.dart',
        intents: [intent(execution: ExecutionMode.background)],
      );
      final out = SwiftEmitter(m).emit()['OsIntentsBackground.swift']!;
      expect(out, contains('@objc(OsIntentsBackgroundSetup)'));
      expect(
        out,
        contains('entrypointLibraryURI = "package:my_app/intents.dart"'),
      );
      expect(out, contains('GeneratedPluginRegistrant.register'));
    });
  });

  group('entity query registration', () {
    EntitySpec project({bool hasQuery = true}) => EntitySpec(
      typeName: 'Project',
      dartClassName: 'ProjectEntity',
      idProperty: 'id',
      properties: [
        EntityPropertySpec(name: 'name', type: ParamType.string, isTitle: true),
        EntityPropertySpec(
          name: 'teamName',
          type: ParamType.string,
          isSubtitle: true,
        ),
      ],
      hasQuery: hasQuery,
      queryClassName: hasQuery ? 'ProjectResolver' : null,
    );

    test('a queryable entity is registered in the registry', () {
      // Nothing in the app calls these — the OS does, before a handler runs —
      // so if they are not registered the feature silently returns nothing.
      final out = emitDartRegistry(
        manifest(intents: [intent()], entities: [project()]),
      );
      expect(out, contains("entities: {"));
      expect(out, contains("'Project': EntityBinding("));
      expect(out, contains('ProjectResolver().byIds(ids)'));
      expect(out, contains('ProjectResolver().matching(query)'));
      expect(out, contains('ProjectResolver().suggested()'));
    });

    test('an entity without a query is not registered', () {
      final out = emitDartRegistry(
        manifest(intents: [intent()], entities: [project(hasQuery: false)]),
      );
      expect(out, isNot(contains('entities: {')));
    });

    test('the encoder matches what the generated Swift reads', () {
      final out = emitDartHelpers(
        manifest(intents: [intent()], entities: [project()]),
      );
      expect(out, contains('Map<String, Object?> _encodeProject('));
      expect(out, contains("'id': e.id,"));
      expect(out, contains("'name': e.name,"));
      expect(out, contains("'teamName': e.teamName,"));

      // Both sides come from one spec; drift here is the bug this guards.
      final swift = SwiftEmitter(
        manifest(intents: [intent()], entities: [project()]),
      ).emit()['OsIntentsEntities.swift']!;
      expect(swift, contains('wire["id"] as? String'));
      expect(swift, contains('wire["name"] as? String'));
      expect(swift, contains('wire["teamName"] as? String'));
    });

    test('the id property is honoured even when it is not called id', () {
      final out = emitDartHelpers(
        manifest(
          intents: [intent()],
          entities: [
            EntitySpec(
              typeName: 'Project',
              dartClassName: 'ProjectEntity',
              idProperty: 'slug',
              properties: [
                EntityPropertySpec(
                  name: 'name',
                  type: ParamType.string,
                  isTitle: true,
                ),
              ],
              hasQuery: true,
              queryClassName: 'ProjectResolver',
            ),
          ],
        ),
      );
      expect(out, contains("'id': e.slug,"));
    });
  });

  group('snippets', () {
    String intentsFor(Manifest m) =>
        SwiftEmitter(m).emit()['OsIntentsGenerated.swift']!;

    IntentSpec snippetIntent({
      ExecutionMode execution = ExecutionMode.background,
    }) => IntentSpec(
      id: 'dueToday',
      functionName: 'dueToday',
      title: 'Tasks due today',
      execution: execution,
      showsSnippet: true,
    );

    test('the return type and the view argument agree', () {
      // Swift fixes perform()'s return type at compile time; declaring
      // ShowsSnippetView without passing a view, or the reverse, does not
      // compile.
      final with_ = intentsFor(manifest(intents: [snippetIntent()]));
      expect(with_, contains('& ShowsSnippetView'));
      expect(
        with_,
        contains('view: OsIntentsSnippetView(wire: outcome.snippet)'),
      );

      final without = intentsFor(manifest(intents: [intent()]));
      expect(without, isNot(contains('ShowsSnippetView')));
      expect(without, isNot(contains('OsIntentsSnippetView')));
    });

    test('a static snippet reads its card from the stored result', () {
      // Storing only the spoken text would leave this path rendering an empty
      // card, which is what the first attempt did.
      final out = intentsFor(
        manifest(intents: [snippetIntent(execution: ExecutionMode.static_)]),
      );
      expect(out, contains('staticResult(for: "dueToday")'));
      expect(out, contains('let outcome = IntentOutcome(wire: stored)'));
      expect(
        out,
        contains('view: OsIntentsSnippetView(wire: outcome.snippet)'),
      );
      expect(out, isNot(contains('wire: nil')));
    });

    test('showsSnippet survives the manifest round trip', () {
      final restored = Manifest.decode(
        manifest(intents: [snippetIntent()]).encode(),
      );
      expect(restored.intents.single.showsSnippet, isTrue);
    });

    test('static intents still need the headless engine, for the fallback', () {
      final m = Manifest(
        source: 'my_app|lib/intents.dart',
        intents: [snippetIntent(execution: ExecutionMode.static_)],
      );
      expect(m.hasBackgroundIntents, isTrue);
      expect(SwiftEmitter(m).emit(), contains('OsIntentsBackground.swift'));
      expect(
        emitBackgroundEntrypoint(m),
        contains("@pragma('vm:entry-point')"),
      );
    });
  });
}
