Pod::Spec.new do |s|
  s.name = 'VhdxNative'
  s.version = '0.6.0'
  s.summary = 'Read-only VHDX, BitLocker and NTFS reader.'
  s.description = 'Rust reader and pinned libyal libraries, built locally for iOS.'
  s.homepage = 'https://github.com/libyal'
  s.license = { :type => 'MIT and LGPL-3.0-or-later', :file => 'Licenses/THIRD_PARTY.md' }
  s.author = 'VHDX Reader contributors'
  s.source = { :path => '.' }
  s.platform = :ios, '15.0'
  s.vendored_frameworks = 'Frameworks/*.xcframework'
  s.resources = 'Licenses'
  s.preserve_paths = 'Frameworks/*.xcframework'
end
