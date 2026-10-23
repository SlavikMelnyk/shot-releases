# CandleLab installer for Windows (PowerShell 5.1 or newer). One command, nothing to install first:
#
#     irm https://github.com/SlavikMelnyk/shot-releases/releases/latest/download/install.ps1 | iex
#
# What it does: finds a Node.js 24 or newer (or, if there is none, downloads the official portable Node.js into the install folder and checks it against the published
# SHASUMS256.txt), downloads the newest CandleLab release, VERIFIES its ed25519 signature and SHA-256 before unpacking anything, installs into %LOCALAPPDATA%\SHOT (no administrator
# rights), creates Start menu and Desktop shortcuts, starts CandleLab and opens your browser. Run it again to update (your data and settings are kept).
#
# Options (when saved as a file, e.g.  powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun ; with `irm | iex` use the environment instead, e.g.  $env:SHOT_DRY_RUN = 1):
#     -DryRun / SHOT_DRY_RUN=1           show what would happen; downloads and writes nothing
#     -Uninstall / SHOT_UNINSTALL=1      remove the app and the shortcuts; your data stays      (add -DeleteData / SHOT_DELETE_DATA=1 to delete it too)
#     -Dir D / SHOT_HOME                 install folder          -Base URL / SHOT_DIST_URL    where releases are published       -Lang uk|en
#     -NoStart  -NoOpen  -Force          -FromDir DIR  install an unpacked release folder (no download)         SHOT_NODE_MIRROR  (default https://nodejs.org/dist)
#
# Everything runs inside Install-Shot, called on the last line, so a download that is cut short does nothing at all.
param(
  [switch]$DryRun, [switch]$Uninstall, [switch]$DeleteData, [switch]$NoStart, [switch]$NoOpen, [switch]$Force,
  [string]$Dir = '', [string]$Base = '', [string]$Lang = '', [string]$FromDir = ''
)

$ShotPublicKey = ''
$ShotDefaultBase = 'https://github.com/SlavikMelnyk/shot-releases/releases/latest/download'
$ShotNodeMajor = 24
$ShotInstallerVersion = '0.1.28'

$ShotCoreMjs = @'
// The installer core: ONE plain-Node file, no dependencies, that does everything an install, an update and an uninstall of CandleLab need after a Node.js is at hand.
//
// It is embedded into install.sh and install.ps1 (the bootstrap scripts only find or fetch a Node.js and run this file) and shipped inside every release as
// scripts/lib/installer-core.mjs, where `npm run update` (scripts/update.mjs) uses the very same code: one implementation, one set of tests (scripts/installer/core.test.mjs).
//
//   node core.mjs install   [--dir D] [--base URL] [--key HEX] [--from-dir DIR] [--node PATH] [--lang uk|en] [--no-start] [--no-open] [--force] [--dry-run]
//   node core.mjs uninstall [--dir D] [--delete-data] [--lang uk|en] [--dry-run]
//   node core.mjs check     [--base URL] [--key HEX]                      (prints the list of the newest release as JSON)
//
// Trust model (docs/DISTRIBUTION.md): the release list `latest.json` must carry a valid ed25519 signature (`latest.json.sig`) of the release key whose PUBLIC half is built into the
// installer; the archive named in it must have exactly the SHA-256 and size written in it. Nothing is unpacked before both checks pass. Archive paths are validated one by one.
// The user's data (`data/`, `.env`, `runtime/`, `reports/`) is never part of a release and never touched by an update; an uninstall keeps it unless told otherwise.
import { createHash, createPublicKey, verify as cryptoVerify } from 'node:crypto';
import { spawn as nodeSpawn, spawnSync as nodeSpawnSync } from 'node:child_process';
import nodeFs from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32, inflateRawSync } from 'node:zlib';

export const FORMAT = 'shot.release/1';
export const INSTALL_STAMP = '.shot-install.json';
/** Names an update never replaces and a release must never contain: they belong to the person, not to the release. */
export const PROTECTED = Object.freeze(['data', '.env', 'runtime', 'reports', 'logs', INSTALL_STAMP, '.staging', '.old']);
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const LIMITS = Object.freeze({ manifest: 64 * 1024, archive: 400 * 1024 * 1024, files: 60_000, unpacked: 1_500_000_000, file: 400_000_000 });

export class InstallError extends Error {
  constructor(key, vars = {}) { super(key); this.key = key; this.vars = vars; }
}

