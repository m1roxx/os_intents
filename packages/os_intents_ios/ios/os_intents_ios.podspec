#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint os_intents_ios.podspec` to validate before publishing.
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
  s.source_files = 'os_intents_ios/Sources/os_intents_ios/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'os_intents_ios_privacy' => ['os_intents_ios/Sources/os_intents_ios/PrivacyInfo.xcprivacy']}
end
