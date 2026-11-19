#!/usr/bin/env python3
"""Build an Apple Silicon macOS 14+ menu-bar application, without installing it."""
from pathlib import Path
import subprocess,shutil,plistlib,json,hashlib
import argparse
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dmg', action='store_true', help='also create a drag-to-install macOS disk image')
options = parser.parse_args()

ROOT=Path(__file__).resolve().parent
BUILD=ROOT/'build';BUILD.mkdir(exist_ok=True)
APP=BUILD/'红魔显示器.app'
if APP.exists():shutil.rmtree(APP)
for d in ('Contents/MacOS','Contents/Resources','Contents/Helpers'):(APP/d).mkdir(parents=True,exist_ok=True)
def run(*args):subprocess.run([str(a) for a in args],check=True,cwd=ROOT)
run('clang','-std=c11','-Os','-Wall','-Wextra','-Werror','-mmacosx-version-min=14.0','-c',ROOT/'core/GMProtocol.c','-o',BUILD/'GMProtocol.o')
objects=[BUILD/'GMProtocol.o']
for source in [ROOT/'native/DDCNative.m',*(ROOT/'third_party/m1ddc/sources'/s for s in ('avservice.m','i2c.m','ioregistry.m'))]:
    obj=BUILD/(source.stem+'.o');objects.append(obj)
    run('clang','-fmodules','-Os','-Wall','-Wextra','-Werror','-mmacosx-version-min=14.0',
        '-I',ROOT/'native','-I',ROOT/'third_party/m1ddc/headers','-c',source,'-o',obj)
swift_compiler=['swiftc','-swift-version','5','-O','-target','arm64-apple-macos14.0','-module-cache-path',BUILD/'module-cache',
               '-import-objc-header',ROOT/'native/Bridge.h']
ddc_link=[*objects,'-framework','CoreDisplay','-framework','AppKit']
runner=APP/'Contents/Helpers/InputShortcutRunner'
run(*swift_compiler,*sorted((ROOT/'shortcut').glob('*.swift')),
    *(ROOT/'macos'/s for s in ('Features.swift','MonitorIdentity.swift','DDC.swift','Bluetooth.swift','BluetoothTransactionLock.swift')),
    *ddc_link,'-framework','CoreBluetooth','-o',runner)
run('codesign','--force','--sign','-',runner)
run(*swift_compiler,*sorted((ROOT/'macos').glob('*.swift')),*ddc_link,
    '-framework','SwiftUI','-framework','CoreBluetooth','-framework','ServiceManagement',
    '-o',APP/'Contents/MacOS/RedMagicDisplay')
shutil.copy2(ROOT/'LICENSE',APP/'Contents/Resources/LICENSE.txt')
shutil.copy2(ROOT/'third_party/m1ddc/LICENSE',APP/'Contents/Resources/m1ddc-LICENSE.txt')
shutil.copytree(ROOT/'assets/donation/qr', APP/'Contents/Resources/Donation')
shutil.copytree(ROOT/'macos/Localizations', APP/'Contents/Resources', dirs_exist_ok=True)
run('swiftc',ROOT/'assets/Icon.swift','-o',BUILD/'IconBuilder')
run(BUILD/'IconBuilder',BUILD/'AppIcon.iconset')
run('iconutil','-c','icns',BUILD/'AppIcon.iconset','-o',APP/'Contents/Resources/AppIcon.icns')
info={'CFBundleName':'红魔显示器','CFBundleDisplayName':'红魔显示器','CFBundleIdentifier':'com.local.redmagic-display',
      'CFBundleExecutable':'RedMagicDisplay','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'16','CFBundleDevelopmentRegion':'en',
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
          'initial_channel':'DDC','restore_last_channel':True,'automatic_transport_fallback':False,'shortcut_bluetooth_fallback':True,
          'bluetooth_idle_disconnect_seconds':300,'statusbar_icon_only':True}
(BUILD/'build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(str(APP))
if options.dmg:
    version = info['CFBundleShortVersionString']
    image = BUILD/f'RedMagicMonitor-{version}-macOS-arm64.dmg'
    with tempfile.TemporaryDirectory(dir=BUILD) as staging:
        stage = Path(staging)
        contents = stage/'disk'
        contents.mkdir()
        run('ditto', APP, contents/APP.name)
        (contents/'Applications').symlink_to('/Applications')
        candidate = stage/image.name
        run('hdiutil', 'create', '-volname', f'REDMAGIC Monitor {version}', '-srcfolder', contents,
            '-fs', 'HFS+', '-format', 'UDZO', candidate)
        run('hdiutil', 'verify', candidate)
        candidate.replace(image)
    print(image)
