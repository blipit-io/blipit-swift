Pod::Spec.new do |s|
  s.name = "BlipitSwift"
  s.version = "0.5.1"
  s.summary = "Blipit error monitoring for iOS, macOS, tvOS and watchOS, on blipit-nuggets."
  s.homepage = "https://docs.blipit.io/mobile"
  s.license = { :type => "MIT" }
  s.author = { "Louward Labs" => "support@blipit.io" }
  s.source = { :git => "https://github.com/blipit-io/blipit-swift.git", :tag => s.version.to_s }
  s.ios.deployment_target = "13.0"
  s.osx.deployment_target = "10.15"
  s.tvos.deployment_target = "13.0"
  s.watchos.deployment_target = "6.0"
  s.swift_version = "5.9"
  s.source_files = "Sources/BlipitSwift/**/*.swift", "Sources/BlipitNuggets/**/*.{c,h}"
  s.public_header_files = "Sources/BlipitNuggets/include/*.h"
  s.resource_bundles = { "BlipitSwiftPrivacy" => ["Sources/BlipitSwift/PrivacyInfo.xcprivacy"] }
end
