#
# The CocoaPods half of the macOS support. Swift Package Manager is the path
# Flutter prefers now, but an app that has not migrated still resolves plugins
# through CocoaPods, so both have to exist and describe the same sources.
#
# `source_files` reaches into ios/ through the symlinked Sources directory, for
# the same reason Package.swift does: the two platforms compile the same four
# files, and a copy would be a second thing to keep in step.
#
Pod::Spec.new do |s|
  s.name             = 'os_intents_ios'
  s.version          = '0.1.0'
  s.summary          = 'Apple-platform implementation of os_intents.'
  s.description      = <<-DESC
The runtime half of os_intents on iOS and macOS: the bridge every generated
AppIntent calls into, the headless engine, and the snippet card.
                       DESC
  s.homepage         = 'https://github.com/m1roxx/os_intents'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'm1roxx' => 'nugmanovilyas228@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'os_intents_ios/Sources/os_intents_ios/**/*.swift'
  s.dependency 'FlutterMacOS'

  # Not macOS 13, which is where App Intents starts. Nothing in this pod names
  # an App Intents type — that floor belongs to the generated code, which
  # carries @available for it — so imposing it here would cost it to every app
  # that only wants the runtime.
  s.platform = :osx, '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
