#!/usr/bin/env python3
"""Configure generated runners. Leaves original logo bytes unchanged."""
from pathlib import Path
import json
def replace(path,old,new):
 p=Path(path);s=p.read_text();p.write_text(s.replace(old,new))
replace('android/app/build.gradle.kts','minSdk = flutter.minSdkVersion','minSdk = 26')
replace('android/app/src/main/AndroidManifest.xml','android:label="rebuild"','android:label="@string/app_name"')
for folder,name in [('values','TallyIsle'),('values-zh','帐屿')]:
 p=Path('android/app/src/main/res')/folder/'strings.xml';p.parent.mkdir(parents=True,exist_ok=True)
 p.write_text('<?xml version="1.0" encoding="utf-8"?>\n<resources><string name="app_name">'+name+'</string></resources>\n')
replace('ios/Runner/Info.plist','<string>Rebuild</string>','<string>TallyIsle</string>')
replace('ios/Runner/Info.plist','<string>rebuild</string>','<string>TallyIsle</string>')
replace('macos/Runner/Configs/AppInfo.xcconfig','PRODUCT_NAME = rebuild','PRODUCT_NAME = TallyIsle')
replace('macos/Runner/Info.plist','<key>CFBundleName</key>','<key>CFBundleDisplayName</key>\n\t<string>TallyIsle</string>\n\t<key>CFBundleName</key>') if '<key>CFBundleDisplayName</key>' not in Path('macos/Runner/Info.plist').read_text() else None
for root in ['ios/Runner','macos/Runner']:
 for lang,name in [('zh-Hans','帐屿'),('en','TallyIsle')]:
  p=Path(root)/(lang+'.lproj')/'InfoPlist.strings';p.parent.mkdir(parents=True,exist_ok=True)
  p.write_text('"CFBundleDisplayName" = "'+name+'";\n"CFBundleName" = "'+name+'";\n')
# Runner build registration of these Apple localization files still needs Xcode validation.
replace('linux/CMakeLists.txt','set(BINARY_NAME "rebuild")','set(BINARY_NAME "tallyisle")')
replace('linux/runner/my_application.cc','"rebuild"','"TallyIsle"')
replace('windows/runner/main.cpp','L"rebuild"','L"TallyIsle"')
for field in ['FileDescription','ProductName']:
 replace('windows/runner/Runner.rc',f'"{field}", "rebuild"',f'"{field}", "TallyIsle"')
replace('web/index.html','<title>rebuild</title>','<title>TallyIsle</title>')
replace('web/index.html','content="rebuild"','content="TallyIsle"')
p=Path('web/manifest.json');m=json.loads(p.read_text());m.update(name='TallyIsle',short_name='TallyIsle',description='帐屿 / TallyIsle')
m['icons']=[i for i in m['icons'] if i.get('purpose')!='maskable'];p.write_text(json.dumps(m,indent=2,ensure_ascii=False)+'\n')
for p in Path('web/icons').glob('Icon-maskable-*'):p.unlink() # generated template artwork, not user source
print('Generated runner names configured; platform display validation remains separate.')
