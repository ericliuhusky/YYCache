Pod::Spec.new do |s|
  s.name         = 'YYCache'
  s.summary      = 'High performance cache framework for iOS. (Swift version)'
  s.version      = '1.0.4-swift'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.authors      = { 'ibireme' => 'ibireme@gmail.com' }
  s.social_media_url = 'http://blog.ibireme.com'
  s.homepage     = 'https://github.com/ibireme/YYCache'
  s.platform     = :ios, '9.0'
  s.ios.deployment_target = '9.0'
  s.source       = { :git => 'https://github.com/ibireme/YYCache.git', :tag => s.version.to_s }

  s.requires_arc = true
  s.swift_version = '5.0'
  s.source_files = 'YYCache/*.swift'

  # Swift 版本无需 public_header_files、libraries、frameworks 配置
end
