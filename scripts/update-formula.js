#!/usr/bin/env node
// Update Homebrew formula version and sha256 based on current package version and built tarballs

import { createHash } from 'crypto';
import { readFileSync, writeFileSync } from 'fs';
import { resolve } from 'path';

const pkg = JSON.parse(readFileSync(resolve('.', 'package.json'), 'utf8'));
const version = pkg.version;
const formulaPath = resolve('.', 'rpi-image-resizer.rb');
const armTarball = resolve('.', 'release', 'rpi-tool-darwin-arm64.tar.gz');
const amdTarball = resolve('.', 'release', 'rpi-tool-darwin-amd64.tar.gz');

function sha256File(filePath) {
  const data = readFileSync(filePath);
  const hash = createHash('sha256');
  hash.update(data);
  return hash.digest('hex');
}

const formula = readFileSync(formulaPath, 'utf8');
let updated = formula;

// Update version string
updated = updated.replace(/version\s+"[^"]+"/, `version "${version}"`);

// Update URLs to use v<version> tag if present with interpolation
updated = updated.replace(
  /(releases\/download\/v)([0-9A-Za-z._-]+)(\/rpi-tool-darwin-arm64\.tar\.gz)/,
  `$1${version}$3`
);
updated = updated.replace(
  /(releases\/download\/v)([0-9A-Za-z._-]+)(\/rpi-tool-darwin-amd64\.tar\.gz)/,
  `$1${version}$3`
);

// Compute and update sha256 for arm64 if tarball exists
try {
  const armSha = sha256File(armTarball);
  updated = updated.replace(/(url\s+"[^"]*darwin-arm64\.tar\.gz"\s*\n\s*sha256\s+")(.*?)(")/, `$1${armSha}$3`);
  console.log(`Updated arm64 sha256: ${armSha}`);
} catch {
  console.warn('Warning: arm64 tarball not found; arm64 sha256 not updated');
}

// Compute and update sha256 for amd64 if tarball exists
try {
  const amdSha = sha256File(amdTarball);
  updated = updated.replace(/(url\s+"[^"]*darwin-amd64\.tar\.gz"\s*\n\s*sha256\s+")(.*?)(")/, `$1${amdSha}$3`);
  console.log(`Updated amd64 sha256: ${amdSha}`);
} catch {
  console.warn('Warning: amd64 tarball not found; amd64 sha256 not updated');
}

if (updated !== formula) {
  writeFileSync(formulaPath, updated);
  console.log(`Formula updated: ${formulaPath} -> version ${version}`);
} else {
  console.log('No changes applied to formula');
}
