Pod::Spec.new do |s|
  s.name             = 'MKAtmosicDFUWapper'
  s.version          = '0.1.8'
  s.summary          = 'Atmosic DFU wrapper for BLE firmware updates.'
  s.description      = <<-DESC
  Wraps the Atmosic blelib SDK to provide a simple Objective-C interface for OTA firmware updates.
                       DESC
  s.homepage         = 'https://github.com/MOKO-iOS-Base-Library/MKAtmosicDFUWapper'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'lovexiaoxia' => 'aadyx2007@163.com' }
  s.source           = { :git => 'git@github.com:MOKO-iOS-Base-Library/MKAtmosicDFUWapper.git', :tag => s.version.to_s }

  s.ios.deployment_target = '18.0'
  s.swift_versions = ['5.0']

  s.source_files = 'MKAtmosicDFUWapper/Classes/**/*.{swift}'

  s.vendored_frameworks = 'MKAtmosicDFUWapper/Frameworks/blelib.xcframework'

  s.dependency 'SwiftCBOR', '~> 0.6.0'
  s.dependency 'SwiftProtobuf', '~> 1.25.0'

  s.xcconfig = {
    'BUILD_LIBRARY_FOR_DISTRIBUTION' => 'YES'
  }

end