// ------------------------------------------------------------------------------------------------------------------------------- words
const MSG = {
  en: {
    title: 'CandleLab installer', dry: 'Dry run: nothing is downloaded, written or started.', where: 'Install folder: {dir}', node: 'Node.js: {path} ({version})',
    plan: 'Would fetch {url} and its signature, verify both, then download and verify the archive.', planLocal: 'Would install the release in {dir} (no download).',
    fetching: 'Reading the release list from {url}', signed: 'The release list is signed by the CandleLab release key {keyId}.', unsigned: 'The release is not signed; the download is checked against the SHA-256 in the release list.', latest: 'Newest release: {version} (published {date}).',
    uptodate: 'CandleLab {version} is installed and up to date.', downgrade: 'The installed version ({installed}) is newer than the published one ({latest}). Nothing was changed. Use --force to install it anyway.',
    downloading: 'Downloading CandleLab {version} ({mb} MB)\u2026', checksum: 'The download is complete and its checksum is correct.', unpacking: 'Unpacking\u2026', stopping: 'Stopping the running CandleLab\u2026',
    swapping: 'Putting the new files in place (your data and settings stay untouched)\u2026', installed: 'CandleLab {version} is installed in {dir}', launchers: 'Launchers: {list}',
    starting: 'Starting CandleLab. The browser opens; the first start shows the setup wizard. Real-money trading stays off until you switch it on yourself.',
    startFailed: 'CandleLab is installed, but it did not start. Run the launcher again, or read data/server.log.', manual: 'Start it any time with: {cmd}',
    update: 'Update later: {cmd}', uninstall: 'Uninstall: {cmd}', local: 'Installing from the folder {dir} (no download, no signature check: the folder is what you downloaded).',
    removing: 'Removing the app and the launchers\u2026', removed: 'CandleLab is removed. Your data is still in {dir} (the data folder and the .env file). To delete it as well, run the uninstall again with {flag}.',
    removedAll: 'CandleLab and all its data are removed.', notInstalled: 'No CandleLab installation found in {dir}.',
    'fail.nokey': 'This installer has no release key built in, so it cannot check anything. Nothing was installed.', 'fail.sig': 'The release list is NOT signed by the CandleLab release key. Nothing was installed.',
    'fail.format': 'The release list is damaged or not in a known format. Nothing was installed.', 'fail.hash': 'The downloaded archive does not match the checksum in the signed release list. Nothing was installed.',
    'fail.size': 'The downloaded archive has a different size than the signed release list says. Nothing was installed.', 'fail.net': 'Cannot download {url}: {reason}',
    'fail.node': 'This Node.js ({have}) is older than the release needs ({need}).', 'fail.zip': 'The archive is damaged or unsafe ({reason}). Nothing was installed.',
    'fail.content': 'The archive does not look like a CandleLab release ({reason}). Nothing was installed.', 'fail.dir': 'Cannot use the install folder {dir}: {reason}',
    'fail.local': 'The folder {dir} is not an unpacked CandleLab release (no VERSION file).', 'fail.url': 'The release address is not acceptable: {url}',
    'fail.notempty': 'The folder {dir} is not empty and is not a CandleLab install, so nothing was changed. Choose an empty folder (or none: the default is used).', 'fail.unsafe': 'Refusing to use {dir}: it is your home folder, the root of a disk, or contains your home folder.',
    sourceCheckout: 'This is a source checkout, not an installed release. Update it with git pull, then run: node scripts/setup.mjs', noBase: 'No release address is configured. Set SHOT_DIST_URL, or baseUrl in config/release.public.json.',
    checkNew: 'An update is available: {current} -> {latest}. Install it with: {cmd}', checkSame: 'CandleLab {current} is the newest release.',
  },
  uk: {
    title: '\u0412\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044f CandleLab', dry: '\u041f\u0440\u043e\u0431\u043d\u0438\u0439 \u0437\u0430\u043f\u0443\u0441\u043a: \u043d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0443\u0454\u0442\u044c\u0441\u044f, \u043d\u0435 \u0437\u0430\u043f\u0438\u0441\u0443\u0454\u0442\u044c\u0441\u044f \u0439 \u043d\u0435 \u0437\u0430\u043f\u0443\u0441\u043a\u0430\u0454\u0442\u044c\u0441\u044f.', where: '\u041f\u0430\u043f\u043a\u0430 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044f: {dir}', node: 'Node.js: {path} ({version})',
    plan: '\u0417\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0438\u0432 \u0431\u0438 {url} \u0456 \u0439\u043e\u0433\u043e \u043f\u0456\u0434\u043f\u0438\u0441, \u043f\u0435\u0440\u0435\u0432\u0456\u0440\u0438\u0432 \u0431\u0438 \u043e\u0431\u0438\u0434\u0432\u0430, \u043f\u043e\u0442\u0456\u043c \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0438\u0432 \u0431\u0438 \u0439 \u043f\u0435\u0440\u0435\u0432\u0456\u0440\u0438\u0432 \u0430\u0440\u0445\u0456\u0432.', planLocal: '\u0412\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0432 \u0431\u0438 \u0437\u0431\u0456\u0440\u043a\u0443 \u0432 {dir} (\u0431\u0435\u0437 \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0435\u043d\u043d\u044f).',
    fetching: '\u0427\u0438\u0442\u0430\u0454\u043c\u043e \u0441\u043f\u0438\u0441\u043e\u043a \u0437\u0431\u0456\u0440\u043e\u043a \u0437 {url}', signed: '\u0421\u043f\u0438\u0441\u043e\u043a \u0437\u0431\u0456\u0440\u043e\u043a \u043f\u0456\u0434\u043f\u0438\u0441\u0430\u043d\u043e \u043a\u043b\u044e\u0447\u0435\u043c \u0432\u0438\u043f\u0443\u0441\u043a\u0443 CandleLab {keyId}.', unsigned: '\u0417\u0431\u0456\u0440\u043a\u0430 \u043d\u0435 \u043f\u0456\u0434\u043f\u0438\u0441\u0430\u043d\u0430; \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0435\u043d\u043d\u044f \u043f\u0435\u0440\u0435\u0432\u0456\u0440\u044f\u0454\u0442\u044c\u0441\u044f \u0437\u0430 SHA-256 \u0437\u0456 \u0441\u043f\u0438\u0441\u043a\u0443 \u0437\u0431\u0456\u0440\u043e\u043a.', latest: '\u041e\u0441\u0442\u0430\u043d\u043d\u044f \u0437\u0431\u0456\u0440\u043a\u0430: {version} (\u043e\u043f\u0443\u0431\u043b\u0456\u043a\u043e\u0432\u0430\u043d\u043e {date}).',
    uptodate: 'CandleLab {version} \u0443\u0436\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e, \u0446\u0435 \u043d\u0430\u0439\u043d\u043e\u0432\u0456\u0448\u0430 \u0437\u0431\u0456\u0440\u043a\u0430.', downgrade: '\u0412\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0430 \u0432\u0435\u0440\u0441\u0456\u044f ({installed}) \u043d\u043e\u0432\u0456\u0448\u0430 \u0437\u0430 \u043e\u043f\u0443\u0431\u043b\u0456\u043a\u043e\u0432\u0430\u043d\u0443 ({latest}). \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0437\u043c\u0456\u043d\u0435\u043d\u043e. \u0429\u043e\u0431 \u0443\u0441\u0435 \u043e\u0434\u043d\u043e \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0438 \u0457\u0457, \u0434\u043e\u0434\u0430\u0439\u0442\u0435 --force.',
    downloading: '\u0417\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0443\u0454\u043c\u043e CandleLab {version} ({mb} \u041c\u0411)\u2026', checksum: '\u0424\u0430\u0439\u043b \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0435\u043d\u043e \u043f\u043e\u0432\u043d\u0456\u0441\u0442\u044e, \u043a\u043e\u043d\u0442\u0440\u043e\u043b\u044c\u043d\u0430 \u0441\u0443\u043c\u0430 \u043f\u0440\u0430\u0432\u0438\u043b\u044c\u043d\u0430.', unpacking: '\u0420\u043e\u0437\u043f\u0430\u043a\u043e\u0432\u0443\u0454\u043c\u043e\u2026', stopping: '\u0417\u0443\u043f\u0438\u043d\u044f\u0454\u043c\u043e CandleLab, \u0449\u043e \u043f\u0440\u0430\u0446\u044e\u0454\u2026',
    swapping: '\u041a\u043b\u0430\u0434\u0435\u043c\u043e \u043d\u043e\u0432\u0456 \u0444\u0430\u0439\u043b\u0438 \u043d\u0430 \u043c\u0456\u0441\u0446\u0435 (\u0432\u0430\u0448\u0456 \u0434\u0430\u043d\u0456 \u0439 \u043d\u0430\u043b\u0430\u0448\u0442\u0443\u0432\u0430\u043d\u043d\u044f \u043d\u0435 \u0447\u0456\u043f\u0430\u0454\u043c\u043e)\u2026', installed: 'CandleLab {version} \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e \u0432 {dir}', launchers: '\u0417\u0430\u043f\u0443\u0441\u043a\u0430\u0447\u0456: {list}',
    starting: '\u0417\u0430\u043f\u0443\u0441\u043a\u0430\u0454\u043c\u043e CandleLab. \u0412\u0456\u0434\u043a\u0440\u0438\u0454\u0442\u044c\u0441\u044f \u0431\u0440\u0430\u0443\u0437\u0435\u0440; \u043f\u0435\u0440\u0448\u0438\u0439 \u0437\u0430\u043f\u0443\u0441\u043a \u043f\u043e\u043a\u0430\u0436\u0435 \u043c\u0430\u0439\u0441\u0442\u0435\u0440 \u043d\u0430\u043b\u0430\u0448\u0442\u0443\u0432\u0430\u043d\u043d\u044f. \u0422\u043e\u0440\u0433\u0456\u0432\u043b\u044f \u0440\u0435\u0430\u043b\u044c\u043d\u0438\u043c\u0438 \u0433\u0440\u043e\u0448\u0438\u043c\u0430 \u043b\u0438\u0448\u0430\u0454\u0442\u044c\u0441\u044f \u0432\u0438\u043c\u043a\u043d\u0435\u043d\u043e\u044e, \u0434\u043e\u043a\u0438 \u0432\u0438 \u0441\u0430\u043c\u0456 \u0457\u0457 \u043d\u0435 \u0432\u0432\u0456\u043c\u043a\u043d\u0435\u0442\u0435.',
    startFailed: 'CandleLab \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e, \u0430\u043b\u0435 \u0432\u0456\u043d \u043d\u0435 \u0437\u0430\u043f\u0443\u0441\u0442\u0438\u0432\u0441\u044f. \u0417\u0430\u043f\u0443\u0441\u0442\u0456\u0442\u044c \u0439\u043e\u0433\u043e \u0449\u0435 \u0440\u0430\u0437 \u0430\u0431\u043e \u043f\u043e\u0434\u0438\u0432\u0456\u0442\u044c\u0441\u044f data/server.log.', manual: '\u0417\u0430\u043f\u0443\u0441\u0442\u0438\u0442\u0438 \u0431\u0443\u0434\u044c-\u043a\u043e\u043b\u0438: {cmd}',
    update: '\u041e\u043d\u043e\u0432\u0438\u0442\u0438 \u043f\u0456\u0437\u043d\u0456\u0448\u0435: {cmd}', uninstall: '\u0412\u0438\u0434\u0430\u043b\u0438\u0442\u0438: {cmd}', local: '\u0412\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u044e\u0454\u043c\u043e \u0437 \u043f\u0430\u043f\u043a\u0438 {dir} (\u0431\u0435\u0437 \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0435\u043d\u043d\u044f \u0439 \u0431\u0435\u0437 \u043f\u0435\u0440\u0435\u0432\u0456\u0440\u043a\u0438 \u043f\u0456\u0434\u043f\u0438\u0441\u0443: \u0446\u0435 \u0442\u0435, \u0449\u043e \u0432\u0438 \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0438\u043b\u0438).',
    removing: '\u0412\u0438\u0434\u0430\u043b\u044f\u0454\u043c\u043e \u0437\u0430\u0441\u0442\u043e\u0441\u0443\u043d\u043e\u043a \u0456 \u0437\u0430\u043f\u0443\u0441\u043a\u0430\u0447\u0456\u2026', removed: 'CandleLab \u0432\u0438\u0434\u0430\u043b\u0435\u043d\u043e. \u0412\u0430\u0448\u0456 \u0434\u0430\u043d\u0456 \u043b\u0438\u0448\u0438\u043b\u0438\u0441\u044c \u0443 {dir} (\u043f\u0430\u043f\u043a\u0430 data \u0456 \u0444\u0430\u0439\u043b .env). \u0429\u043e\u0431 \u0432\u0438\u0434\u0430\u043b\u0438\u0442\u0438 \u0439 \u0457\u0445, \u0437\u0430\u043f\u0443\u0441\u0442\u0456\u0442\u044c \u0432\u0438\u0434\u0430\u043b\u0435\u043d\u043d\u044f \u0449\u0435 \u0440\u0430\u0437 \u0437 {flag}.',
    removedAll: 'CandleLab \u0456 \u0432\u0441\u0456 \u0439\u043e\u0433\u043e \u0434\u0430\u043d\u0456 \u0432\u0438\u0434\u0430\u043b\u0435\u043d\u043e.', notInstalled: '\u0423 {dir} \u043d\u0435 \u0437\u043d\u0430\u0439\u0434\u0435\u043d\u043e \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e\u0433\u043e CandleLab.',
    'fail.nokey': '\u0423 \u0446\u0435\u0439 \u0456\u043d\u0441\u0442\u0430\u043b\u044f\u0442\u043e\u0440 \u043d\u0435 \u0432\u0431\u0443\u0434\u043e\u0432\u0430\u043d\u043e \u043a\u043b\u044e\u0447 \u0432\u0438\u043f\u0443\u0441\u043a\u0443, \u0442\u043e\u0436 \u0432\u0456\u043d \u043d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u043c\u043e\u0436\u0435 \u043f\u0435\u0440\u0435\u0432\u0456\u0440\u0438\u0442\u0438. \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.', 'fail.sig': '\u0421\u043f\u0438\u0441\u043e\u043a \u0437\u0431\u0456\u0440\u043e\u043a \u041d\u0415 \u043f\u0456\u0434\u043f\u0438\u0441\u0430\u043d\u043e \u043a\u043b\u044e\u0447\u0435\u043c \u0432\u0438\u043f\u0443\u0441\u043a\u0443 CandleLab. \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.',
    'fail.format': '\u0421\u043f\u0438\u0441\u043e\u043a \u0437\u0431\u0456\u0440\u043e\u043a \u043f\u043e\u0448\u043a\u043e\u0434\u0436\u0435\u043d\u0438\u0439 \u0430\u0431\u043e \u0432 \u043d\u0435\u0432\u0456\u0434\u043e\u043c\u043e\u043c\u0443 \u0444\u043e\u0440\u043c\u0430\u0442\u0456. \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.', 'fail.hash': '\u0417\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0435\u043d\u0438\u0439 \u0430\u0440\u0445\u0456\u0432 \u043d\u0435 \u0437\u0431\u0456\u0433\u0430\u0454\u0442\u044c\u0441\u044f \u0437 \u043a\u043e\u043d\u0442\u0440\u043e\u043b\u044c\u043d\u043e\u044e \u0441\u0443\u043c\u043e\u044e \u0437 \u043f\u0456\u0434\u043f\u0438\u0441\u0430\u043d\u043e\u0433\u043e \u0441\u043f\u0438\u0441\u043a\u0443. \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.',
    'fail.size': '\u0417\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0435\u043d\u0438\u0439 \u0430\u0440\u0445\u0456\u0432 \u043c\u0430\u0454 \u0456\u043d\u0448\u0438\u0439 \u0440\u043e\u0437\u043c\u0456\u0440, \u043d\u0456\u0436 \u0443 \u043f\u0456\u0434\u043f\u0438\u0441\u0430\u043d\u043e\u043c\u0443 \u0441\u043f\u0438\u0441\u043a\u0443. \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.', 'fail.net': '\u041d\u0435 \u0432\u0434\u0430\u043b\u043e\u0441\u044f \u0437\u0430\u0432\u0430\u043d\u0442\u0430\u0436\u0438\u0442\u0438 {url}: {reason}',
    'fail.node': '\u0426\u0435\u0439 Node.js ({have}) \u0441\u0442\u0430\u0440\u0456\u0448\u0438\u0439, \u043d\u0456\u0436 \u043f\u043e\u0442\u0440\u0456\u0431\u043d\u043e \u0437\u0431\u0456\u0440\u0446\u0456 ({need}).', 'fail.zip': '\u0410\u0440\u0445\u0456\u0432 \u043f\u043e\u0448\u043a\u043e\u0434\u0436\u0435\u043d\u0438\u0439 \u0430\u0431\u043e \u043d\u0435\u0431\u0435\u0437\u043f\u0435\u0447\u043d\u0438\u0439 ({reason}). \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.',
    'fail.content': '\u0410\u0440\u0445\u0456\u0432 \u043d\u0435 \u0441\u0445\u043e\u0436\u0438\u0439 \u043d\u0430 \u0437\u0431\u0456\u0440\u043a\u0443 CandleLab ({reason}). \u041d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e.', 'fail.dir': '\u041d\u0435 \u0432\u0434\u0430\u043b\u043e\u0441\u044f \u0432\u0438\u043a\u043e\u0440\u0438\u0441\u0442\u0430\u0442\u0438 \u043f\u0430\u043f\u043a\u0443 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044f {dir}: {reason}',
    'fail.local': '\u041f\u0430\u043f\u043a\u0430 {dir} \u043d\u0435 \u0454 \u0440\u043e\u0437\u043f\u0430\u043a\u043e\u0432\u0430\u043d\u043e\u044e \u0437\u0431\u0456\u0440\u043a\u043e\u044e CandleLab (\u043d\u0435\u043c\u0430\u0454 \u0444\u0430\u0439\u043b\u0443 VERSION).', 'fail.url': '\u0410\u0434\u0440\u0435\u0441\u0430 \u0437\u0431\u0456\u0440\u043a\u0438 \u043d\u0435\u043f\u0440\u0438\u0439\u043d\u044f\u0442\u043d\u0430: {url}',
    'fail.notempty': '\u041f\u0430\u043f\u043a\u0430 {dir} \u043d\u0435 \u043f\u043e\u0440\u043e\u0436\u043d\u044f \u0439 \u043d\u0435 \u0454 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u043c CandleLab, \u0442\u043e\u043c\u0443 \u043d\u0456\u0447\u043e\u0433\u043e \u043d\u0435 \u0437\u043c\u0456\u043d\u0435\u043d\u043e. \u041e\u0431\u0435\u0440\u0456\u0442\u044c \u043f\u043e\u0440\u043e\u0436\u043d\u044e \u043f\u0430\u043f\u043a\u0443 (\u0430\u0431\u043e \u0436\u043e\u0434\u043d\u043e\u0457: \u0442\u043e\u0434\u0456 \u0432\u0438\u043a\u043e\u0440\u0438\u0441\u0442\u0430\u0454\u0442\u044c\u0441\u044f \u0442\u0438\u043f\u043e\u0432\u0430).', 'fail.unsafe': '\u041d\u0435 \u0432\u0438\u043a\u043e\u0440\u0438\u0441\u0442\u043e\u0432\u0443\u044e {dir}: \u0446\u0435 \u0432\u0430\u0448\u0430 \u0434\u043e\u043c\u0430\u0448\u043d\u044f \u043f\u0430\u043f\u043a\u0430, \u043a\u043e\u0440\u0456\u043d\u044c \u0434\u0438\u0441\u043a\u0430 \u0430\u0431\u043e \u043f\u0430\u043f\u043a\u0430, \u0449\u043e \u043c\u0456\u0441\u0442\u0438\u0442\u044c \u0432\u0430\u0448\u0443 \u0434\u043e\u043c\u0430\u0448\u043d\u044e.',
    sourceCheckout: '\u0426\u0435 \u0432\u0438\u0445\u0456\u0434\u043d\u0438\u0439 \u043a\u043e\u0434, \u0430 \u043d\u0435 \u0432\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0430 \u0437\u0431\u0456\u0440\u043a\u0430. \u041e\u043d\u043e\u0432\u0456\u0442\u044c \u0439\u043e\u0433\u043e \u0447\u0435\u0440\u0435\u0437 git pull \u0456 \u0437\u0430\u043f\u0443\u0441\u0442\u0456\u0442\u044c: node scripts/setup.mjs', noBase: '\u0410\u0434\u0440\u0435\u0441\u0443 \u0437\u0431\u0456\u0440\u043e\u043a \u043d\u0435 \u0437\u0430\u0434\u0430\u043d\u043e. \u0417\u0430\u0434\u0430\u0439\u0442\u0435 SHOT_DIST_URL \u0430\u0431\u043e baseUrl \u0443 config/release.public.json.',
    checkNew: '\u0404 \u043e\u043d\u043e\u0432\u043b\u0435\u043d\u043d\u044f: {current} -> {latest}. \u0412\u0441\u0442\u0430\u043d\u043e\u0432\u0456\u0442\u044c \u0439\u043e\u0433\u043e \u043a\u043e\u043c\u0430\u043d\u0434\u043e\u044e: {cmd}', checkSame: 'CandleLab {current} \u2014 \u0446\u0435 \u043d\u0430\u0439\u043d\u043e\u0432\u0456\u0448\u0430 \u0437\u0431\u0456\u0440\u043a\u0430.',
  },
};
export function say(lang, key, vars = {}) {
  const text = MSG[lang]?.[key] ?? MSG.en[key] ?? key;
  return text.replace(/\{(\w+)\}/g, (all, k) => (k in vars ? String(vars[k]) : all));
}
export const pickLang = (env = process.env, locale = '') => (/^uk\b/i.test(String(env.SHOT_LANG || env.LC_ALL || env.LC_MESSAGES || env.LANG || locale).replace('_', '-')) ? 'uk' : 'en');

