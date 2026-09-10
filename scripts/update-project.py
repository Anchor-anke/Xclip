#!/usr/bin/env python3
"""Register feature source files deterministically in the Xclip Xcode project."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
p=root/'src/Xclip.xcodeproj/project.pbxproj'
s=p.read_text()
for path in sorted((root/'src/OneClip').glob('*.swift')):
    name=path.name
    if f'path = {name};' in s: continue
    fid=hashlib.sha1(('file:'+name).encode()).hexdigest()[:24].upper()
    bid=hashlib.sha1(('build:'+name).encode()).hexdigest()[:24].upper()
    s=s.replace('/* End PBXBuildFile section */',f'\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};\n/* End PBXBuildFile section */')
    s=s.replace('/* End PBXFileReference section */',f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    s=s.replace('AA00000029A8B4B700123456 /* OneClipApp.swift */,', f'AA00000029A8B4B700123456 /* OneClipApp.swift */,\n\t\t\t\t{fid} /* {name} */,')
    s=s.replace('AA00000129A8B4B700123456 /* OneClipApp.swift in Sources */,',f'AA00000129A8B4B700123456 /* OneClipApp.swift in Sources */,\n\t\t\t\t{bid} /* {name} in Sources */,')
s=s.replace('PRODUCT_BUNDLE_IDENTIFIER = com.oneclip.app;', 'PRODUCT_BUNDLE_IDENTIFIER = local.cclip.app;')
s=s.replace('GENERATE_INFOPLIST_FILE = YES;', 'GENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tINFOPLIST_FILE = OneClip/Info.plist;')
if '/* InfoPlist.strings */ = {isa = PBXVariantGroup;' not in s:
    variant=hashlib.sha1(b'variant:InfoPlist.strings').hexdigest()[:24].upper()
    build=hashlib.sha1(b'resource:InfoPlist.strings').hexdigest()[:24].upper()
    children=[]
    for language in ['en', 'zh-Hans']:
        fid=hashlib.sha1(('localized:'+language+':InfoPlist.strings').encode()).hexdigest()[:24].upper()
        children.append(fid+' /* '+language+' */')
        entry=f'\t\t{fid} /* {language} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = "{language}"; path = "{language}.lproj/InfoPlist.strings"; sourceTree = "<group>"; }};\n'
        s=s.replace('/* End PBXFileReference section */',entry+'/* End PBXFileReference section */')
    entry=f'\t\t{variant} /* InfoPlist.strings */ = {{isa = PBXVariantGroup; children = ({", ".join(children)},); name = InfoPlist.strings; sourceTree = "<group>"; }};\n'
    s=s.replace('/* Begin PBXProject section */','/* Begin PBXVariantGroup section */\n'+entry+'/* End PBXVariantGroup section */\n\n/* Begin PBXProject section */')
    s=s.replace('/* End PBXBuildFile section */',f'\t\t{build} /* InfoPlist.strings in Resources */ = {{isa = PBXBuildFile; fileRef = {variant} /* InfoPlist.strings */; }};\n/* End PBXBuildFile section */')
    s=s.replace('AA00000429A8B4B800123456 /* Assets.xcassets */,',f'AA00000429A8B4B800123456 /* Assets.xcassets */,\n\t\t\t\t{variant} /* InfoPlist.strings */,')
    s=s.replace('AA00000529A8B4B800123456 /* Assets.xcassets in Resources */,',f'AA00000529A8B4B800123456 /* Assets.xcassets in Resources */,\n\t\t\t\t{build} /* InfoPlist.strings in Resources */,')
    s=s.replace('knownRegions = (\n\t\t\t\ten,','knownRegions = (\n\t\t\t\ten,\n\t\t\t\t"zh-Hans",')
p.write_text(s)
