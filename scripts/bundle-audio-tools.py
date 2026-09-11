#!/usr/bin/env python3
"""Copy tools and dylibs from a source-built prefix; remove all non-system paths."""
import pathlib, shutil, subprocess, sys
prefix, bundle = map(lambda x: pathlib.Path(x).resolve(), sys.argv[1:])
tools = bundle / 'Contents/Resources/Tools'
frameworks = bundle / 'Contents/Frameworks'
tools.mkdir(parents=True, exist_ok=True)
frameworks.mkdir(parents=True, exist_ok=True)
copied = {}

def dependencies(path):
    return [line.strip().split(' (')[0] for line in subprocess.check_output(['otool','-L',str(path)],text=True).splitlines()[1:]]

def copy_library(source):
    source=source.resolve()
    if source in copied:return copied[source]
    if not source.is_relative_to(prefix):raise RuntimeError('Dependency outside build prefix: '+str(source))
    dest=frameworks/source.name
    shutil.copy2(source,dest);copied[source]=dest
    rewrite(dest)
    subprocess.run(['install_name_tool','-id','@rpath/'+dest.name,str(dest)],check=True)
    return dest

def rewrite(path):
    for dep in dependencies(path):
        if dep.startswith(('/usr/lib/','/System/Library/')):continue
        if dep.startswith('@'):raise RuntimeError('Unexpected unresolved dependency: '+dep)
        dest=copy_library(pathlib.Path(dep))
        relative=('@loader_path/' if path.parent==frameworks else '@loader_path/../../Frameworks/')+dest.name
        subprocess.run(['install_name_tool','-change',dep,relative,str(path)],check=True)

for name in ['ffmpeg','ffprobe','cd-paranoia']:
    dest=tools/name
    shutil.copy2(prefix/'bin'/name,dest)
    rewrite(dest)
for path in [*frameworks.iterdir(), *tools.iterdir()]:
    for dep in dependencies(path):
        if not dep.startswith(('/usr/lib/','/System/Library/','@loader_path/','@rpath/')):
            raise RuntimeError('Nonportable dependency: '+dep)
    subprocess.run(['codesign','--force','--sign','-',str(path)],check=True)
print('Bundled 3 audio tools and',len(copied),'libraries')