// ------------------------------------------------------------------------------------------------------------------------------- versions
const SEMVER = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/;
export function parseSemver(text) {
  const m = SEMVER.exec(String(text ?? '').trim());
  return m ? { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), pre: m[4] ? m[4].split('.') : [] } : null;
}
/** -1, 0 or 1. A pre-release is older than its release (1.0.0-rc.1 < 1.0.0). Throws on a text that is not a version. */
export function compareVersions(a, b) {
  const x = parseSemver(a), y = parseSemver(b);
  if (!x || !y) throw new InstallError('fail.format');
  for (const k of ['major', 'minor', 'patch']) if (x[k] !== y[k]) return x[k] < y[k] ? -1 : 1;
  if (!x.pre.length || !y.pre.length) return x.pre.length === y.pre.length ? 0 : x.pre.length ? -1 : 1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === undefined) return -1;
    if (q === undefined) return 1;
    if (p === q) continue;
    const pn = /^\d+$/.test(p), qn = /^\d+$/.test(q);
    if (pn && qn) return Number(p) < Number(q) ? -1 : 1;
    if (pn !== qn) return pn ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return 0;
}

// ------------------------------------------------------------------------------------------------------------------------------- signature and checksum
export const sha256Hex = data => createHash('sha256').update(data).digest('hex');
export const sha256File = (path, fs = nodeFs) => sha256Hex(fs.readFileSync(path));
/** The ed25519 public key (64 hex characters = 32 raw bytes) as a key object. */
export function publicKeyOf(hex) {
  if (!/^[0-9a-f]{64}$/i.test(String(hex ?? ''))) throw new InstallError('fail.nokey');
  return createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(hex, 'hex')]), format: 'der', type: 'spki' });
}
export const keyIdOf = hex => sha256Hex(Buffer.from(hex, 'hex')).slice(0, 16);
/** True only for a valid ed25519 signature (base64, 64 bytes) of exactly these bytes. Never throws on a bad signature. */
export function verifyDetached(data, signatureB64, publicHex) {
  try {
    const sig = Buffer.from(String(signatureB64).trim(), 'base64');
    if (sig.length !== 64) return false;
    return cryptoVerify(null, data, publicKeyOf(publicHex), sig);
  } catch (error) { if (error instanceof InstallError) throw error; return false; }
}

