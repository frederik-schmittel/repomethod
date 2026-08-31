#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const packageRoot = path.resolve(__dirname, '..');
const packageJson = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));

const lifecycleScripts = {
  install: 'install.sh',
  update: 'update.sh',
  uninstall: 'uninstall.sh',
};

function usage() {
  process.stdout.write(`repomethod ${packageJson.version}

Usage:
  repomethod install [options]
  repomethod update [options]
  repomethod uninstall
  repomethod doctor

Commands use the current Git repository by default. Pass --target <path> to
operate on another repository.

Common options:
  --target <path>       Target repository
  --help                Show this help
  --version             Show the package version

Install options are forwarded to install.sh: --dry-run, --preserve, --backup,
and --force. Update accepts --source <path>.

Compatibility no-ops (accepted, no effect): install/update --offline.
`);
}

function fail(message) {
  process.stderr.write(`[error] ${message}\n`);
  process.exitCode = 1;
}

function findOption(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return null;
  if (!args[index + 1] || args[index + 1].startsWith('--')) {
    throw new Error(`${name} requires a value`);
  }
  return args[index + 1];
}

function gitRoot(startPath) {
  const resolved = path.resolve(startPath);
  const result = spawnSync('git', ['-C', resolved, 'rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error && result.error.code === 'ENOENT') {
    throw new Error('required command not found: git');
  }
  if (result.status !== 0) {
    throw new Error(`target is not a git repository: ${resolved}`);
  }
  return result.stdout.trim();
}

function commandExists(command) {
  const pathEntries = (process.env.PATH || '').split(path.delimiter);
  return pathEntries.some((entry) => {
    if (!entry) return false;
    try {
      fs.accessSync(path.join(entry, command), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function runLifecycle(command, args) {
  const forwarded = [...args];
  if (forwarded.includes('--target')) {
    const targetIndex = forwarded.indexOf('--target');
    forwarded[targetIndex + 1] = gitRoot(findOption(forwarded, '--target'));
  } else {
    forwarded.unshift('--target', gitRoot(process.cwd()));
  }

  const result = spawnSync('bash', [path.join(packageRoot, lifecycleScripts[command]), ...forwarded], {
    cwd: process.cwd(),
    stdio: 'inherit',
  });

  if (result.error) {
    if (result.error.code === 'ENOENT') {
      fail('required command not found: bash');
      return;
    }
    fail(result.error.message);
    return;
  }
  process.exitCode = result.status === null ? 1 : result.status;
}

function sha256(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function sha256Text(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

// Hash of a pointer-block file's marker-delimited content, matching
// lib/pointer.sh's pointer_block_owned check: the bytes strictly between
// the first `<!-- repomethod:begin -->` and `<!-- repomethod:end -->`
// lines, with no trailing newline. Returns null on absent/malformed
// markers so doctor reports drift rather than a false "unchanged".
function pointerBlockHash(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  const begin = lines.indexOf('<!-- repomethod:begin -->');
  const end = lines.indexOf('<!-- repomethod:end -->');
  if (begin === -1 || end === -1 || end <= begin) return null;
  return sha256Text(lines.slice(begin + 1, end).join('\n'));
}

function inspectManifest(target) {
  const manifestPath = path.join(target, '.repomethod', 'manifest.json');
  if (!fs.existsSync(manifestPath)) {
    process.stdout.write('[info] installation: not installed\n');
    return true;
  }

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch {
    fail(`manifest is not valid JSON: ${manifestPath}`);
    return false;
  }
  if (!manifest.files || typeof manifest.files !== 'object' || Array.isArray(manifest.files)) {
    fail(`manifest has no valid files map: ${manifestPath}`);
    return false;
  }

  let modified = 0;
  let missing = 0;
  for (const [relativePath, entry] of Object.entries(manifest.files)) {
    const installedPath = path.resolve(target, relativePath);
    const gitPath = path.join(target, '.git');
    if (
      (installedPath !== target && !installedPath.startsWith(`${target}${path.sep}`))
      || installedPath === gitPath
      || installedPath.startsWith(`${gitPath}${path.sep}`)
    ) {
      modified += 1;
      continue;
    }
    let stat;
    try {
      stat = fs.lstatSync(installedPath);
    } catch (error) {
      if (error.code === 'ENOENT') {
        missing += 1;
        continue;
      }
      throw error;
    }

    let current;
    if (stat.isSymbolicLink()) {
      current = fs.readlinkSync(installedPath);
    } else if (stat.isFile()) {
      const physicalPath = fs.realpathSync(installedPath);
      if (physicalPath !== target && !physicalPath.startsWith(`${target}${path.sep}`)) {
        modified += 1;
        continue;
      }
      // A pointer-block file (AGENTS.md / CLAUDE.md) records the hash of
      // its marker block, not of the whole host-owned file — compare like
      // for like.
      current = entry && entry.source === 'pointer-block'
        ? pointerBlockHash(installedPath)
        : sha256(installedPath);
    } else {
      modified += 1;
      continue;
    }
    if (!entry || current !== entry.sha256) modified += 1;
  }

  const profiles = Array.isArray(manifest.profiles) ? manifest.profiles.join(',') : 'unknown';
  process.stdout.write(`[ok] installation: version ${manifest.version || 'unknown'}; profiles ${profiles}\n`);
  if (manifest.version !== packageJson.version) {
    process.stdout.write(`[warn] repository version differs from CLI ${packageJson.version}; run repomethod update\n`);
  }
  if (modified > 0 || missing > 0) {
    process.stdout.write(`[warn] managed drift: ${modified} modified, ${missing} missing\n`);
  } else {
    process.stdout.write(`[ok] managed files: ${Object.keys(manifest.files).length} unchanged\n`);
  }
  return true;
}

function doctor(args) {
  const allowed = new Set(['--target']);
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (!allowed.has(argument)) throw new Error(`unknown flag: ${argument}`);
    if (!args[index + 1] || args[index + 1].startsWith('--')) {
      throw new Error(`${argument} requires a value`);
    }
    index += 1;
  }

  const required = ['bash', 'git', 'jq', 'find', 'diff'];
  const missing = required.filter((command) => !commandExists(command));
  if (missing.length > 0) {
    fail(`required commands not found: ${missing.join(', ')}`);
    return;
  }

  // lib/common.sh's inherit_errexit fix requires Bash 4.4+ to actually take
  // effect (silently a no-op on older Bash — see its comment); gate on the
  // same minimum here rather than accepting any Bash 4.x.
  const bashVersion = spawnSync('bash', ['-c', 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'], {
    encoding: 'utf8',
  });
  const [bashMajorStr, bashMinorStr] = (bashVersion.stdout || '').split('.');
  const bashMajor = Number.parseInt(bashMajorStr, 10);
  const bashMinor = Number.parseInt(bashMinorStr, 10);
  if (!Number.isInteger(bashMajor) || !Number.isInteger(bashMinor) || bashMajor < 4 || (bashMajor === 4 && bashMinor < 4)) {
    fail('Bash 4.4 or newer is required');
    return;
  }

  const versionFile = fs.readFileSync(path.join(packageRoot, 'VERSION'), 'utf8').trim();
  if (versionFile !== packageJson.version) {
    fail(`package version ${packageJson.version} does not match VERSION ${versionFile}`);
    return;
  }

  const explicitTarget = findOption(args, '--target');
  const target = gitRoot(explicitTarget || process.cwd());
  process.stdout.write(`[ok] repomethod: ${packageJson.version}\n`);
  process.stdout.write(`[ok] target: ${target}\n`);
  process.stdout.write(`[ok] requirements: Bash ${bashMajor}.${bashMinor}, Git, jq, find, diff\n`);
  if (inspectManifest(target)) process.stdout.write('[ok] doctor completed\n');
}

function main() {
  const [command, ...args] = process.argv.slice(2);

  if (!command || command === '--help' || command === '-h') {
    usage();
    return;
  }
  if (command === '--version' || command === '-v') {
    process.stdout.write(`${packageJson.version}\n`);
    return;
  }
  if (args.includes('--help') || args.includes('-h')) {
    usage();
    return;
  }

  try {
    if (Object.hasOwn(lifecycleScripts, command)) {
      runLifecycle(command, args);
      return;
    }
    if (command === 'doctor') {
      doctor(args);
      return;
    }
    throw new Error(`unknown command: ${command}`);
  } catch (error) {
    fail(error.message);
  }
}

main();
