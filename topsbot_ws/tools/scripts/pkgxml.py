#!/usr/bin/env python3
"""pkgxml.py — shared, comment-safe package.xml queries for the build scripts.

Replaces the various grep/sed/inline-heredoc parses of package.xml: XML
comments must never influence results. (A commented-out
<buildtool_depend>catkin</buildtool_depend> template line once skipped a
whole package from debianization, and commented <depend> lines can leak
dead rosdep keys into sysroot resolution.)

Subcommands:
  name FILE                print the <name> of one package.xml
                           (exit 1 + stderr on parse error / missing name)
  list [--keep-catkin] [--name-only] DIR...
                           print "name dir" (or names only) for every
                           package.xml under DIR (hidden dirs skipped);
                           ROS1 (buildtool_depend catkin) packages are
                           skipped unless --keep-catkin
  dep-keys DIR...          print unique build-time dependency keys across
                           all ROS 2 package.xml under DIR (comment-safe;
                           the tag set matches deps.sh: depend / build_depend
                           / build_export_depend / buildtool_depend /
                           buildtool_export_depend). ROS1 (catkin) packages
                           are skipped: their keys (catkin / roscpp /
                           message_generation) can never resolve in a ROS 2
                           sysroot and only produce rosdep warning noise.

Runs both inside the cross container and on the host (stdlib only).
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ET

BUILD_TAGS = (
    "depend",
    "build_depend",
    "build_export_depend",
    "buildtool_depend",
    "buildtool_export_depend",
)


def parse(path):
    return ET.parse(path).getroot()


def is_ros1(root):
    return any(
        (t.text or "").strip() == "catkin" for t in root.findall("buildtool_depend")
    )


def iter_pkgs(bases, keep_catkin=False):
    """Yield (name, dir, element-root) for each package.xml under bases."""
    for base in bases:
        for r, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            if "package.xml" not in files:
                continue
            path = os.path.join(r, "package.xml")
            try:
                root = parse(path)
            except ET.ParseError as e:
                print(
                    f"pkgxml: WARNING: skipping unparseable {path}: {e}",
                    file=sys.stderr,
                )
                continue
            name = (root.findtext("name") or "").strip()
            if not name:
                print(f"pkgxml: WARNING: no <name> in {path}, skipped", file=sys.stderr)
                continue
            if not keep_catkin and is_ros1(root):
                continue  # ROS1 (catkin) package
            yield name, os.path.dirname(path), root


def cmd_name(args):
    try:
        root = parse(args.file)
    except (ET.ParseError, OSError) as e:
        print(f"pkgxml: {args.file}: {e}", file=sys.stderr)
        return 1
    name = (root.findtext("name") or "").strip()
    if not name:
        print(f"pkgxml: {args.file}: no <name>", file=sys.stderr)
        return 1
    print(name)
    return 0


def cmd_list(args):
    for name, d, _ in iter_pkgs(args.dirs, keep_catkin=args.keep_catkin):
        print(name if args.name_only else f"{name} {d}")
    return 0


def cmd_dep_keys(args):
    keys = set()
    # keep_catkin=False: ROS1 packages are not built here (colcon ignores them
    # via COLCON_IGNORE, package.sh skips catkin), so their ROS1-only keys are
    # unresolvable by definition — collecting them only adds warning noise.
    for _, _, root in iter_pkgs(args.dirs, keep_catkin=False):
        for tag in BUILD_TAGS:
            for el in root.findall(tag):
                v = (el.text or "").strip()
                if v:
                    keys.add(v)
    for k in sorted(keys):
        print(k)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="pkgxml.py", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("name", help="print <name> of one package.xml")
    sp.add_argument("file")
    sp.set_defaults(fn=cmd_name)

    sp = sub.add_parser("list", help="list packages under DIR ...")
    sp.add_argument("--keep-catkin", action="store_true", help="keep ROS1 packages")
    sp.add_argument("--name-only", action="store_true", help="print names only")
    sp.add_argument("dirs", nargs="+")
    sp.set_defaults(fn=cmd_list)

    sp = sub.add_parser("dep-keys", help="unique build-time dependency keys")
    sp.add_argument("dirs", nargs="+")
    sp.set_defaults(fn=cmd_dep_keys)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