/** The release list: strict. Returns the fields the installer uses. */
export function parseManifest(bytes) {
  let m;
  try { m = JSON.parse(Buffer.from(bytes).toString('utf8')); } catch { throw new InstallError('fail.format'); }
  const ok = m && typeof m === 'object' && m.format === FORMAT && typeof m.version === 'string' && parseSemver(m.version) && typeof m.url === 'string' && m.url.length > 0 && m.url.length < 600 && !/\s/.test(m.url)
    && /^[0-9a-f]{64}$/.test(String(m.sha256)) && Number.isInteger(m.size) && m.size > 0 && m.size <= LIMITS.archive && typeof m.minNode === 'string' && parseSemver(m.minNode)
    && typeof m.publishedAt === 'string' && !Number.isNaN(Date.parse(m.publishedAt));
  if (!ok) throw new InstallError('fail.format');
  return { format: m.format, version: m.version, url: m.url, sha256: m.sha256, size: m.size, minNode: m.minNode, publishedAt: m.publishedAt, commit: typeof m.commit === 'string' ? m.commit.slice(0, 40) : null };
}

/** http(s) only; plain http only for this computer (a test server or a local mirror). */
export function acceptableUrl(text, base) {
  let u;
  try { u = new URL(text, base); } catch { return null; }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname);
  return u.protocol === 'https:' || (u.protocol === 'http:' && local) ? u : null;
}

// ------------------------------------------------------------------------------------------------------------------------------- network
export async function httpGet(url, { fetch: f = globalThis.fetch, maxBytes = LIMITS.manifest, timeoutMs = 30_000, tries = 3, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  let last = 'unknown';
  for (let attempt = 0; attempt < tries; attempt++) {
    try {
      const res = await f(url, { headers: { 'User-Agent': 'shot-installer' }, redirect: 'follow', signal: AbortSignal.timeout(timeoutMs) });
      if (res.status === 404) throw new InstallError('fail.net', { url, reason: 'HTTP 404' });
      if (!res.ok) { last = `HTTP ${res.status}`; if (res.status < 500 && res.status !== 429) break; }
      else {
        const declared = Number(res.headers.get('content-length'));
        if (Number.isFinite(declared) && declared > maxBytes) throw new InstallError('fail.size');
        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.length > maxBytes) throw new InstallError('fail.size');
        return buf;
      }
    } catch (error) {
      if (error instanceof InstallError) throw error;
      last = error?.cause?.code || error?.name || 'network error';
    }
    if (attempt < tries - 1) await sleep(1000 * 2 ** attempt);
  }
  throw new InstallError('fail.net', { url, reason: last });
}

/**
 * Reads the newest release list. With a release key (`publicKey`) the list must carry a valid signature (InstallError('fail.sig') otherwise). WITHOUT a key the releases are UNSIGNED, which is the owner's
 * choice since 16 Oct 2026 (\u00abno signatures on releases\u00bb: nothing to back up or lose): the only integrity check is then the SHA-256 of the archive from this list, fetched over https from the owner's own
 * repository, so whoever controls that repository controls what is installed. `keyId` is null for an unsigned release.
 */
export async function fetchRelease({ base, publicKey, fetch: f, sleep }) {
  const root = String(base ?? '').replace(/\/+$/, '');
  const listUrl = acceptableUrl(`${root}/latest.json`), sigUrl = publicKey ? acceptableUrl(`${root}/latest.json.sig`) : null;
  if (!listUrl || (publicKey && !sigUrl)) throw new InstallError('fail.url', { url: `${root}/latest.json` });
  const bytes = await httpGet(listUrl.href, { fetch: f, sleep });
  if (publicKey) {
    const sig = await httpGet(sigUrl.href, { fetch: f, maxBytes: 1024, sleep });
    if (!verifyDetached(bytes, sig.toString('utf8'), publicKey)) throw new InstallError('fail.sig');
  }
  const manifest = parseManifest(bytes);
  const archive = acceptableUrl(manifest.url, listUrl.href);
  if (!archive) throw new InstallError('fail.url', { url: manifest.url });
  return { manifest, archiveUrl: archive.href, listUrl: listUrl.href, keyId: publicKey ? keyIdOf(publicKey) : null };
}

// ------------------------------------------------------------------------------------------------------------------------------- ZIP
function u64(buf, at) {
  const v = buf.readBigUInt64LE(at);
  if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new InstallError('fail.zip', { reason: 'size' });
  return Number(v);
}
/** Entries of a ZIP held in memory (central directory, ZIP64 aware). */
export function listZip(buf) {
  const bad = reason => new InstallError('fail.zip', { reason });
  if (buf.length < 22) throw bad('too short');
  let eocd = -1;
  for (let i = buf.length - 22, stop = Math.max(0, buf.length - 22 - 65535); i >= stop; i--) if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw bad('no end record');
  let total = buf.readUInt16LE(eocd + 10), size = buf.readUInt32LE(eocd + 12), offset = buf.readUInt32LE(eocd + 16);
  if (total === 0xffff || size === 0xffffffff || offset === 0xffffffff) {
    const loc = eocd - 20;
    if (loc < 0 || buf.readUInt32LE(loc) !== 0x07064b50) throw bad('zip64 locator');
    const rec = u64(buf, loc + 8);
    if (rec + 56 > buf.length || buf.readUInt32LE(rec) !== 0x06064b50) throw bad('zip64 record');
    total = u64(buf, rec + 32); size = u64(buf, rec + 40); offset = u64(buf, rec + 48);
  }
  if (total > LIMITS.files || offset + size > buf.length) throw bad('directory');
  const out = [];
  let at = offset;
  for (let k = 0; k < total; k++) {
    if (at + 46 > buf.length || buf.readUInt32LE(at) !== 0x02014b50) throw bad('directory entry');
    const madeBy = buf.readUInt16LE(at + 4), flags = buf.readUInt16LE(at + 8), method = buf.readUInt16LE(at + 10), crc = buf.readUInt32LE(at + 16);
    let csize = buf.readUInt32LE(at + 20), usize = buf.readUInt32LE(at + 24), local = buf.readUInt32LE(at + 42);
    const nl = buf.readUInt16LE(at + 28), el = buf.readUInt16LE(at + 30), cl = buf.readUInt16LE(at + 32), external = buf.readUInt32LE(at + 38);
    const nameEnd = at + 46 + nl, extraEnd = nameEnd + el;
    if (extraEnd + cl > buf.length) throw bad('directory entry');
    const name = buf.toString(flags & 0x800 ? 'utf8' : 'latin1', at + 46, nameEnd);
    for (let e = nameEnd; e + 4 <= extraEnd;) {
      const id = buf.readUInt16LE(e), len = buf.readUInt16LE(e + 2), end = e + 4 + len;
      if (end > extraEnd) break;
      if (id === 1) {
        let p = e + 4;
        const take = field => { if (field !== 0xffffffff) return field; if (p + 8 > end) throw bad('zip64 field'); const v = u64(buf, p); p += 8; return v; };
        usize = take(usize); csize = take(csize); local = take(local);
      }
      e = end;
    }
    const unix = madeBy >> 8 === 3 ? (external >>> 16) & 0xffff : null;
    out.push({ name, method, csize, usize, crc, local, flags, unix, directory: name.endsWith('/') });
    at = extraEnd + cl;
  }
  return out;
}
export function entryData(buf, e) {
  const bad = reason => new InstallError('fail.zip', { reason });
  if (e.flags & 1) throw bad('encrypted');
  if (e.usize > LIMITS.file) throw bad('file too large');
  if (e.local + 30 > buf.length || buf.readUInt32LE(e.local) !== 0x04034b50) throw bad('local header');
  const start = e.local + 30 + buf.readUInt16LE(e.local + 26) + buf.readUInt16LE(e.local + 28), end = start + e.csize;
  if (end > buf.length) throw bad('cut short');
  const raw = buf.subarray(start, end);
  let data;
  if (e.method === 0) data = Buffer.from(raw);
  else if (e.method === 8) { try { data = inflateRawSync(raw, { maxOutputLength: Math.max(1, e.usize + 1) }); } catch { throw bad('inflate'); } }
  else throw bad('method');
  if (data.length !== e.usize || crc32(data) !== e.crc) throw bad('checksum');
  return data;
}
/** A path from the archive, as segments; throws for anything that could leave the target folder. */
export function safeSegments(name) {
  const parts = String(name).replace(/\/$/, '').split('/');
  if (!name || name.startsWith('/') || name.includes('\\') || name.includes('\0') || /^[A-Za-z]:/.test(name) || parts.some(p => p === '' || p === '.' || p === '..')) throw new InstallError('fail.zip', { reason: 'unsafe path' });
  return parts;
}
/**
 * Unpacks a release archive into `dest`. The archive has one top-level folder (shot-<version>/): it is stripped. Absolute paths, `..`, backslashes, drive letters, symbolic links,
 * duplicate names, more than 60,000 files, more than 1.5 GB in total and any CRC mismatch are refused. Unix permissions survive as \u00abexecutable or not\u00bb.
 */
