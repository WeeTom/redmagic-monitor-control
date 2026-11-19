#!/usr/bin/env python3
"""Build an Apple Silicon macOS 14+ menu-bar application, without installing it."""
from pathlib import Path
import subprocess,shutil,plistlib,json,hashlib

ROOT=Path(__file__).resolve().parent
BUILD=ROOT/'build';BUILD.mkdir(exist_ok=True)
APP=BUILD/'红魔显示器.app'
if APP.exists():shutil.rmtree(APP)
for d in ('Contents/MacOS','Contents/Resources'):(APP/d).mkdir(parents=True,exist_ok=True)
def run(*args):subprocess.run([str(a) for a in args],check=True,cwd=ROOT)
run('clang','-std=c11','-Os','-Wall','-Wextra','-Werror','-mmacosx-version-min=14.0','-c',ROOT/'core/GMProtocol.c','-o',BUILD/'GMProtocol.o')
objects=[BUILD/'GMProtocol.o']
for source in [ROOT/'native/DDCNative.m',*(ROOT/'third_party/m1ddc/sources'/s for s in ('avservice.m','i2c.m','ioregistry.m'))]:
    obj=BUILD/(source.stem+'.o');objects.append(obj)
    run('clang','-fmodules','-Os','-Wall','-Wextra','-Werror','-mmacosx-version-min=14.0',
        '-I',ROOT/'native','-I',ROOT/'third_party/m1ddc/headers','-c',source,'-o',obj)
run('swiftc','-swift-version','5','-O','-target','arm64-apple-macos14.0','-module-cache-path',BUILD/'module-cache',
    '-import-objc-header',ROOT/'native/Bridge.h',*sorted((ROOT/'macos').glob('*.swift')),*objects,
    '-framework','CoreDisplay','-framework','AppKit','-framework','SwiftUI','-framework','CoreBluetooth','-framework','ServiceManagement',
    '-o',APP/'Contents/MacOS/RedMagicDisplay')
shutil.copy2(ROOT/'LICENSE',APP/'Contents/Resources/LICENSE.txt')
shutil.copy2(ROOT/'third_party/m1ddc/LICENSE',APP/'Contents/Resources/m1ddc-LICENSE.txt')
run('swiftc',ROOT/'assets/Icon.swift','-o',BUILD/'IconBuilder')
run(BUILD/'IconBuilder',BUILD/'AppIcon.iconset')
run('iconutil','-c','icns',BUILD/'AppIcon.iconset','-o',APP/'Contents/Resources/AppIcon.icns')
info={'CFBundleName':'红魔显示器','CFBundleDisplayName':'红魔显示器','CFBundleIdentifier':'com.local.redmagic-display',
      'CFBundleExecutable':'RedMagicDisplay','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.5.2','CFBundleVersion':'8',
      'LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','CFBundleIconFile':'AppIcon',
      'NSBluetoothAlwaysUsageDescription':'通过蓝牙连接你的红魔显示器，切换输入源、读取状态并调节已支持的画面和灯效设置。',
      'NSBluetoothPeripheralUsageDescription':'连接红魔显示器并控制输入源及已支持的设置。'}
with (APP/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
run('codesign','--force','--sign','-',APP)
run('codesign','--verify','--deep','--strict',APP)
manifest={'version':info['CFBundleShortVersionString'],'platform':'Apple Silicon, macOS 14+','app':APP.name,
          'binary_sha256':hashlib.sha256((APP/'Contents/MacOS/RedMagicDisplay').read_bytes()).hexdigest(),
          'ddc_transport':'native persistent IOAV session',
          'channel_reads':'first use, missing values, reconnect, or a throttled input-only check on panel entry','volume_command':'factory C8',
          'firmware_flash_interface_included':False,'volume_limit':100,'volume_requires_positive_query':True,
          'initial_channel':'DDC','restore_last_channel':True,'automatic_transport_fallback':False,'bluetooth_idle_disconnect_seconds':300,'statusbar_icon_only':True}
(BUILD/'build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(str(APP))
