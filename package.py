import argparse
import configparser
import glob
import os
import shutil
import sys
import zipfile
import tempfile
from argparse import Namespace
from subprocess import check_call
from typing import List, Optional

SCALELIB_VERSION = "0.2.1"
CYCLECLOUD_API_VERSION = "8.1.0"


def build_sdist() -> str:
    cmd = [sys.executable, "setup.py", "sdist", "--formats=zip"]
    check_call(cmd, cwd=os.path.abspath("hpcpack-autoscaler"))
    sdists = glob.glob("hpcpack-autoscaler/dist/cyclecloud-hpcpack-*.zip")
    assert len(sdists) == 1, "Found %d sdist packages, expected 1" % len(sdists)
    path = sdists[0]
    fname = os.path.basename(path)
    dest = os.path.join("libs", fname)
    if os.path.exists(dest):
        os.remove(dest)
    shutil.move(path, dest)
    return fname


def get_cycle_libs(args: Namespace) -> List[str]:
    ret = [build_sdist()]

    scalelib_file = "cyclecloud-scalelib-{}.tar.gz".format(SCALELIB_VERSION)
    cyclecloud_api_file = "cyclecloud_api-{}-py2.py3-none-any.whl".format(
        CYCLECLOUD_API_VERSION
    )

    scalelib_url = "https://github.com/Azure/cyclecloud-scalelib/archive/{}.tar.gz".format(
    # scalelib_url = "https://suzhuhpcshare.blob.core.windows.net/testbuilds/cyclecloud-scalelib-{}.tar.gz".format(
        SCALELIB_VERSION
    )
    print("WARNING: \nWARNING: Downloading CycleCloud API tarball from GridEngine Project until first release...\nWARNING: ")
    cyclecloud_api_url = "https://github.com/Azure/cyclecloud-gridengine/releases/download/2.0.0/cyclecloud_api-8.0.1-py2.py3-none-any.whl"
    to_download = {
        scalelib_file: (args.scalelib, scalelib_url),
        cyclecloud_api_file: (args.cyclecloud_api, cyclecloud_api_url),
    }

    for lib_file in to_download:
        arg_override, url = to_download[lib_file]
        if arg_override:
            if not os.path.exists(arg_override):
                print(arg_override, "does not exist", file=sys.stderr)
                sys.exit(1)
            fname = os.path.basename(arg_override)
            orig = os.path.abspath(arg_override)
            dest = os.path.abspath(os.path.join("libs", fname))
            if orig != dest:
                shutil.copyfile(orig, dest)
            ret.append(fname)
        else:
            dest = os.path.join("libs", lib_file)
            check_call(["curl", "-L", "-k", "-s", "-o", dest, url])
            # PowerShell
            # check_call(["wget", url, "-OutFile", dest])
            ret.append(lib_file)
            print("Downloaded", lib_file, "to")

    return ret


def execute() -> None:
    expected_cwd = os.path.abspath(os.path.dirname(__file__))
    os.chdir(expected_cwd)

    if not os.path.exists("libs"):
        os.makedirs("libs")

    argument_parser = argparse.ArgumentParser(
        "Builds CycleCloud HPC Pack project with all dependencies.\n"
        + "If you don't specify local copies of scalelib or cyclecloud-api they will be downloaded from github."
    )
    argument_parser.add_argument("--scalelib", default=None)
    argument_parser.add_argument("--cyclecloud-api", default=None)
    args = argument_parser.parse_args()

    cycle_libs = get_cycle_libs(args)

    parser = configparser.ConfigParser()
    ini_path = os.path.abspath("project.ini")

    with open(ini_path) as fr:
        parser.read_file(fr)

    version = parser.get("project", "version")
    if not version:
        raise RuntimeError("Missing [project] -> version in {}".format(ini_path))

    if not os.path.exists("dist"):
        os.makedirs("dist")

    zf = zipfile.ZipFile(
        "dist/cyclecloud-hpcpack-pkg-{}.zip".format(version), "w", zipfile.ZIP_DEFLATED
    )

    build_dir = tempfile.mkdtemp("cyclecloud-hpcpack")

    def _add(name: str, path: Optional[str] = None) -> None:
        path = path or name
        print(f"Adding : {name} from {path}")
        zf.write(path, name)

    packages = []
    for dep in cycle_libs:
        dep_path = os.path.abspath(os.path.join("libs", dep))
        #_add(os.path.join("packages", dep), dep_path)
        packages.append(dep_path)

    check_call(['pip', 'download'] + packages, cwd=build_dir)

    print("Using build dir", build_dir)
    for fil in os.listdir(build_dir):
        if fil.startswith("certifi-2019"):
            print("WARNING: Ignoring duplicate certifi {}".format(fil))
            continue
        path = os.path.join(build_dir, fil)
        _add("packages/" + fil, path)

    _add("install.ps1")
    _add("logging.conf", "hpcpack-autoscaler/logging.conf")

if __name__ == "__main__":
    execute()