export function extractZip(buf, dest, { fs = nodeFs } = {}) {
  const entries = listZip(buf);
  const seen = new Set();
  let total = 0, top = null;
  const plan = [];
  for (const e of entries) {
    const segs = safeSegments(e.name);
    if (e.unix !== null && (e.unix & 0o170000) === 0o120000) throw new InstallError('fail.zip', { reason: 'symbolic link' });
    top ??= segs[0];
    if (segs[0] !== top || segs.length < 2 && !e.directory) throw new InstallError('fail.zip', { reason: 'not one top-level folder' });
    const rel = segs.slice(1);
    if (!rel.length) continue;
    const key = rel.join('/').toLowerCase();
    if (seen.has(key)) throw new InstallError('fail.zip', { reason: 'duplicate name' });
    seen.add(key);
    total += e.usize;
    if (total > LIMITS.unpacked) throw new InstallError('fail.zip', { reason: 'too large' });
    plan.push({ e, rel });
  }
  const root = resolve(dest);
  fs.mkdirSync(root, { recursive: true });
  for (const { e, rel } of plan) {
    const target = resolve(root, ...rel), inside = relative(root, target);
    if (!inside || inside.startsWith('..') || isAbsolute(inside)) throw new InstallError('fail.zip', { reason: 'unsafe path' });
    if (e.directory) { fs.mkdirSync(target, { recursive: true }); continue; }
    const data = entryData(buf, e);
    fs.mkdirSync(dirname(target), { recursive: true });
    fs.writeFileSync(target, data, { mode: e.unix !== null && (e.unix & 0o111) ? 0o755 : 0o644 });
  }
  return { files: plan.filter(p => !p.e.directory).length, bytes: total, top: top ?? '' };
}

// ------------------------------------------------------------------------------------------------------------------------------- the install folder
const readJson = (path, fs = nodeFs) => { try { return JSON.parse(fs.readFileSync(path, 'utf8')); } catch { return null; } };
export const installedVersion = (dir, fs = nodeFs) => { const v = readJson(join(dir, 'VERSION'), fs)?.version; return typeof v === 'string' && parseSemver(v) ? v : null; };
/** A folder the installer must never take as its own: the home folder, the root of a disk, or anything that contains the home folder. */
export function unsafeDir(dir, home = homedir()) {
  const d = resolve(dir), h = resolve(home);
  return d === h || dirname(d) === d || h.startsWith(d + sep);
}
/** Safe to install into: it does not exist, is empty, holds only what belongs to the person or to the installer (data, .env, runtime\u2026), or is already a CandleLab install. */
export function usableDir(dir, fs = nodeFs) {
  if (!fs.existsSync(dir)) return true;
  if (fs.existsSync(join(dir, INSTALL_STAMP)) || installedVersion(dir, fs)) return true;
  try { return fs.readdirSync(dir).every(name => PROTECTED.includes(name)); } catch { return false; }
}
const sleepSync = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
function renameRetry(a, b, fs = nodeFs) {
  for (let i = 0; ; i++) {
    try { fs.renameSync(a, b); return; } catch (error) {
      if (i >= 6 || !['EPERM', 'EBUSY', 'EACCES', 'ENOTEMPTY'].includes(error.code)) throw error;
      sleepSync(150 * (i + 1));
    }
  }
}
const removeTree = (path, fs = nodeFs) => { try { fs.rmSync(path, { recursive: true, force: true, maxRetries: 5, retryDelay: 150 }); return true; } catch { return false; } };

/**
 * Puts the unpacked release `from` into the install folder `dir`: every top-level entry of the release replaces the old one (the old one is set aside first and put back if anything fails),
 * entries an earlier release installed and this one no longer has are removed, and everything else in `dir` (data, .env, runtime, reports, the person's own files) is left as it is.
 * Writes `.shot-install.json`. Returns the list of installed entries.
 */
export function swapIn(from, dir, meta, { fs = nodeFs } = {}) {
  const entries = fs.readdirSync(from);
  for (const name of entries) if (PROTECTED.includes(name)) throw new InstallError('fail.content', { reason: `the release contains ${name}` });
  const previous = readJson(join(dir, INSTALL_STAMP), fs)?.entries;
  const gone = Array.isArray(previous) ? previous.filter(n => typeof n === 'string' && !entries.includes(n) && !PROTECTED.includes(n) && !n.includes('/') && !n.includes('\\') && n !== '..') : [];
  const old = join(dir, '.old');
  removeTree(old, fs);
  fs.mkdirSync(old, { recursive: true });
  const moved = [], placed = [];
  try {
    for (const name of [...entries, ...gone]) {
      if (fs.existsSync(join(dir, name))) { renameRetry(join(dir, name), join(old, name), fs); moved.push(name); }
    }
    for (const name of entries) { renameRetry(join(from, name), join(dir, name), fs); placed.push(name); }
  } catch (error) {
    for (const name of placed) removeTree(join(dir, name), fs);
    for (const name of moved) { try { renameRetry(join(old, name), join(dir, name), fs); } catch { /* the copy stays in .old */ } }
    throw error;
  }
  fs.writeFileSync(join(dir, INSTALL_STAMP), JSON.stringify({ ...meta, entries, installedAt: new Date().toISOString() }, null, 2));
  removeTree(old, fs);
  return entries;
}

