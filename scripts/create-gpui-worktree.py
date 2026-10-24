#!/usr/bin/env python3
"""Create a migration worktree from the frozen local Whisky + GPUI baseline.

Run with --check to verify the snapshot without creating a branch or worktree.
The source checkout, its branch and its index are left unchanged.

The baseline archive and its checksum live in `.worktree-setup/`, which is
local-only and not version controlled: the archive carries the GPUI demo that
the repository deliberately does not track. Re-create it from a local checkout
that still has `demos/gpui-demo/` before running this script on a fresh clone.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def run(*args, cwd=None):
    return subprocess.run(list(args), cwd=cwd, check=True)


def main():
    source = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--path', type=Path, default=source.parent / 'Whisky-gpui')
    parser.add_argument('--branch', default='gpui-migration')
    args = parser.parse_args()
    target = args.path.expanduser().resolve()
    archive = source / '.worktree-setup/gpui-baseline.tar.gz'
    checksum = (source / '.worktree-setup/archive.sha256').read_text().strip()
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise RuntimeError('Snapshot archive checksum mismatch.')
    run('git', 'check-ref-format', '--branch', args.branch, cwd=source)
    if target.exists():
        raise RuntimeError('Destination already exists: ' + str(target))
    branch_exists = subprocess.run(
        ['git', 'show-ref', '--verify', '--quiet', 'refs/heads/' + args.branch], cwd=source
    ).returncode
    if branch_exists == 0:
        raise RuntimeError('Branch already exists; choose --branch NAME.')
    if branch_exists != 1:
        raise RuntimeError('Unable to inspect the requested branch.')
    with tarfile.open(archive, 'r:gz') as tar:
        manifest_path = 'docs/gpui-migration/BASELINE.json'
        manifest = json.load(tar.extractfile(manifest_path))
        expected = set(manifest['files']) | {manifest_path}
        members = tar.getmembers()
        if set(member.name for member in members) != expected:
            raise RuntimeError('Snapshot members do not match the baseline manifest.')
        for member in members:
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts or not member.isfile():
                raise RuntimeError('Unsafe snapshot entry: ' + member.name)
            if member.name != manifest_path:
                digest = hashlib.sha256(tar.extractfile(member).read()).hexdigest()
                if digest != manifest['files'][member.name]:
                    raise RuntimeError('Snapshot file checksum mismatch: ' + member.name)
        run('git', 'cat-file', '-e', manifest['base_commit'] + '^{commit}', cwd=source)
        print('Verified snapshot:', len(manifest['files']), 'source/resource files', flush=True)
        print('Branch:', args.branch, '\nWorktree:', target, flush=True)
        if args.check:
            print('Check complete. No branch, commit or worktree was created.')
            return
        # Fail before creation if the local machine cannot create commits yet.
        subprocess.run(['git', 'var', 'GIT_AUTHOR_IDENT'], cwd=source,
                       stdout=subprocess.DEVNULL, check=True)
        subprocess.run(['git', 'var', 'GIT_COMMITTER_IDENT'], cwd=source,
                       stdout=subprocess.DEVNULL, check=True)
        run('git', 'worktree', 'add', '-b', args.branch, str(target), manifest['base_commit'], cwd=source)
        for member in members:
            output = target / member.name
            output.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as src, output.open('wb') as dst:
                shutil.copyfileobj(src, dst)
            output.chmod(member.mode)
        for name in manifest['deleted']:
            (target / name).unlink()
        for name, digest in manifest['files'].items():
            if hashlib.sha256((target / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError('Copied file verification failed: ' + name)
        status = target / 'docs/gpui-migration/STATUS.md'
        status.write_text(
            '# GPUI migration starting point\n\n'
            'This worktree contains a snapshot of the current Whisky source and GPUI app. '
            'No production migration has started.\n\n'
            'Read `apps/whisky-gpui/README.md` before implementation. '
            'The source-file hashes and original parent commit are in `BASELINE.json`.\n\n'
            'Demo status: native compilation/linking with cached dependencies passed; '
            'the newly added settings screens have not completed GUI acceptance. '
            'Cargo dependency resolution has a known optional-backend conflict. '
            'Freeze the user-accepted visual baseline before migrating.\n', encoding='utf-8')
        staged = sorted(expected | set(manifest['deleted']) | {'docs/gpui-migration/STATUS.md'})
        run('git', 'add', '--', *staged, cwd=target)
        run('git', 'commit', '-m', 'chore: snapshot Whisky and GPUI demo for migration', cwd=target)
        run('git', 'status', '--short', cwd=target)
        commit = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=target).decode().strip()
        print('\nReady:', target, '\nBranch:', args.branch, '\nBaseline commit:', commit)
        print('Start the migration agent in this worktree and send it the constraints '
              'from `apps/whisky-gpui/README.md`.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError) as exc:
        print('Worktree setup stopped: ' + str(exc), file=sys.stderr)
        print('If creation already started, its files are preserved for inspection; nothing is deleted.',
              file=sys.stderr)
        sys.exit(1)
