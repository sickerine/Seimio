#!/usr/bin/env python3
# Copies the app's QML (app/qml, app/Seimio) and the modules standing in for the LG's into the Android build,
# and gives Qt 6 its shaders. The QML writes
# each shader inline as GLSL ES 2 (what the LG's Qt 5.12 takes); Qt 6 takes only a URL to a shader compiled
# with its `qsb`. So each inline fragment shader is written out in Qt 6's form (Vulkan-style GLSL 440: the
# uniforms in one block that starts with qt_Matrix and qt_Opacity, the samplers bound after it), compiled, and
# the literal in the copied QML replaced by the compiled file's address. The app's source stays one shader each.
# The lab server is this Mac at the address it has today (the app is written with .47), as tools/deploy.sh does.
# usage: stage.py <repo> <out dir> <qsb> <lab address>
import pathlib, re, shutil, subprocess, sys

repo, out, qsb, lab = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
shutil.rmtree(out / "app", ignore_errors=True)
for part in ("qml", "Seimio"):
    shutil.copytree(repo / "app" / part, out / "app" / part)
# the modules only the LG has: the Mac previews' stand-ins, with Android's own (android/imports: the window,
# and the player over mpv) in their place where it has one
shutil.rmtree(out / "imports", ignore_errors=True)
shutil.copytree(repo / "tools" / "preview" / "imports" / "Seimio" / "Native", out / "imports" / "Seimio" / "Native")
shutil.copytree(repo / "android" / "imports", out / "imports", dirs_exist_ok=True)
probe = out / "app" / "qml" / "LabProbe.qml"
probe.write_text(probe.read_text().replace("192.168.1.47", lab))

LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"', re.S)
UNIFORM = re.compile(r"^\s*uniform\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+(\w+(?:\[\d+\])?)\s*;.*$", re.M)


def qt6(src):
    body = re.sub(r"^\s*precision\s+\w+\s+\w+\s*;\s*$", "", src, flags=re.M)
    samplers, block = [], []
    for kind, name in UNIFORM.findall(body):
        if kind == "sampler2D": samplers.append(name)
        elif name not in ("qt_Opacity", "qt_Matrix"): block.append(f"    {kind} {name};")
    body = UNIFORM.sub("", body)
    body = re.sub(r"^\s*varying\s+(?:\w+\s+)?vec2\s+qt_TexCoord0\s*;.*$", "", body, flags=re.M)
    body = re.sub(r"\b(lowp|mediump|highp)\s+", "", body)
    body = re.sub(r"\btexture2D\s*\(", "texture(", body).replace("gl_FragColor", "fragColor")
    head = ["#version 440", "layout(location = 0) in vec2 qt_TexCoord0;", "layout(location = 0) out vec4 fragColor;",
            "layout(std140, binding = 0) uniform buf {", "    mat4 qt_Matrix;", "    float qt_Opacity;", *block, "};"]
    head += [f"layout(binding = {i + 1}) uniform sampler2D {n};" for i, n in enumerate(samplers)]
    return "\n".join(head) + "\n" + body


count, failed = 0, []
for qml in sorted((out / "app").rglob("*.qml")):
    text = qml.read_text()
    def swap(m):
        global count
        nonlocal_n[0] += 1
        src = m.group(1).encode().decode("unicode_escape") if "\\" in m.group(1) else m.group(1)
        name = f"{qml.stem}-{nonlocal_n[0]}.frag"
        folder = qml.parent / "shaders"; folder.mkdir(exist_ok=True)
        (folder / name).write_text(qt6(src))
        r = subprocess.run([qsb, "--glsl", "100 es,300 es", "-o", str(folder / (name + ".qsb")), str(folder / name)], capture_output=True, text=True)
        (folder / name).unlink() if r.returncode == 0 else failed.append(f"{qml.relative_to(out)} #{nonlocal_n[0]}: {r.stderr.strip()[:600]}")
        count += 1
        return '"qrc:/' + str((folder / (name + ".qsb")).relative_to(out)) + '"'
    nonlocal_n = [0]
    text = LITERAL.sub(lambda m: swap(m) if "gl_FragColor" in m.group(1) else m.group(0), text)
    qml.write_text(text)

print(f"{count} shaders staged")
if failed:
    print("\n".join(failed)); sys.exit(1)