// ------------------------------------------------------------------------------------------------------------------------------- launchers
const q = s => `'${String(s).replace(/'/g, `'\\''`)}'`;
const subs = (text, vars) => text.replace(/@@(\w+)@@/g, (_all, k) => vars[k]);
const SHOT_SH = `#!/bin/sh
# CandleLab launcher (written by the installer; safe to delete). Usage: shot [start|open|stop|restart|status|update|keys|doctor]
DIR=@@DIR@@
NODE=@@NODE@@
[ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
if [ -z "$NODE" ]; then echo "Node.js 24 was not found. Run the installer again." >&2; exit 1; fi
cd "$DIR" || exit 1
exec "$NODE" scripts/shot.mjs "$@"
`;
const SHOT_CMD = `@echo off
rem CandleLab launcher (written by the installer; safe to delete). Usage: shot [start|open|stop|restart|status|update|keys|doctor]
setlocal
set "DIR=@@WDIR@@"
set "NODE=@@WNODE@@"
if not exist "%NODE%" for /f "delims=" %%i in ('where node 2^>nul') do set "NODE=%%i"
if not exist "%NODE%" (echo Node.js 24 was not found. Run the installer again.& exit /b 1)
cd /d "%DIR%"
"%NODE%" scripts\\shot.mjs %*
exit /b %ERRORLEVEL%
`;
const APP_SH = `#!/bin/sh
# Opens CandleLab: starts it if it is not running and shows it in the browser. Written by the installer.
DIR=@@DIR@@
NODE=@@NODE@@
[ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
mkdir -p "$DIR/data"
cd "$DIR" || exit 1
exec "$NODE" scripts/setup.mjs --lang @@LANG@@ >> "$DIR/data/launcher.log" 2>&1
`;
const PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CandleLab</string><key>CFBundleDisplayName</key><string>CandleLab</string>
<key>CFBundleIdentifier</key><string>app.shot.launcher</string><key>CFBundleExecutable</key><string>CandleLab</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>@@VERSION@@</string><key>CFBundleShortVersionString</key><string>@@VERSION@@</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
`;

/**
 * What the installer puts outside the install folder, per system. A list of files ({path, content, mode}) and, on Windows, the shortcuts (made with PowerShell afterwards).
 * Pure: the same inputs give the same plan, so it is tested on any machine.
 */
export function launcherPlan({ platform, dir, node, home, env = {}, lang = 'en', version = '0.0.0' }) {
  const files = [], shortcuts = [], label = [], legacy = [];
  const win = platform === 'win32';
  const nodeIn = win ? join(dir, 'runtime', 'node.exe') : join(dir, 'runtime', 'bin', 'node');
  const nodePath = node ?? nodeIn;
  if (win) {
    files.push({ path: join(dir, 'shot.cmd'), content: subs(SHOT_CMD, { WDIR: dir, WNODE: nodePath }).replace(/\n/g, '\r\n'), mode: 0o644 });
    const programs = join(env.APPDATA ?? join(home, 'AppData', 'Roaming'), 'Microsoft', 'Windows', 'Start Menu', 'Programs');
    for (const lnk of [join(programs, 'CandleLab.lnk'), join(env.USERPROFILE ?? home, 'Desktop', 'CandleLab.lnk')]) shortcuts.push({ path: lnk, target: nodePath, args: `scripts\\setup.mjs --lang ${lang}`, cwd: dir });
    label.push('Start menu', 'Desktop');
    legacy.push(join(programs, 'lab69.lnk'), join(env.USERPROFILE ?? home, 'Desktop', 'lab69.lnk'));
  } else {
    files.push({ path: join(dir, 'shot'), content: subs(SHOT_SH, { DIR: q(dir), NODE: q(nodePath) }), mode: 0o755 });
    if (platform === 'darwin') {
      const apps = join(home, 'Applications');
      files.push({ path: join(apps, 'CandleLab.command'), content: `#!/bin/sh\n# Double-click to start CandleLab (the window shows what it does).\nexec ${q(join(dir, 'shot'))} start --lang ${lang}\n`, mode: 0o755 });
      files.push({ path: join(apps, 'CandleLab.app', 'Contents', 'Info.plist'), content: subs(PLIST, { VERSION: version }), mode: 0o644 });
      files.push({ path: join(apps, 'CandleLab.app', 'Contents', 'MacOS', 'CandleLab'), content: subs(APP_SH, { DIR: q(dir), NODE: q(nodePath), LANG: lang }), mode: 0o755 });
      label.push(join('~', 'Applications', 'CandleLab.app'), join('~', 'Applications', 'CandleLab.command'));
      legacy.push(join(apps, 'SHOT.app'), join(apps, 'SHOT.command'), join(apps, 'lab69.app'), join(apps, 'lab69.command')); // the names before the product was called CandleLab: a new install or an update removes them
    } else {
      const data = env.XDG_DATA_HOME || join(home, '.local', 'share');
      files.push({ path: join(data, 'applications', 'shot.desktop'), content: `[Desktop Entry]\nType=Application\nName=CandleLab\nComment=CandleLab, a local research workspace\nExec=${join(dir, 'shot')} start\nIcon=${join(dir, 'dist', 'client', 'icons', 'icon-192.png')}\nTerminal=false\nCategories=Office;Finance;\n`, mode: 0o644 });
      label.push(join('~', '.local', 'share', 'applications', 'shot.desktop'));
    }
    label.push(join(dir, 'shot'));
  }
  return { files, shortcuts, label, legacy, paths: [...files.map(f => f.path), ...shortcuts.map(s => s.path)] };
}
const SHORTCUT_PS = (s) => `$w = New-Object -ComObject WScript.Shell; $l = $w.CreateShortcut('${s.path.replace(/'/g, "''")}'); $l.TargetPath = '${s.target.replace(/'/g, "''")}'; $l.Arguments = '${s.args.replace(/'/g, "''")}'; $l.WorkingDirectory = '${s.cwd.replace(/'/g, "''")}'; $l.WindowStyle = 7; $l.Description = 'CandleLab'; $l.Save()`;

export function writeLaunchers(plan, { fs = nodeFs, spawnSync } = {}) {
  for (const p of plan.legacy ?? []) removeTree(p, fs);
  for (const f of plan.files) {
    fs.mkdirSync(dirname(f.path), { recursive: true });
    fs.writeFileSync(f.path, f.content, { mode: f.mode });
    try { fs.chmodSync(f.path, f.mode); } catch { /* not supported on this file system */ }
  }
  for (const s of plan.shortcuts) {
    fs.mkdirSync(dirname(s.path), { recursive: true });
    try { spawnSync?.('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', SHORTCUT_PS(s)], { windowsHide: true, stdio: 'ignore' }); } catch { /* a missing shortcut is not a failure */ }
  }
}

// ------------------------------------------------------------------------------------------------------------------------------- process helpers
export function runNode(node, args, { cwd, spawn = nodeSpawn, env = process.env } = {}) {
  return new Promise(done => {
    let child;
    try { child = spawn(node, args, { cwd, stdio: 'inherit', windowsHide: true, env }); } catch { done(1); return; }
    child.on?.('error', () => done(1));
    child.on?.('close', code => done(code ?? 1));
  });
}

// ------------------------------------------------------------------------------------------------------------------------------- install
const MB = n => (n / 1048576).toFixed(1);
/** The folder a person's install goes to when none is given: ~/SHOT, or %LOCALAPPDATA%\SHOT on Windows. */
export function defaultDir({ platform = process.platform, env = process.env, home = homedir() } = {}) {
  return platform === 'win32' ? join(env.LOCALAPPDATA || join(home, 'AppData', 'Local'), 'SHOT') : join(home, 'SHOT');
}

/**
 * The whole install/update. Every effect is a parameter (fetch, fs, spawn, platform, home, env, log) so the tests run it in a temp folder against a local server.
 * `opts`: dir, base, key, fromDir, node, lang, start, open, force, dryRun, launchers. Returns { ok, action, version, dir }.
 */
export async function runInstall(opts, deps = {}) {
  const d = { fetch: globalThis.fetch, fs: nodeFs, spawn: nodeSpawn, spawnSync: nodeSpawnSync, platform: process.platform, env: process.env, home: homedir(), log: console.log, sleep: undefined, nodeVersion: process.version, ...deps };
  const lang = opts.lang === 'uk' || opts.lang === 'en' ? opts.lang : pickLang(d.env);
  const t = (key, vars) => say(lang, key, vars);
  const dir = resolve(opts.dir ?? defaultDir(d));
  const nodePath = opts.node ?? process.execPath;
  const start = opts.start !== false, open = opts.open !== false;
  d.log(`${t('title')}`);
  d.log(t('where', { dir }));
  d.log(t('node', { path: nodePath, version: d.nodeVersion }));
  try {
    if (opts.dryRun) {
      d.log(t('dry'));
      d.log(opts.fromDir ? t('planLocal', { dir }) : t('plan', { url: `${String(opts.base ?? '').replace(/\/+$/, '')}/latest.json` }));
      const plan = launcherPlan({ platform: d.platform, dir, node: nodePath, home: d.home, env: d.env, lang });
      d.log(t('launchers', { list: plan.label.join(', ') }));
      return { ok: true, action: 'dry-run', dir };
    }
    if (unsafeDir(dir, d.home)) throw new InstallError('fail.unsafe', { dir });
    if (!usableDir(dir, d.fs)) throw new InstallError('fail.notempty', { dir });
    d.fs.mkdirSync(dir, { recursive: true });
    const staging = join(dir, '.staging');
    removeTree(staging, d.fs);
    d.fs.mkdirSync(staging, { recursive: true });
    const have = installedVersion(dir, d.fs);
    let version, meta;
    try {
      if (opts.fromDir) {
        const from = resolve(opts.fromDir);
        const v = installedVersion(from, d.fs);
        if (!v) throw new InstallError('fail.local', { dir: from });
        d.log(t('local', { dir: from }));
        if (from === dir) return await finish({ action: 'unchanged', version: v }); // unpacked straight into the install folder: nothing to copy
        version = v; meta = { version, source: 'folder' };
        d.log(t('unpacking'));
        const unpacked = join(staging, 'release');
        d.fs.cpSync(from, unpacked, { recursive: true, filter: p => !PROTECTED.includes(relative(from, p).split(sep)[0]) });
      } else {
        const publicKey = opts.key;
        d.log(t('fetching', { url: `${String(opts.base ?? '').replace(/\/+$/, '')}/latest.json` }));
        const rel = await fetchRelease({ base: opts.base, publicKey, fetch: d.fetch, sleep: d.sleep });
        const m = rel.manifest;
        d.log(rel.keyId ? t('signed', { keyId: rel.keyId }) : t('unsigned')); d.log(t('latest', { version: m.version, date: m.publishedAt.slice(0, 10) }));
        if (compareVersions(d.nodeVersion, m.minNode) < 0) throw new InstallError('fail.node', { have: d.nodeVersion, need: m.minNode });
        if (have && !opts.force) {
          const c = compareVersions(have, m.version);
          if (c === 0) { d.log(t('uptodate', { version: have })); return await finish({ action: 'unchanged', version: have }); }
          if (c > 0) { d.log(t('downgrade', { installed: have, latest: m.version })); return { ok: true, action: 'kept-newer', version: have, dir }; }
        }
        d.log(t('downloading', { version: m.version, mb: MB(m.size) }));
        const zip = await httpGet(rel.archiveUrl, { fetch: d.fetch, maxBytes: LIMITS.archive, timeoutMs: 15 * 60_000, sleep: d.sleep });
        if (zip.length !== m.size) throw new InstallError('fail.size');
        if (sha256Hex(zip) !== m.sha256) throw new InstallError('fail.hash');
        d.log(t('checksum'));
        d.log(t('unpacking'));
        const unpacked = join(staging, 'release');
        extractZip(zip, unpacked, { fs: d.fs });
        version = m.version; meta = { version, source: 'url', base: String(opts.base).replace(/\/+$/, ''), keyId: rel.keyId };
      }
      const unpacked = join(staging, 'release');
      const got = installedVersion(unpacked, d.fs);
      if (got !== version) throw new InstallError('fail.content', { reason: `VERSION says ${got ?? 'nothing'}, expected ${version}` });
      if (!d.fs.existsSync(join(unpacked, 'dist', 'server', 'index.js')) || !d.fs.existsSync(join(unpacked, 'scripts', 'setup.mjs'))) throw new InstallError('fail.content', { reason: 'files are missing' });
      // stop a running copy (its files are about to be replaced), then swap
      if (have && d.fs.existsSync(join(dir, 'scripts', 'service.mjs'))) { d.log(t('stopping')); await runNode(nodePath, ['scripts/service.mjs', 'stop'], { cwd: dir, spawn: d.spawn, env: d.env }); }
      d.log(t('swapping'));
      swapIn(unpacked, dir, meta, { fs: d.fs });
    } finally { removeTree(staging, d.fs); }
    return await finish({ action: have ? 'updated' : 'installed', version });

    async function finish(result) {
      const plan = launcherPlan({ platform: d.platform, dir, node: d.fs.existsSync(join(dir, 'runtime')) ? undefined : nodePath, home: d.home, env: d.env, lang, version: result.version });
      if (opts.launchers !== false) writeLaunchers(plan, { fs: d.fs, spawnSync: d.spawnSync });
      const cmd = d.platform === 'win32' ? join(dir, 'shot.cmd') : join(dir, 'shot');
      d.log('');
      d.log(t('installed', { version: result.version, dir }));
      if (opts.launchers !== false) d.log(t('launchers', { list: plan.label.join(', ') }));
      d.log(t('manual', { cmd: `${cmd} start` })); d.log(t('update', { cmd: `${cmd} update` }));
      if (start) {
        d.log(t('starting'));
        const code = await runNode(nodePath, ['scripts/setup.mjs', '--lang', lang, ...(open ? [] : ['--no-open'])], { cwd: dir, spawn: d.spawn, env: d.env });
        if (code !== 0) d.log(t('startFailed'));
        return { ok: true, ...result, dir, started: code === 0 };
      }
      return { ok: true, ...result, dir, started: false };
    }
  } catch (error) {
    if (error instanceof InstallError) { d.log(`\n${t(error.key, error.vars)}`); return { ok: false, error: error.key, dir }; }
    d.log(`\n${t('fail.dir', { dir, reason: error?.code || error?.message || String(error) })}`);
    return { ok: false, error: 'fail.dir', dir };
  }
}

// ------------------------------------------------------------------------------------------------------------------------------- uninstall
/** Removes the app, the runtime and the launchers; the data (`data/`, `.env`, `reports/`) stays unless `deleteData`. */
export async function runUninstall(opts, deps = {}) {
  const d = { fs: nodeFs, spawn: nodeSpawn, platform: process.platform, env: process.env, home: homedir(), log: console.log, ...deps };
  const lang = opts.lang === 'uk' || opts.lang === 'en' ? opts.lang : pickLang(d.env);
  const t = (key, vars) => say(lang, key, vars);
  const dir = resolve(opts.dir ?? defaultDir(d));
  const stamp = readJson(join(dir, INSTALL_STAMP), d.fs);
  if (!stamp && !installedVersion(dir, d.fs)) { d.log(t('notInstalled', { dir })); return { ok: false, removed: false, dir }; }
  if (opts.deleteData && unsafeDir(dir, d.home)) { d.log(t('fail.unsafe', { dir })); return { ok: false, removed: false, dir }; }
  const plan = launcherPlan({ platform: d.platform, dir, home: d.home, env: d.env, lang });
  const entries = [...new Set([...(Array.isArray(stamp?.entries) ? stamp.entries : []), 'shot', 'shot.cmd', 'VERSION'])].filter(n => typeof n === 'string' && !n.includes('/') && !n.includes('\\') && n !== '..' && !PROTECTED.includes(n));
  d.log(t('title'));
  d.log(t('where', { dir }));
  if (opts.dryRun) {
    d.log(t('dry'));
    d.log(t('removing') + ` ${[...entries, 'runtime', ...plan.paths].join(', ')}`);
    d.log(opts.deleteData ? 'data: DELETED' : 'data: kept');
    return { ok: true, removed: false, dry: true, dir };
  }
  if (d.fs.existsSync(join(dir, 'scripts', 'service.mjs'))) { d.log(t('stopping')); await runNode(opts.node ?? process.execPath, ['scripts/service.mjs', 'stop'], { cwd: dir, spawn: d.spawn, env: d.env }); }
  d.log(t('removing'));
  for (const p of [...plan.paths, ...plan.legacy]) removeTree(p, d.fs);
  if (d.platform === 'darwin') removeTree(join(d.home, 'Applications', 'CandleLab.app'), d.fs);
  if (opts.deleteData) {
    removeTree(dir, d.fs);
    d.log(t('removedAll'));
    return { ok: true, removed: true, dataKept: false, dir };
  }
  for (const name of [...entries, 'runtime', INSTALL_STAMP, '.staging', '.old']) removeTree(join(dir, name), d.fs);
  try { if (!d.fs.readdirSync(dir).length) d.fs.rmdirSync(dir); } catch { /* data stays */ }
  d.log(t('removed', { dir, flag: '--delete-data' }));
  return { ok: true, removed: true, dataKept: true, dir };
}

// ------------------------------------------------------------------------------------------------------------------------------- command line
export function parseArgs(argv) {
  const out = { command: argv[0] && !argv[0].startsWith('-') ? argv[0] : 'install', dir: undefined, base: undefined, key: undefined, fromDir: undefined, node: undefined, lang: undefined, start: true, open: true, force: false, dryRun: false, deleteData: false, launchers: true, unknown: [] };
  for (let i = out.command === argv[0] ? 1 : 0; i < argv.length; i++) {
    const a = argv[i], eq = a.startsWith('--') ? a.indexOf('=') : -1, flag = eq > 0 ? a.slice(0, eq) : a, inline = eq > 0 ? a.slice(eq + 1) : undefined;
    const value = () => inline ?? argv[++i];
    if (flag === '--dir') out.dir = value(); else if (flag === '--base') out.base = value(); else if (flag === '--key') out.key = value(); else if (flag === '--from-dir') out.fromDir = value();
    else if (flag === '--node') out.node = value(); else if (flag === '--lang') out.lang = value();
    else if (flag === '--no-start') out.start = false; else if (flag === '--no-open') out.open = false; else if (flag === '--force') out.force = true;
    else if (flag === '--dry-run') out.dryRun = true; else if (flag === '--delete-data') out.deleteData = true; else if (flag === '--no-launchers') out.launchers = false;
    else out.unknown.push(a);
  }
  return out;
}

export async function main(argv, deps = {}) {
  const o = parseArgs(argv);
  const log = deps.log ?? console.log;
  if (o.unknown.length) { log(`Unknown option: ${o.unknown.join(' ').slice(0, 80)}`); return 2; }
  if (o.command === 'install') return (await runInstall(o, deps)).ok ? 0 : 1;
  if (o.command === 'uninstall') return (await runUninstall(o, deps)).ok ? 0 : 1;
  if (o.command === 'check') {
    try { const r = await fetchRelease({ base: o.base, publicKey: o.key, fetch: deps.fetch ?? globalThis.fetch }); log(JSON.stringify({ ...r.manifest, keyId: r.keyId })); return 0; }
    catch (error) { log(say(pickLang(), error instanceof InstallError ? error.key : 'fail.net', error.vars ?? { url: '', reason: String(error?.message ?? error) })); return 1; }
  }
  log('Usage: core.mjs install|uninstall|check [options]');
  return 2;
}

/** The real paths are compared: node resolves symbolic links in import.meta.url but not in argv[1], and /tmp and /var/folders are links on macOS. */
const isMain = () => { try { return Boolean(process.argv[1]) && nodeFs.realpathSync(process.argv[1]) === nodeFs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } };
if (isMain()) {
  main(process.argv.slice(2)).then(code => process.exit(code), error => { console.error(error?.message ?? error); process.exit(1); });
}

'@

# The Ukrainian texts are written here as the letter U in front of a quoted string; scripts/release.mjs turns each into base64, so this file stays pure ASCII (PowerShell 5.1 reads a file or an `irm` answer
# without a byte order mark as ANSI, which would garble Cyrillic letters).
function ConvertFrom-ShotB64([string]$S) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($S)) }

