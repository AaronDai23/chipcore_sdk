#
# chipcore_sdk CocoaPods podspec
#
# card_coin 依赖 chipcore_sdk 时，CocoaPods 使用此文件将 iOS 原生代码编译为静态库。
#
Pod::Spec.new do |s|
  s.name             = 'chipcore_sdk'
  s.version          = '1.0.0'
  s.summary          = 'ChipBase hardware wallet Flutter plugin — iOS native'
  s.description      = 'NFC card + blockchain SDK for Chip Base App'
  s.homepage         = 'https://github.com/chipbase/chipcore_sdk'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'ChipBase' => 'dev@chipbase.com' }
  s.source           = { :path => '.' }

  # 同时包含 Classes/（插件入口）和 Runner/（全部原生实现）
  s.source_files = 'Classes/**/*.swift', 'Runner/**/*.swift'
  # 排除 AppDelegate（仅在 Runner app 中需要）
  s.exclude_files = 'Runner/AppDelegate.swift', 'Runner/GeneratedPluginRegistrant.*'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # 依赖与 ChipCoreBlockchainApi.swift 中 import 对应的 Pods
  s.dependency 'CryptoSwift', '~> 1.8'

  # 允许使用 @objc 动态派发
  s.swift_version = '5.0'

  # NFC capability（需要在宿主 app 的 entitlements 开启 Near Field Communication Tag Reading）
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
