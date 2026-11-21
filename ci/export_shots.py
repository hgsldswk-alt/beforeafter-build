"""Export xcresult attachments and preserve the names tracked by the store listing."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

SHOT = re.compile(r"^(store-(?:zh-Hans|en|zh-Hant)-\d{2}-[a-z]+(?:-[a-z]+)*?|paid-01-paywall)(?=$|[_.])")


def named_paths(manifest):
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            file = attachment.get("exportedFileName", "")
            match = SHOT.match(name)
            if match and Path(file).name == file and file.lower().endswith(".png"):
                yield file, match.group(1) + ".png"


def export(result, folder):
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                    "--output-path", str(folder)], check=True)
    pngs = list(folder.rglob("*.png"))
    if not pngs:
        sys.exit("界面测试没有导出 PNG 截图")
    names = {}
    for manifest in folder.rglob("manifest.json"):
        for source, output in named_paths(json.loads(manifest.read_text(encoding="utf-8"))):
            path = manifest.parent / source
            if path.is_file():
                names[output] = path
    for output, source in names.items():
        canon = folder / output
        if source.resolve() != canon.resolve():
            shutil.copy2(source, canon)
    print(f"已导出 {len(pngs)} 张界面测试截图，其中 {len(names)} 张按附件名生成标准文件名")


if __name__ == "__main__":
    export(sys.argv[1], Path(sys.argv[2]))