function Get-ShotText([string]$Key, [string]$L) {
  $m = @{
    'title'       = @{ en = 'CandleLab installer'; uk = (ConvertFrom-ShotB64 '0JLRgdGC0LDQvdC+0LLQu9C10L3QvdGPIENhbmRsZUxhYg==') }
    'unsupported' = @{ en = 'This system is not supported by the installer (64-bit Windows on x64 or arm64 is needed). Use the ZIP download from the website.'; uk = (ConvertFrom-ShotB64 '0KbRjyDRgdC40YHRgtC10LzQsCDQvdC1INC/0ZbQtNGC0YDQuNC80YPRlNGC0YzRgdGPINGW0L3RgdGC0LDQu9GP0YLQvtGA0L7QvCAo0L/QvtGC0YDRltCx0LXQvSA2NC3QsdGW0YLQvdC40LkgV2luZG93cyDQvdCwIHg2NCDQsNCx0L4gYXJtNjQpLiDQodC60L7RgNC40YHRgtCw0LnRgtC10YHRjCBaSVAt0LLQsNGA0ZbQsNC90YLQvtC8INGW0Lcg0YHQsNC50YLRgy4=') }
    'no_base'     = @{ en = 'This copy of the installer has no release address. Set $env:SHOT_DIST_URL or use the ZIP download.'; uk = (ConvertFrom-ShotB64 '0KMg0YbRltC5INC60L7Qv9GW0Zcg0ZbQvdGB0YLQsNC70Y/RgtC+0YDQsCDQvdC10LzQsNGUINCw0LTRgNC10YHQuCDQt9Cx0ZbRgNC+0LouINCX0LDQtNCw0LnRgtC1ICRlbnY6U0hPVF9ESVNUX1VSTCDQsNCx0L4g0YHQutC+0YDQuNGB0YLQsNC50YLQtdGB0YwgWklQLdCy0LDRgNGW0LDQvdGC0L7QvC4=') }
    'node_found'  = @{ en = 'Using Node.js:'; uk = (ConvertFrom-ShotB64 'Tm9kZS5qcyDQt9C90LDQudC00LXQvdC+Og==') }
    'node_dl'     = @{ en = 'No Node.js 24 found. Downloading the official portable Node.js (into the CandleLab folder only; your system is not changed):'; uk = (ConvertFrom-ShotB64 'Tm9kZS5qcyAyNCDQvdC1INC30L3QsNC50LTQtdC90L4uINCX0LDQstCw0L3RgtCw0LbRg9GU0LzQviDQvtGE0ZbRhtGW0LnQvdC40Lkg0L/QvtGA0YLQsNGC0LjQstC90LjQuSBOb2RlLmpzICjQu9C40YjQtSDQsiDQv9Cw0L/QutGDIENhbmRsZUxhYiwg0YHQuNGB0YLQtdC80LAg0L3QtSDQt9C80ZbQvdGO0ZTRgtGM0YHRjyk6') }
    'node_plan'   = @{ en = 'No Node.js 24 found: would download the portable Node.js from'; uk = (ConvertFrom-ShotB64 'Tm9kZS5qcyAyNCDQvdC1INC30L3QsNC50LTQtdC90L46INC30LDQstCw0L3RgtCw0LbQuNCyINCx0Lgg0L/QvtGA0YLQsNGC0LjQstC90LjQuSBOb2RlLmpzINC3') }
    'node_sums'   = @{ en = 'Could not find the right Node.js file in SHASUMS256.txt:'; uk = (ConvertFrom-ShotB64 '0J3QtSDQstC00LDQu9C+0YHRjyDQt9C90LDQudGC0Lgg0L/QvtGC0YDRltCx0L3QuNC5INGE0LDQudC7IE5vZGUuanMg0YMgU0hBU1VNUzI1Ni50eHQ6') }
    'node_hash'   = @{ en = 'The Node.js checksum does not match the published one. Nothing was installed.'; uk = (ConvertFrom-ShotB64 '0JrQvtC90YLRgNC+0LvRjNC90LAg0YHRg9C80LAgTm9kZS5qcyDQvdC1INC30LHRltCz0LDRlNGC0YzRgdGPINC3INC+0L/Rg9Cx0LvRltC60L7QstCw0L3QvtGOLiDQndGW0YfQvtCz0L4g0L3QtSDQstGB0YLQsNC90L7QstC70LXQvdC+Lg==') }
    'node_bad'    = @{ en = 'The downloaded Node.js does not run on this computer.'; uk = (ConvertFrom-ShotB64 '0JfQsNCy0LDQvdGC0LDQttC10L3QuNC5IE5vZGUuanMg0L3QtSDQt9Cw0L/Rg9GB0LrQsNGU0YLRjNGB0Y8g0L3QsCDRhtGM0L7QvNGDINC60L7QvNC/4oCZ0Y7RgtC10YDRli4=') }
    'no_node_un'  = @{ en = 'Node.js was not found, so the installer cannot remove the app itself. Delete the folder by hand (your data is in its data sub-folder):'; uk = (ConvertFrom-ShotB64 'Tm9kZS5qcyDQvdC1INC30L3QsNC50LTQtdC90L4sINGC0L7QtiDRltC90YHRgtCw0LvRj9GC0L7RgCDQvdC1INC80L7QttC1INCy0LjQtNCw0LvQuNGC0Lgg0LfQsNGB0YLQvtGB0YPQvdC+0Log0YHQsNC8LiDQktC40LTQsNC70ZbRgtGMINC/0LDQv9C60YMg0LLRgNGD0YfQvdGDICjQtNCw0L3RliDQu9C10LbQsNGC0Ywg0YMg0ZfRlyDQv9GW0LTQv9Cw0L/RhtGWIGRhdGEpOg==') }
    'dl_failed'   = @{ en = 'Download failed:'; uk = (ConvertFrom-ShotB64 '0J3QtSDQstC00LDQu9C+0YHRjyDQt9Cw0LLQsNC90YLQsNC20LjRgtC4Og==') }
    'dry'         = @{ en = '(dry run: nothing is downloaded, written or started)'; uk = (ConvertFrom-ShotB64 'KNC/0YDQvtCx0L3QuNC5INC30LDQv9GD0YHQujog0L3RltGH0L7Qs9C+INC90LUg0LfQsNCy0LDQvdGC0LDQttGD0ZTRgtGM0YHRjywg0L3QtSDQt9Cw0L/QuNGB0YPRlNGC0YzRgdGPINC5INC90LUg0LfQsNC/0YPRgdC60LDRlNGC0YzRgdGPKQ==') }
  }
  return $m[$Key][$L]
}

function Get-ShotFile([string]$Url, [string]$Path, [string]$L) {
  try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path } catch { throw ("{0} {1} ({2})" -f (Get-ShotText 'dl_failed' $L), $Url, $_.Exception.Message) }
}

function Get-ShotNodeMajor([string]$NodePath) {
  try { $v = (& $NodePath -v 2>$null); if ($v -match '^v(\d+)\.') { return [int]$Matches[1] } } catch { }
  return 0
}

function Install-Shot {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is many times faster in PowerShell 5.1 without the progress bar
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

  # options from the parameters, then from the environment (for `irm | iex`)
  if ($env:SHOT_DRY_RUN) { $script:DryRun = [switch]$true }
  if ($env:SHOT_UNINSTALL) { $script:Uninstall = [switch]$true }
  if ($env:SHOT_DELETE_DATA) { $script:DeleteData = [switch]$true }
  $L = 'en'
  $locale = if ($Lang) { $Lang } elseif ($env:SHOT_LANG) { $env:SHOT_LANG } else { (Get-Culture).Name }
  if ($locale -match '^uk') { $L = 'uk' }
  $install = if ($Dir) { $Dir } elseif ($env:SHOT_HOME) { $env:SHOT_HOME } else { Join-Path $env:LOCALAPPDATA 'SHOT' }
  $baseUrl = if ($Base) { $Base } elseif ($env:SHOT_DIST_URL) { $env:SHOT_DIST_URL } else { $ShotDefaultBase }
  $baseUrl = $baseUrl.TrimEnd('/')
  if (-not $FromDir -and -not $Uninstall -and -not $baseUrl) { Write-Host (Get-ShotText 'no_base' $L); return }

  Write-Host ("{0} {1}" -f (Get-ShotText 'title' $L), $ShotInstallerVersion)
  $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  $nodeArch = switch ($arch) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { $null } }
  if (-not $nodeArch) { Write-Host (Get-ShotText 'unsupported' $L); return }
  Write-Host ("  windows/{0}  ->  {1}" -f $nodeArch, $install)

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("shot-install-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    # --- Node.js: the one from a previous install, one on PATH, or the official portable zip
    $node = $null
    $runtimeNode = Join-Path $install 'runtime\node.exe'
    $onPath = Get-Command node -ErrorAction SilentlyContinue
    foreach ($candidate in @($runtimeNode, $(if ($onPath) { $onPath.Source }))) {
      if ($candidate -and (Test-Path $candidate) -and ((Get-ShotNodeMajor $candidate) -ge $ShotNodeMajor)) { $node = $candidate; break }
    }
    $mirror = if ($env:SHOT_NODE_MIRROR) { $env:SHOT_NODE_MIRROR.TrimEnd('/') } else { 'https://nodejs.org/dist' }
    if (-not $node) {
      if ($Uninstall) { Write-Host ("{0} {1}" -f (Get-ShotText 'no_node_un' $L), $install); return }
      if ($DryRun) { Write-Host ("{0} {1}/latest-v{2}.x/" -f (Get-ShotText 'node_plan' $L), $mirror, $ShotNodeMajor); Write-Host ("  " + (Get-ShotText 'dry' $L)); return }
      Write-Host ("{0} {1}" -f (Get-ShotText 'node_dl' $L), $mirror)
      $sumsUrl = "$mirror/latest-v$ShotNodeMajor.x/SHASUMS256.txt"
      $sumsFile = Join-Path $tmp 'SHASUMS256.txt'
      Get-ShotFile $sumsUrl $sumsFile $L
      $line = Get-Content $sumsFile | Where-Object { $_ -match "  node-v[0-9][0-9.]*-win-$nodeArch\.zip$" } | Select-Object -First 1
      if (-not $line) { throw ("{0} {1}" -f (Get-ShotText 'node_sums' $L), $sumsUrl) }
      $want = ($line -split '\s+')[0].ToLower()
      $zipName = ($line -split '\s+')[1]
      $zipFile = Join-Path $tmp $zipName
      Get-ShotFile "$mirror/latest-v$ShotNodeMajor.x/$zipName" $zipFile $L
      if ((Get-FileHash -Algorithm SHA256 $zipFile).Hash.ToLower() -ne $want) { throw (Get-ShotText 'node_hash' $L) }
      $unpack = Join-Path $tmp 'node'
      Expand-Archive -Path $zipFile -DestinationPath $unpack -Force
      $inner = Get-ChildItem $unpack | Select-Object -First 1
      New-Item -ItemType Directory -Path $install -Force | Out-Null
      if (Test-Path (Join-Path $install 'runtime')) { Remove-Item (Join-Path $install 'runtime') -Recurse -Force }
      Move-Item -Path $inner.FullName -Destination (Join-Path $install 'runtime')
      $node = $runtimeNode
      if ((Get-ShotNodeMajor $node) -lt $ShotNodeMajor) { throw (Get-ShotText 'node_bad' $L) }
    }
    Write-Host ("{0} {1} ({2})" -f (Get-ShotText 'node_found' $L), $node, (& $node -v))

    # --- the installer core, the same file `npm run update` uses
    $coreFile = Join-Path $tmp 'core.mjs'
    [IO.File]::WriteAllText($coreFile, $ShotCoreMjs, (New-Object System.Text.UTF8Encoding($false)))

    $runner = $node
    if ($Uninstall -and $node.StartsWith($install, [StringComparison]::OrdinalIgnoreCase)) {
      # node.exe cannot delete itself: the uninstall runs a copy from the temp folder
      $runner = Join-Path $tmp 'node.exe'
      Copy-Item $node $runner
    }
    $argv = @($coreFile, $(if ($Uninstall) { 'uninstall' } else { 'install' }), '--dir', $install, '--node', $node, '--lang', $L)
    if (-not $Uninstall) {
      if ($baseUrl) { $argv += @('--base', $baseUrl) }
      if ($ShotPublicKey) { $argv += @('--key', $ShotPublicKey) }
      if ($FromDir) { $argv += @('--from-dir', $FromDir) }
    }
    if ($DeleteData) { $argv += '--delete-data' }
    if ($DryRun) { $argv += '--dry-run' }
    if ($NoStart) { $argv += '--no-start' }
    if ($NoOpen) { $argv += '--no-open' }
    if ($Force) { $argv += '--force' }
    & $runner @argv
    if ($LASTEXITCODE -ne 0) { Write-Host ("exit code {0}" -f $LASTEXITCODE) }
  }
  catch { Write-Host ""; Write-Host $_.Exception.Message -ForegroundColor Red }
  finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Install-Shot
